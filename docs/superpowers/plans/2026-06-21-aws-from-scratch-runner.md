# AWS From-Scratch Bring-Up Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single orchestrated `make aws-all` path that brings the whole stack up on AWS/EKS from nothing (post-`aws-down` or fresh account), with the Mongo and RDS-inventory seeds the previous design missed.

**Architecture:** A thin orchestrator (`scripts/aws/up-all.sh`) sequences the existing leaf scripts with the inter-step dependencies enforced as explicit gates (fail-fast credential/tfvars preflight; rollout-status before the post-apps SQL seeds). Two new seed scripts fill the data gaps: `seed-mongo.sh` runs the existing in-cluster `02-mongo-seed` Job verbatim; `seed-inventory.sh` loads RDS stock via the throwaway-`mysql:8.0`-pod pattern `seed-rds.sh` already uses. Credentials are sourced from files that already exist (`docker/.env`, `k8s/.env`, `seed.sh`), so the operator re-enters nothing.

**Tech Stack:** Bash, Make, kubectl, AWS CLI, Terraform outputs, MongoDB `mongoimport`, MySQL client.

**Testing approach (read this first):** This is infra shell scripting — there is no unit-test framework and the real run bills AWS, so **all verification is offline gates** (the spec mandates this). Per task the pass/fail checks are: `bash -n <script>` (syntax), `grep` assertions that required safety/idempotency properties are present, `kubectl kustomize` (overlay builds), and `make -n` (target resolves). The billed end-to-end `make aws-all` is the user's to run; the agent never runs billable AWS/kubectl-apply commands.

**Branch:** `feat/aws-deploy` (already checked out — verify with `git branch --show-current`; do NOT create a new branch).

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/aws/seed-mongo.sh` (new) | Seed Mongo (`api_role` + `product` + `productQuantityHistory`) by running the existing `02-mongo-seed` Job against EKS. |
| `scripts/aws/seed-inventory.sh` (new) | Seed RDS inventory stock (`inventory_product` + `product_quantity_history`) from a throwaway `mysql:8.0` pod. |
| `scripts/aws/up-all.sh` (new) | Orchestrator: preflight → up → push → infra → seed-mongo → seed-secrets → apps(+gate) → seed-rds → seed-inventory → [S3 slot] → summary. |
| `Makefile` (modify) | Add `aws-all` target + `.PHONY` entry. |
| `scripts/aws/RUNBOOK.md` (new) | The by-hand sequence with per-step "why" + verify gates. |

Build order: seed scripts first (Tasks 1–2), then the orchestrator that calls them (Task 3), then the Make target (Task 4), then the runbook (Task 5), then a final offline-gate sweep (Task 6).

---

### Task 1: `scripts/aws/seed-mongo.sh`

**Files:**
- Create: `scripts/aws/seed-mongo.sh`

Faithful standalone copy of the Makefile `k8s-seed` `02-mongo-seed` case: create the two configmaps imperatively (the data lives out-of-tree under `docker/`, so kustomize's configMapGenerator can't be used — this is the documented scar), apply the Job, wait for completion. Works unchanged on AWS because Mongo is in-cluster (`mongodb.infra.svc.cluster.local`) and `infra-up.sh` already creates the `bootstrap` namespace.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Seed MongoDB (api_role + product + productQuantityHistory) on the EKS cluster.
#
# Mongo stays self-hosted in-cluster in Phase 4 (only MySQL/Redis/MinIO move to
# managed services), so the existing k8s/infra/jobs/02-mongo-seed Job runs here
# verbatim — it connects to mongodb.infra.svc.cluster.local. This is the AWS twin
# of the Makefile `k8s-seed` 02-mongo-seed case.
#
# WHY this is critical: without api_role the gateway 403s every route; without
# product the catalog is empty. The Job itself is fail-closed (waits for mongo
# PRIMARY, verifies non-empty counts before reporting success).
#
# The two configMaps are created imperatively (NOT a kustomize generator): the
# data files live under docker/, out of the Job's kustomize tree, and kubectl's
# embedded kustomize forbids out-of-tree configMapGenerator sources. See the
# SCAR note in k8s/infra/jobs/02-mongo-seed/job.yaml.
#
# Idempotent: the Job's seed.sh skips when api_role already has docs; we delete
# the prior Job first because Jobs are immutable.
#
# Usage:  AWS_PROFILE=microecom scripts/aws/seed-mongo.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JOB_DIR="$ROOT/k8s/infra/jobs/02-mongo-seed"

# bootstrap ns is created by infra-up.sh; ensure it exists so this is runnable
# standalone too.
kubectl get ns bootstrap >/dev/null 2>&1 || kubectl create ns bootstrap

echo "▶ (re)creating mongo-seed configmaps in bootstrap ns ..."
kubectl -n bootstrap create configmap mongo-seed-scripts \
  --from-file="$JOB_DIR/seed.sh" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n bootstrap create configmap mongo-seed-data \
  --from-file="$ROOT/docker/api_role.json" \
  --from-file="$ROOT/docker/product.json" \
  --from-file="$ROOT/docker/product-quantity-history.json" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "▶ applying mongo-seed Job ..."
kubectl -n bootstrap delete job mongo-seed --ignore-not-found >/dev/null
kubectl apply -f "$JOB_DIR/job.yaml"

echo "▶ waiting for mongo-seed to complete (the Job verifies non-empty counts) ..."
kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/mongo-seed
echo "✅ mongo seed complete (api_role + product + productQuantityHistory)."
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/aws/seed-mongo.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Offline gate — syntax**

Run: `bash -n scripts/aws/seed-mongo.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Offline gate — reuses the existing Job, doesn't reinvent it**

Run: `grep -c '02-mongo-seed/job.yaml\|mongo-seed-scripts\|mongo-seed-data' scripts/aws/seed-mongo.sh`
Expected: prints a number ≥ 3 (it references the committed Job + both configmaps rather than hand-rolling a Job).

- [ ] **Step 5: Commit**

```bash
git add scripts/aws/seed-mongo.sh
git commit -m "feat(aws): seed-mongo.sh — run 02-mongo-seed Job against EKS

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `scripts/aws/seed-inventory.sh`

**Files:**
- Create: `scripts/aws/seed-inventory.sh`

RDS twin of `scripts/seed/k8s-inventory.sh`. The local script does `kubectl -n infra exec mysql-0` — but there is no in-cluster MySQL on AWS (it's RDS, private, no public endpoint). So this uses the **same throwaway-pod pattern as `seed-rds.sh`**: a one-shot `mysql:8.0` pod in the `apps` namespace (which inherits the node SG that the RDS SG admits on 3306), with `MYSQL_PWD` keeping the password off argv, and RDS host/password read from `terraform output`. The `jq` expressions that turn `docker/product.json` / `docker/product-quantity-history.json` into INSERTs are reused from the local script, switched to `INSERT IGNORE` so a re-run is idempotent without a separate count query (PK = `id`).

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Seed inventory-service's RDS tables:
#   ecommerce_dev.inventory_product        (from docker/product.json)
#   ecommerce_dev.product_quantity_history (from docker/product-quantity-history.json)
#
# WHY: these tables are normally written reactively — inventory_product by the
# Kafka ProductUpdate listener (only fires when product-service SAVES a product),
# product_quantity_history by admin stock ops / PaymentSuccess. The catalog is
# seeded straight into MongoDB (seed-mongo.sh), bypassing the save path, so
# neither table is ever populated and every cart item renders "0 available".
# This is the AWS/RDS twin of scripts/seed/k8s-inventory.sh, mirroring the SAME
# source JSON so product ids line up with the Mongo catalog.
#
# ORDERING: inventory-service creates these tables via Hibernate ddl-auto at
# startup, so run this AFTER inventory-service reaches Running (up-all.sh's
# step-6 rollout gate enforces it). Standalone, we preflight that the tables
# exist and tell you to wait if not.
#
# Like seed-rds.sh, the mysql client runs from a throwaway pod INSIDE the cluster
# (RDS has no public endpoint) with MYSQL_PWD to keep the password off argv.
# INSERT IGNORE makes re-runs idempotent (id is the PK).
#
# Usage:  AWS_PROFILE=microecom scripts/aws/seed-inventory.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT/aws/main"
PRODUCTS_JSON="$ROOT/docker/product.json"
QTY_JSON="$ROOT/docker/product-quantity-history.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
[ -f "$PRODUCTS_JSON" ] || { echo "Missing $PRODUCTS_JSON" >&2; exit 1; }
[ -f "$QTY_JSON" ]      || { echo "Missing $QTY_JSON" >&2; exit 1; }

RDS_HOST="$(terraform -chdir="$TF" output -raw rds_primary_endpoint)"
DB_PASS="$(terraform -chdir="$TF" output -raw db_master_password)"

# Run `mysql <args>` in a one-shot pod; SQL (when loading) is piped via stdin.
run_mysql() {  # run_mysql <mysql-args...>   (optional SQL on stdin)
  kubectl run "inv-seed-${RANDOM}" -n apps --rm -i --restart=Never \
    --image=mysql:8.0 --env=MYSQL_PWD="$DB_PASS" --command -- \
    mysql -h "$RDS_HOST" -uadmin "$@"
}

# Preflight: the tables must exist (inventory-service ddl-auto creates them).
echo "▶ checking inventory tables exist at ${RDS_HOST} ..."
TABLES="$(run_mysql ecommerce_dev -N -e "
  SELECT COUNT(*) FROM information_schema.tables
  WHERE table_schema='ecommerce_dev'
    AND table_name IN ('inventory_product','product_quantity_history');" 2>&1 </dev/null || true)"
NTAB="$(printf '%s' "$TABLES" | tr -dc '0-9')"
if [ "${NTAB:-0}" -lt 2 ]; then
  echo "✋ inventory tables not ready (found ${NTAB:-0}/2)." >&2
  echo "   Start inventory-service once (ddl-auto creates them), then re-run." >&2
  exit 1
fi

# Build INSERT IGNORE statements. Same jq as scripts/seed/k8s-inventory.sh; the
# image_url host rewrite mirrors seed-mongo.sh's catalog rewrite so order_item
# snapshots match the catalog. (S3 isn't wired until Phase 4c, so the host is a
# placeholder either way — kept consistent with Mongo.)
SQL_PRODUCTS="$(jq -r '
  .[] |
  "INSERT IGNORE INTO inventory_product (id, name, price, image_url) VALUES ("
  + "\"" + ._id."$oid" + "\", "
  + "\"" + (.name | gsub("\""; "\\\"")) + "\", "
  + (.price | tostring) + ", "
  + (if .imageUrl then "\"" + (.imageUrl | gsub("\""; "\\\"") | gsub("http://localhost:9000/"; "http://media.microecom.local/")) + "\"" else "NULL" end)
  + ");"' "$PRODUCTS_JSON")"

SQL_QTY="$(jq -r '
  .[] |
  "INSERT IGNORE INTO product_quantity_history (id, product_id, quantity, created_at) VALUES ("
  + "\"" + ._id + "\", "
  + "\"" + .productId + "\", "
  + (.quantity | tostring) + ", "
  + "\"" + (.createdAt."$date" | sub("Z$"; "") | sub("T"; " ")) + "\""
  + ");"' "$QTY_JSON")"

PROD_ROWS="$(printf '%s\n' "$SQL_PRODUCTS" | grep -c INSERT || true)"
QTY_ROWS="$(printf '%s\n' "$SQL_QTY" | grep -c INSERT || true)"
echo "▶ seeding inventory_product (${PROD_ROWS} rows) + product_quantity_history (${QTY_ROWS} rows) ..."
printf '%s\n%s\n' "$SQL_PRODUCTS" "$SQL_QTY" | run_mysql ecommerce_dev
echo "✅ inventory stock seed complete."
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/aws/seed-inventory.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Offline gate — syntax**

Run: `bash -n scripts/aws/seed-inventory.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Offline gate — password is never on argv, and re-run is idempotent**

Run: `grep -q 'MYSQL_PWD=' scripts/aws/seed-inventory.sh && grep -q 'INSERT IGNORE' scripts/aws/seed-inventory.sh && ! grep -q -- '-p"\$DB_PASS"' scripts/aws/seed-inventory.sh && echo SAFE`
Expected: prints `SAFE` (password via env not `-p<pass>`, and INSERT IGNORE present for idempotency).

- [ ] **Step 5: Offline gate — reads RDS coords from terraform, mirrors seed-rds.sh**

Run: `grep -c 'terraform -chdir.*output -raw\|kubectl run "inv-seed' scripts/aws/seed-inventory.sh`
Expected: prints a number ≥ 2.

- [ ] **Step 6: Commit**

```bash
git add scripts/aws/seed-inventory.sh
git commit -m "feat(aws): seed-inventory.sh — RDS stock seed via throwaway mysql pod

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `scripts/aws/up-all.sh` (orchestrator)

**Files:**
- Create: `scripts/aws/up-all.sh`

The from-scratch chain. Step 0 is a fail-fast preflight that loads credentials from files that already exist (`docker/.env`, `k8s/.env`, the JWK from `seed.sh`) and verifies `db_master_password` is in tfvars — before the ~15-min apply. Steps 1–8 delegate to leaf scripts in dependency order; step 6 carries the one hard sequencing gate (wait `authorization-server` AND `inventory-service` before the post-apps SQL seeds). Step 9 is a labeled no-op slot for the Phase-4c S3 image seed.

- [ ] **Step 1: Write the script**

```bash
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
# change to rebuild.
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
  set -a; # shellcheck disable=SC1090
  . "$f"; set +a
}
load_env_file "$ROOT/docker/.env"
load_env_file "$ROOT/k8s/.env"

# 2) JWK: the canonical copy is hardcoded in the local vault seed; extract it so
#    the AWS JWK is byte-identical (the gateway caches JWKS by kid). An exported
#    APPLICATION_JWK wins if set.
if [ -z "${APPLICATION_JWK:-}" ]; then
  APPLICATION_JWK="$(sed -n "s/^[[:space:]]*application\.jwk='\(.*\)'[[:space:]]*\\\\\{0,1\}[[:space:]]*$/\1/p" \
    "$ROOT/k8s/infra/jobs/03-vault-seed/seed.sh" | head -n1)"
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
kubectl apply -k "$ROOT/k8s/apps/overlays/aws"

# Both gate a post-apps SQL seed: auth-server's ddl-auto creates the account
# schema (step 7), inventory-service's creates the stock tables (step 8).
echo "▶ waiting for authorization-server + inventory-service (they create the RDS schema) ..."
kubectl -n apps rollout status deploy/authorization-server --timeout=600s
kubectl -n apps rollout status deploy/inventory-service --timeout=600s
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
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/aws/up-all.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Offline gate — syntax**

Run: `bash -n scripts/aws/up-all.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Offline gate — every leaf script it calls exists**

Run:
```bash
for s in up.sh push-images.sh infra-up.sh seed-mongo.sh seed-secrets.sh seed-rds.sh seed-inventory.sh; do
  test -f "scripts/aws/$s" && echo "ok $s" || echo "MISSING $s"
done
```
Expected: seven `ok` lines, no `MISSING`.

- [ ] **Step 5: Offline gate — the rollout gate waits on both schema-owning services**

Run: `grep -c 'rollout status deploy/authorization-server\|rollout status deploy/inventory-service' scripts/aws/up-all.sh`
Expected: prints `2`.

- [ ] **Step 6: Offline gate — secrets are not echoed**

Run: `! grep -nE 'echo.*(APPLICATION_JWK|DB_PASS|MAIL_PASSWORD|CLIENT_SECRET|db_master_password)[^=]*\}' scripts/aws/up-all.sh && echo "no secret echoed"`
Expected: prints `no secret echoed` (the tfvars check greps, never prints the value).

- [ ] **Step 7: Commit**

```bash
git add scripts/aws/up-all.sh
git commit -m "feat(aws): up-all.sh — from-scratch bring-up orchestrator

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `make aws-all` target

**Files:**
- Modify: `Makefile` (the AWS section near line 496–525)

- [ ] **Step 1: Add `aws-all` to the AWS `.PHONY` line**

Find (line ~496):
```makefile
.PHONY: aws-bootstrap aws-up aws-push aws-infra-up aws-down aws-leak-check
```
Replace with:
```makefile
.PHONY: aws-bootstrap aws-up aws-push aws-infra-up aws-down aws-leak-check aws-all
```

- [ ] **Step 2: Add the target after the `aws-leak-check` recipe**

Find (line ~523–525):
```makefile
# Confirm nothing is still billing after a teardown (ALBs, NAT, EIPs, EBS, EKS).
aws-leak-check:
	@scripts/aws/leak-check.sh
```
Append immediately after:
```makefile

# Full from-scratch bring-up: cluster+RDS → images → infra → seed-mongo →
# secrets → apps(+gate) → seed-rds → seed-inventory. The cloud twin of
# `make k8s-bootstrap`. Every step bills AWS — run it yourself. Default reuses
# ECR images (they survive aws-down); PUSH=all rebuilds after a code change.
aws-all:
	@scripts/aws/up-all.sh
```

- [ ] **Step 3: Offline gate — target resolves and points at the script**

Run: `make -n aws-all`
Expected: prints `scripts/aws/up-all.sh` (the recipe), exit 0 — no "No rule to make target".

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat(aws): make aws-all — one-command from-scratch bring-up

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `scripts/aws/RUNBOOK.md`

**Files:**
- Create: `scripts/aws/RUNBOOK.md`

The by-hand path for interview-prep learning: each step's command, *why* it sits in that position (the dependency it satisfies), and a *verify gate* before moving on.

- [ ] **Step 1: Write the runbook**

````markdown
# AWS From-Scratch Bring-Up Runbook

The manual sequence behind `make aws-all`. Run it by hand to learn the ordering
and the failure points; or just run `make aws-all` and let the orchestrator do it.

## What persists vs. what rebuilds across `aws-down`

`aws-down` destroys **`aws/main` only** (VPC, EKS, ALB, RDS). The separate
**`aws/bootstrap`** stack — ECR images, Terraform state bucket, DynamoDB lock —
**survives**. So a from-scratch re-run reuses your pushed images unless you
changed code (then `PUSH=all`).

## Prerequisites (one-time)

- `make aws-bootstrap` has been run once (persistent state bucket + ECR).
- `aws/main/terraform.tfvars` contains `db_master_password = "<strong>"` (gitignored).
- `docker/.env` (PayPal) and `k8s/.env` (mail) are filled — same files local dev uses.
- The JWK is auto-extracted from `k8s/infra/jobs/03-vault-seed/seed.sh` — nothing to fill.

## Steps

### 1. Cluster + RDS — `make aws-up`
**Why first:** nothing else can run without the cluster, and the RDS endpoints
become readable as Terraform outputs only after this apply (~15–20 min).
**Verify:**
```bash
kubectl get nodes                                   # nodes Ready
terraform -chdir=aws/main output rds_primary_endpoint
```

### 2. Images — `make aws-push svc=all` (skip if ECR is warm)
**Why here:** the apps (step 6) pull from ECR. Skip if you didn't change code —
images survive `aws-down`.
**Verify:** `aws ecr describe-images --repository-name microecom/gateway --profile microecom`

### 3. Infra + ESO — `make aws-infra-up`
**Why before secrets/apps:** installs the External Secrets Operator and
ClusterSecretStore (apps' ExternalSecrets can't resolve without it), plus
self-hosted Mongo/Kafka/SR/Connect/VM/Grafana and the Mongo CDC connector.
**Verify:**
```bash
kubectl -n infra get pods                           # mongodb, kafka, etc. Running
kubectl get clustersecretstore
```

### 4. Mongo seed — `scripts/aws/seed-mongo.sh`
**Why before apps serve traffic:** `api_role` drives the gateway's authz —
unseeded, every route 403s; `product` is the catalog. Needs Mongo (step 3) up.
**Verify:**
```bash
kubectl -n bootstrap logs job/mongo-seed | tail -5  # "...counts ... OK"
```

### 5. Secrets — `scripts/aws/seed-secrets.sh`
**Why before apps:** pushes the RDS JDBC URLs (from step-1 outputs) + app config
into Secrets Manager; the apps' ExternalSecrets sync from here. Reads PayPal/mail
from `docker/.env`/`k8s/.env` and the JWK from `seed.sh` if not already exported.
**Verify:** `aws secretsmanager get-secret-value --secret-id app/ecommerce --profile microecom --query SecretString --output text | head -c 80`

### 6. Apps — `kubectl apply -k k8s/apps/overlays/aws`
**Why the gate:** the next two seeds need schema that the apps create via
Hibernate `ddl-auto` on first connect — `authorization-server` (accounts) and
`inventory-service` (stock tables).
**Verify (and gate):**
```bash
kubectl -n apps rollout status deploy/authorization-server --timeout=600s
kubectl -n apps rollout status deploy/inventory-service --timeout=600s
kubectl -n apps get externalsecrets                 # SecretSynced=True
```

### 7. RDS accounts — `scripts/aws/seed-rds.sh`
**Why after step 6:** `ecommerce.sql` is data-only; the tables exist only after
`authorization-server` started. Guarded — skips if already seeded.
**Verify:** the script prints `account/role/user` complete (or "already seeded").

### 8. RDS inventory stock — `scripts/aws/seed-inventory.sh`
**Why after step 6:** `inventory_product` / `product_quantity_history` exist only
after `inventory-service` started. Without this, cart shows "0 available".
Idempotent (`INSERT IGNORE`).
**Verify:** the script prints row counts seeded (or the tables-not-ready message).

### 9. S3 product images — DEFERRED to Phase 4c
No object store on AWS yet (no bucket/IRSA; `core-s3` still points at an
undeployed MinIO). Catalog images 404 until 4c; browse/cart/checkout work.

## Teardown
```bash
make aws-down            # deletes Ingress (removes ALB), then terraform destroy
make aws-leak-check      # confirm nothing still bills (ALB, NAT, EIP, EBS, EKS)
```
````

- [ ] **Step 2: Offline gate — the runbook covers every step and the persistence note**

Run: `grep -cE '^### [1-9]\.|What persists' scripts/aws/RUNBOOK.md`
Expected: prints a number ≥ 10 (9 numbered steps + the persistence heading).

- [ ] **Step 3: Commit**

```bash
git add scripts/aws/RUNBOOK.md
git commit -m "docs(aws): RUNBOOK.md — by-hand from-scratch sequence with verify gates

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Final offline-gate sweep

**Files:** none (verification only).

- [ ] **Step 1: Syntax-check all three new scripts**

Run: `for s in seed-mongo seed-inventory up-all; do bash -n "scripts/aws/$s.sh" && echo "ok $s"; done`
Expected: three `ok` lines, exit 0.

- [ ] **Step 2: The apps overlay still builds (up-all applies it)**

Run: `kubectl kustomize k8s/apps/overlays/aws >/dev/null && echo "overlay builds"`
Expected: prints `overlay builds`, exit 0.

- [ ] **Step 3: The make target resolves**

Run: `make -n aws-all`
Expected: prints `scripts/aws/up-all.sh`, exit 0.

- [ ] **Step 4: No secret literals were committed**

Run: `git grep -nE 'PAYPAL_CLIENT_SECRET=|MAIL_PASSWORD=[^$]|db_master_password *= *"' -- scripts/aws/ Makefile || echo "clean"`
Expected: prints `clean` (the scripts read secrets from files/outputs, never inline them).

- [ ] **Step 5: Confirm on the right branch, then report**

Run: `git branch --show-current`
Expected: `feat/aws-deploy`. Report the five commits (Tasks 1–5) to the user and hand off the billed `make aws-all` run.
```
```

---

## Self-Review

**1. Spec coverage:**
- Orchestrator `up-all.sh` with the 9-step sequence → Task 3 ✓
- `seed-mongo.sh` (the missing Mongo seed) → Task 1 ✓
- `seed-inventory.sh` (the missing stock seed) → Task 2 ✓
- `make aws-all` + `.PHONY` → Task 4 ✓
- `RUNBOOK.md` with per-step why + verify → Task 5 ✓
- Credential sourcing (docker/.env, k8s/.env, JWK from seed.sh, tfvars) → Task 3 Step 1 + gates ✓
- `PUSH=reuse` default / `PUSH=all` → Task 3 ✓
- Rollout gate on auth-server AND inventory-service → Task 3 Step 5 gate ✓
- S3 deferred slot → Task 3 step 9 + runbook §9 ✓
- Offline-gates-only verification (no billed runs by agent) → every task's gate steps + Task 6 ✓
- Branch `feat/aws-deploy` → header + Task 6 Step 5 ✓
- "What persists across aws-down" → up-all.sh header + runbook ✓

**2. Placeholder scan:** No TBD/TODO. The step-9 "S3 DEFERRED" is intentional and labeled (matches the spec's out-of-scope), not a gap. Every code step contains complete, runnable content.

**3. Type/name consistency:** Script names match across tasks (`seed-mongo.sh`, `seed-inventory.sh`, `up-all.sh`); the orchestrator's Task 3 Step 4 gate lists exactly the seven leaf scripts that exist after Tasks 1–2 + the pre-existing ones; `make aws-all` recipe path matches Task 3's filename; `terraform output` names (`rds_primary_endpoint`, `db_master_password`) match the committed `aws/main/outputs.tf`; namespace `bootstrap`/`apps`/`infra` usage matches the existing scripts.
