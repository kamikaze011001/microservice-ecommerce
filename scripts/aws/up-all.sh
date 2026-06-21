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
#   1 up.sh        VPC+EKS+ALB+ESO IRSA+RDS, kubeconfig (RDS outputs exist after)
#   2 push-images  reuse existing ECR images, or PUSH=all to rebuild
#   3 infra-up.sh  ESO + ClusterSecretStore + Mongo/Kafka/SR/Connect/VM/Grafana
#                  + the Mongo CDC connector (must precede app ExternalSecrets)
#   4 seed-mongo   api_role + product + qty-history → Mongo (needs Mongo up)
#   5 seed-secrets RDS JDBC URLs + app config → Secrets Manager (needs step-1
#                  outputs; must precede apps so ExternalSecrets resolve real vals)
#   6 apps         kubectl apply -k overlay; GATE on auth-server + inventory-svc
#   7 seed-rds     accounts/roles/users → RDS (schema from auth-server ddl-auto)
#   8 seed-inv     inventory stock → RDS (tables from inventory-svc ddl-auto)
#   9 [Phase 4c]   S3 product images — skipped (no bucket until 4c)
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

# 2) JWK: the canonical copy is hardcoded in the local vault seed; extract it so
#    the AWS JWK is byte-identical (the gateway caches JWKS by kid). An exported
#    APPLICATION_JWK wins if set.
if [ -z "${APPLICATION_JWK:-}" ]; then
  # 2>/dev/null + || true so a missing/renamed seed.sh yields an empty var and the
  # friendly `need APPLICATION_JWK` below fires — not a raw sed error under set -e.
  APPLICATION_JWK="$(sed -n "s/^[[:space:]]*application\.jwk='\(.*\)'[[:space:]]*\\\\\{0,1\}[[:space:]]*$/\1/p" \
    "$ROOT/k8s/infra/jobs/03-vault-seed/seed.sh" 2>/dev/null | head -n1 || true)"
  export APPLICATION_JWK
fi

# Fail loud, naming the exact file to populate.
need() {  # need <VAR> <where-to-fill>
  local v="$1" where="$2"
  [ -n "${!v:-}" ] || { echo "ERROR: $v is empty — fill it in $where" >&2; exit 1; }
}
need PAYPAL_CLIENT_ID        "docker/.env"
need PAYPAL_CLIENT_SECRET    "docker/.env"
need APPLICATION_MAIL_USERNAME "k8s/.env"
need APPLICATION_MAIL_PASSWORD "k8s/.env"
need APPLICATION_JWK         "k8s/infra/jobs/03-vault-seed/seed.sh (could not extract application.jwk)"

# 3) RDS master password must be in the gitignored tfvars (grep, never echo it).
if ! grep -qE '^[[:space:]]*db_master_password[[:space:]]*=' "$TF/terraform.tfvars" 2>/dev/null; then
  echo "ERROR: db_master_password missing from aws/main/terraform.tfvars" >&2
  echo "  Add:  db_master_password = \"<choose-a-strong-password>\"" >&2
  exit 1
fi
echo "✓ creds resolved (PayPal, mail, JWK), db_master_password set, PUSH=${PUSH}"

# ── Step 1 — cluster + RDS ────────────────────────────────────────────────────
banner "Step 1/9 · terraform apply (VPC + EKS + ALB + ESO IRSA + RDS) — ~15-20 min"
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
banner "Step 4/9 · seed Mongo (api_role + product + qty-history)"
"$ROOT/scripts/aws/seed-mongo.sh"

# ── Step 5 — Secrets Manager (reads RDS outputs from step 1) ──────────────────
banner "Step 5/9 · seed Secrets Manager (RDS JDBC URLs + app config)"
"$ROOT/scripts/aws/seed-secrets.sh"

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
banner "Step 7/9 · seed RDS data (accounts/roles/users)"
"$ROOT/scripts/aws/seed-rds.sh"

# ── Step 8 — RDS inventory stock (tables now exist) ───────────────────────────
banner "Step 8/9 · seed RDS inventory stock"
"$ROOT/scripts/aws/seed-inventory.sh"

# ── Step 9 — S3 product images (Phase 4c) ─────────────────────────────────────
banner "Step 9/9 · S3 product images — DEFERRED"
echo "▶ skipped: no object store on AWS until Phase 4c (S3 + IRSA). The catalog"
echo "  renders with broken <img> links; browse/cart/checkout work without images."

banner "DONE · stack is up"
ALB="$(kubectl -n apps get ingress gateway-alb \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
echo "  Gateway ALB : ${ALB:-<pending — re-check: kubectl -n apps get ingress gateway-alb>}"
echo "  Verify      : login should return a JWT; catalog lists products; cart shows stock"
echo "  Remember    : 'make aws-down' when done — the cluster bills ~\$0.25-0.30/hr."
