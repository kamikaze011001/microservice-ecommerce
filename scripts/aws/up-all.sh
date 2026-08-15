#!/usr/bin/env bash
# One-shot, from-scratch AWS bring-up. The cloud twin of `make k8s-bootstrap`.
#
# WHEN: you ran `make aws-down` (or it's a fresh account after `make aws-bootstrap`)
# and the EKS cluster no longer exists. Chains every ordered step from nothing to
# a fully running, fully seeded stack so you don't have to remember the sequence.
#
# WHAT PERSISTS across aws-down: aws/bootstrap (ECR repos, TF state, lock table)
# is a SEPARATE stack — aws-down only destroys aws/main, so pushed ECR images
# SURVIVE. That's why image push defaults to "reuse"; set PUSH=all after a code
# change to rebuild. FIRST-EVER run on a fresh account (ECR repos exist but are
# empty) MUST use PUSH=all, or step 6 deploys image tags that aren't there yet
# (ErrImagePull).
#
# ORDER (each step depends on the one before — do not reshuffle):
#   1 up.sh        VPC+EKS+ALB+ESO IRSA+RDS+ElastiCache, kubeconfig (endpoints exist after)
#   2 push-images  reuse existing ECR images, or PUSH=all to rebuild
#   3 infra-up.sh  ESO + ClusterSecretStore + Mongo/Kafka/SR/Connect/VM/Grafana
#                  + the Mongo CDC connector (must precede app ExternalSecrets)
#   4 seed-mongo   api_role + product + qty-history → Mongo (needs Mongo up)
#   5 seed-secrets RDS JDBC URLs + Redis host + app config → Secrets Manager (needs step-1
#                  outputs; must precede apps so ExternalSecrets resolve real vals)
#   6 apps         kubectl apply -k overlay; GATE on auth-server + inventory-svc
#   7 seed-rds     accounts/roles/users → RDS (schema from auth-server ddl-auto)
#   8 seed-inv     inventory stock → RDS (tables from inventory-svc ddl-auto)
#   9 seed-images  upload sample product JPGs to the S3 media bucket (Phase 4c)
#
# Every step bills AWS — this is the USER's to run. Idempotent-ish: each leaf
# reconciles, so a re-run after a mid-way failure resumes safely.
#
# Usage:  AWS_PROFILE=microecom [PUSH=all] scripts/aws/up-all.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT/aws/main"
PUSH="${PUSH:-reuse}"   # reuse | all

banner() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }

# ── Step 0 — preflight (fail BEFORE the 15-min apply) ─────────────────────────
banner "Step 0/9 · preflight (credentials + tfvars)"

# Credentials already live in the repo from local setup — source them rather than
# re-enter. Each resolves: existing env var > canonical file > fail-loud.
# 1) PayPal from docker/.env, mail from k8s/.env (both gitignored).
load_env_file() {  # load_env_file <path>  — export its KEY=VALUE pairs if present
  local f="$1"
  [ -f "$f" ] || return 0
  # Pair set -a / set +a so a parse failure inside the file can't strand auto-export
  # on for the rest of the script (which would leak later vars into child envs).
  # shellcheck disable=SC1090
  { set -a; . "$f"; set +a; } || { set +a; return 1; }
}
load_env_file "$ROOT/docker/.env"
load_env_file "$ROOT/k8s/.env"

# 2) JWK: Phase 8 Task 6 — no longer extracted here. deploy/secrets/
#    jwk.private.json is now the single canonical copy secrets-seed.sh resolves
#    for EVERY env (compose/k8s/aws) via the SAME `<file:jwk.private.json>` ref
#    (see deploy/secrets/authorization-server.yaml), so byte-identical-across-envs
#    (the gateway caches JWKS by kid) is now guaranteed by construction instead
#    of by this script sed-extracting it from k8s/infra/jobs/03-vault-seed/
#    seed.sh — a tree a later phase deletes, and Step 5 below no longer reads
#    APPLICATION_JWK at all (secrets-seed.sh --env aws resolves the JWK from
#    the canonical file, not the environment).

# Fail loud, naming the exact file to populate.
need() {  # need <VAR> <where-to-fill>
  local v="$1" where="$2"
  [ -n "${!v:-}" ] || { echo "ERROR: $v is empty — fill it in $where" >&2; exit 1; }
}
need PAYPAL_CLIENT_ID        "docker/.env"
need PAYPAL_CLIENT_SECRET    "docker/.env"
need APPLICATION_MAIL_USERNAME "k8s/.env"
need APPLICATION_MAIL_PASSWORD "k8s/.env"

# 3) RDS master password must be in the gitignored tfvars (grep, never echo it).
if ! grep -qE '^[[:space:]]*db_master_password[[:space:]]*=' "$TF/terraform.tfvars" 2>/dev/null; then
  echo "ERROR: db_master_password missing from aws/main/terraform.tfvars" >&2
  echo "  Add:  db_master_password = \"<choose-a-strong-password>\"" >&2
  exit 1
fi
echo "✓ creds resolved (PayPal, mail), db_master_password set, PUSH=${PUSH}"

# ── Step 1 — cluster + RDS ────────────────────────────────────────────────────
banner "Step 1/9 · terraform apply (VPC + EKS + ALB + ESO IRSA + RDS + ElastiCache) — ~15-20 min"
"$ROOT/scripts/aws/up.sh"

# ── Step 2 — images ───────────────────────────────────────────────────────────
banner "Step 2/9 · container images (PUSH=${PUSH})"
if [ "$PUSH" = "all" ]; then
  "$ROOT/scripts/aws/push-images.sh" all
else
  echo "▶ reusing existing ECR images. Set PUSH=all to rebuild after a code change."
fi

# ── Step 3 — ESO + self-hosted infra subset ──────────────────────────────────
banner "Step 3/9 · ESO + infra subset (Mongo/Kafka/SR/Connect/VM/Grafana)"
"$ROOT/scripts/aws/infra-up.sh"

# ── Step 4 — Mongo seed (api_role gates routing; needs Mongo from step 3) ─────
# Phase 8 Task 6: repointed off scripts/aws/seed-mongo.sh (k8s/infra/jobs/
# 02-mongo-seed + docker/*.json — trees a later phase deletes) onto the
# canonical deploy/scripts/seed.sh, which covers the same ground (api_role +
# product + productQuantityHistory) plus the 30 product images in one pass —
# see deploy/seed/tests/equivalence-test.sh (13 matched / 2 declared-different,
# both on the compose leg — the aws leg matches exactly). --context is
# REQUIRED for --env aws's mongo leg (kubectl exec into the in-cluster mongo
# pod) — never inherited from an ambient context; "microecom-eks" matches the
# hard context check at Step 6 below and scripts/aws/up.sh's own
# `--alias microecom-eks`.
banner "Step 4/9 · seed Mongo + product images (api_role + product + qty-history)"
bash "$ROOT/deploy/scripts/seed.sh" --env aws --stage pre-apps --context microecom-eks

# ── Step 5 — Secrets Manager (reads RDS outputs from step 1) ──────────────────
# Repointed off scripts/aws/seed-secrets.sh onto the canonical
# deploy/scripts/secrets-seed.sh (deploy/secrets/tests/equivalence-test.sh:
# 33/0/0). No --context here: secrets-seed.sh's aws leg talks to AWS Secrets
# Manager directly (no kubectl) and REJECTS --context for any env but k8s.
# PAYPAL_CLIENT_ID/SECRET and APPLICATION_MAIL_USERNAME/PASSWORD are resolved
# from this script's own environment (see the preflight above) via the
# canonical secrets resolver's ${VAR} substitution (deploy/secrets/
# payment-service.yaml, deploy/secrets/ecommerce.yaml) — nothing here needs to
# change to feed them through. application.jwk is NOT one of these — see the
# preflight's note above: it now resolves from the committed
# deploy/secrets/jwk.private.json for every env, not from an env var.
banner "Step 5/9 · seed Secrets Manager (RDS JDBC URLs + app config)"
bash "$ROOT/deploy/scripts/secrets-seed.sh" --env aws

# ── Step 6 — apps + the one hard sequencing gate ──────────────────────────────
banner "Step 6/9 · deploy apps overlay"
# Guard the only kubectl this orchestrator issues directly (the leaf scripts at
# steps 3-5/7-8 carry their own guard) so a stray context can't apply onto kind.
CTX="$(kubectl config current-context)"
if [[ "$CTX" != "microecom-eks" ]]; then
  echo "✋ kubectl context is '$CTX', not 'microecom-eks'. Aborting before apply." >&2
  echo "   Run: aws eks update-kubeconfig --name microecom-eks --region ap-southeast-1 --alias microecom-eks" >&2
  exit 1
fi
# Stamp the S3 IRSA role ARN onto the product-service + authorization-server
# ServiceAccounts and apply them BEFORE the apps overlay (mirror infra-up.sh's ESO
# stamp). The IRSA webhook injects the web-identity token when a pod is admitted
# based on its SA annotation, so the annotated SA must exist before app pods are
# created — annotating after would need a restart. The context guard above already
# pinned us to microecom-eks.
S3_ROLE_ARN="$(terraform -chdir="$TF" output -raw s3_irsa_role_arn)" \
  || { echo "ERROR: 'terraform output s3_irsa_role_arn' failed — run step 1 (terraform apply) first" >&2; exit 1; }
# Create the `apps` namespace BEFORE the IRSA ServiceAccounts. The overlay's
# namespace.yaml is applied last (inside `kubectl apply -k`), but the IRSA SAs
# below are stamped and applied imperatively first — both target namespace
# `apps`, which doesn't exist yet → "namespaces 'apps' not found". Apply the
# Namespace directly so the SAs land; the later `apply -k` reconciles it
# idempotently (Namespace apply is a no-op once it exists).
kubectl apply -f "$ROOT/k8s/apps/overlays/aws/namespace.yaml"
sed "s|PLACEHOLDER_S3_ROLE_ARN|${S3_ROLE_ARN}|g" \
  "$ROOT/k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml" | kubectl apply -f -

kubectl apply -k "$ROOT/k8s/apps/overlays/aws"

# Both gate a post-apps SQL seed: auth-server's ddl-auto creates the account
# schema (step 7), inventory-service's creates the stock tables (step 8). On
# timeout, surface state instead of dying on kubectl's bare "timed out" (these
# are the two hardest deps to debug — ExternalSecret/DB/IRSA crashloops).
echo "▶ waiting for authorization-server + inventory-service (they create the RDS schema) ..."
for d in authorization-server inventory-service; do
  kubectl -n apps rollout status "deploy/$d" --timeout=600s \
    || { echo "ERROR: $d failed to roll out. Recent state:" >&2
         kubectl -n apps describe "deploy/$d" 2>&1 | tail -30 >&2
         echo "  Dig in: kubectl -n apps logs deploy/$d --previous" >&2
         exit 1; }
done
echo "▶ waiting for the rest of the apps (best-effort) ..."
for d in gateway product-service order-service orchestrator-service \
         payment-service bff-service mock-paypal-service; do
  kubectl -n apps rollout status "deploy/$d" --timeout=300s || \
    echo "  ⚠ $d not Ready yet — check 'kubectl -n apps get pods' (not fatal for the seeds)"
done

# ── Step 7 — RDS account data (schema now exists) ─────────────────────────────
# Repointed off scripts/aws/seed-rds.sh onto the canonical seed.sh post-apps
# stage, which imports ecommerce.sql (account/account_role/role/user) AND the
# derived inventory_product/product_quantity_history rows AND runs the
# inventory-service reconcile restart, all gated behind its own
# every-target-table-exists precondition (see seed.sh's post-apps case).
banner "Step 7/9 · seed RDS data (accounts/roles/users)"
bash "$ROOT/deploy/scripts/seed.sh" --env aws --stage post-apps --context microecom-eks

# ── Step 8 — RDS inventory stock (tables now exist) ───────────────────────────
# scripts/aws/seed-inventory.sh's old ground (inventory_product +
# product_quantity_history) is now covered by the SAME post-apps call as
# Step 7 above (seed.sh has no inventory-only scope — see deploy/scripts/
# seed.sh's post-apps case, which imports both in one idempotent pass and
# restarts inventory-service once already). Calling it again here is
# redundant but harmless: the row-count gates make the SQL a no-op on the
# second pass, and the reconcile restart is idempotent (AvailableStockSeeder
# deletes-then-incrs). Kept as its own numbered step for output-shape parity
# with the old 9-step script; see task-6-report.md.
banner "Step 8/9 · seed RDS inventory stock"
bash "$ROOT/deploy/scripts/seed.sh" --env aws --stage post-apps --context microecom-eks

# AvailableStockSeeder runs at inventory-service startup (step 6) and seeds the
# Redis `available:{productId}` reservation counters from SUM(product_quantity_history).
# At step 6 the ledger was EMPTY, so it backfilled 0 rows and created NO counters
# — every order then fails "Insufficient available stock" (the Lua reservation
# reads a missing key as 0). The ledger rows were just inserted above, so restart
# inventory-service: the seeder re-runs, backfills inventory_product.stock from
# the ledger SUM, and re-incrs every `available:*` counter. It deletes-then-incrs
# each key, so this is safe and idempotent. See AvailableStockSeeder ("On Redis
# loss/restart, this runner reseeds all counters from the DB floor"). Without this
# restart, order placement is broken until the next inventory-service pod restart.
echo "▶ restarting inventory-service so AvailableStockSeeder re-seeds Redis from the populated ledger ..."
kubectl -n apps rollout restart deploy/inventory-service
kubectl -n apps rollout status deploy/inventory-service --timeout=300s

# ── Step 9 — S3 product images (Phase 4c) ─────────────────────────────────────
# scripts/aws/seed-images.sh's old ground is covered by the SAME
# `seed --env aws --stage pre-apps` call as Step 4 above (seed.sh uploads
# product images alongside the mongo import — no images-only scope exists).
# Re-running it here re-does the whole pre-apps stage (mongo upsert + mc cp
# overwrite) — redundant but idempotent either way. Kept as its own numbered
# step for output-shape parity with the old 9-step script; see
# task-6-report.md.
banner "Step 9/9 · seed S3 product images"
bash "$ROOT/deploy/scripts/seed.sh" --env aws --stage pre-apps --context microecom-eks

banner "DONE · stack is up"
ALB="$(kubectl -n apps get ingress gateway-alb \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
echo "  Gateway ALB : ${ALB:-<pending — re-check: kubectl -n apps get ingress gateway-alb>}"
echo "  Storefront  : https://shop.microecom.click   ← open in a browser (valid TLS)"
echo "  First apply : DNS propagation + ACM issuance can take a few minutes before it resolves."
echo "  Raw ALB     : http://${ALB:-<pending>}/   (debug only — the host rule means this now 404s)"
echo "  Verify      : padlock is valid; http:// 301-redirects to https://; the funnel completes"
echo "  Remember    : 'make aws-down' when done — the cluster bills ~\$0.25-0.30/hr."
