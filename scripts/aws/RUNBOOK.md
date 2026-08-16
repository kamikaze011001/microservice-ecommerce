# AWS From-Scratch Bring-Up Runbook

The manual sequence behind `make aws-all`. Run it by hand to learn the ordering
and the failure points; or just run `make aws-all` and let the orchestrator do it.

**Confirmation prompt:** `scripts/aws/up-all.sh` creates real, billed AWS
infrastructure (EKS, VPC + NAT, RDS, ALB), so it asks `Continue? [y/N]` before
doing anything — only a literal `y` proceeds. Run it from an interactive
terminal so the prompt can be answered. Non-interactive/CI runs (no TTY on
stdin) are refused unless you pass `--yes` to opt in explicitly, e.g.
`scripts/aws/up-all.sh --yes` or `PUSH=all scripts/aws/up-all.sh --yes`.

## What persists vs. what rebuilds across `aws-down`

`aws-down` destroys **`aws/main` only** (VPC, EKS, ALB, RDS, ElastiCache). The separate
**`aws/bootstrap`** stack — ECR images, Terraform state bucket, DynamoDB lock —
**survives**. So a from-scratch re-run reuses your pushed images unless you
changed code (then `PUSH=all`).

**Status:** this runbook describes the sequence `scripts/aws/up-all.sh` now
actually runs, repointed onto the canonical `deploy/scripts/` tree in
Phase 8 of the deploy refactor (2026-08-14/15). Every step below has been
verified only offline (render diffs, fixture terraform outputs, equivalence
suites) — **`ENV=aws` has never been deployed for real**, no EKS cluster has
ever been created by this repo, and this runbook itself has never been
executed end-to-end. See `deploy/README.md`'s "Verification status"
sections for exactly what is and isn't proven.

## Prerequisites (one-time)

- `make aws-bootstrap` has been run once (persistent state bucket + ECR).
- `aws/main/terraform.tfvars` contains `db_master_password = "<strong>"` (gitignored).
- `docker/.env` (PayPal) and `deploy/.env` (mail) are filled — same files
  local dev uses. (`deploy/.env` replaced `k8s/.env` in Phase 8 — see
  `deploy/README.md`'s "Losses and leftovers" if you have an old checkout
  with `k8s/.env` still on disk.)
- The JWK is resolved from the committed `deploy/secrets/jwk.private.json`
  for every env — nothing to fill in by hand (it used to be extracted from
  the now-deleted `k8s/infra/jobs/03-vault-seed/seed.sh`).

## Steps

### 1. Cluster + RDS — `make aws-up`
**Why first:** nothing else can run without the cluster, and the RDS endpoints
become readable as Terraform outputs only after this apply (~15–20 min).
**Verify:**
```bash
kubectl get nodes                                   # nodes Ready
terraform -chdir=aws/main output rds_primary_endpoint
terraform -chdir=aws/main output redis_primary_endpoint
```

### 2. Images — `make aws-push svc=all` (skip if ECR is warm)
**Why here:** the apps (step 6) pull from ECR. Skip if you didn't change code —
images survive `aws-down`.
**Verify:** `aws ecr describe-images --repository-name gateway --profile microecom`

### 3. Infra + ESO — `make aws-infra-up`
**Why before secrets/apps:** installs the External Secrets Operator and
ClusterSecretStore (apps' ExternalSecrets can't resolve without it), plus
self-hosted Mongo/Kafka/SR/Connect/VM/Grafana and the Mongo CDC connector.
**Verify:**
```bash
kubectl -n infra get pods                           # mongodb, kafka, etc. Running
kubectl get clustersecretstore
```

### 4. Mongo seed + product images — `deploy/scripts/seed.sh --env aws --stage pre-apps`
**Why before apps serve traffic:** `api_role` drives the gateway's authz —
unseeded, every route 403s; `product`/`productQuantityHistory` is the
catalog. Needs Mongo (step 3) up. Also uploads the 30 sample product JPGs
(`docker/seed-images/<category>/<slug>.jpg`) to
`s3://<bucket>/products/<productId>/<slug>.jpg` in the same pass — one
canonical script covers what `scripts/aws/seed-mongo.sh` and
`scripts/aws/seed-images.sh` used to do separately (both deleted, Phase 8).
Requires `--context` (never an ambient kubectl context — see
`deploy/README.md`'s "k8s context requirement").
```bash
bash deploy/scripts/seed.sh --env aws --stage pre-apps --context microecom-eks
```
**Verify:** `kubectl -n bootstrap logs job/mongo-seed | tail -5` (or the
script's own printed summary); `aws s3 ls s3://<bucket>/products/ --recursive
--profile microecom` lists the uploaded objects.

### 5. Secrets — `deploy/scripts/secrets-seed.sh --env aws`
**Why before apps:** pushes the RDS JDBC URLs + the ElastiCache Redis host (from
step-1 outputs) + app config into Secrets Manager; the apps' ExternalSecrets sync
from here. Reads PayPal/mail from `docker/.env`/`deploy/.env` (exported into
this shell's environment — see the canonical resolver's `${VAR}`
substitution); the JWK is no longer read from an env var at all — it
resolves from the committed `deploy/secrets/jwk.private.json` for every env.
This is the canonical replacement for the deleted `scripts/aws/seed-secrets.sh`.
```bash
bash deploy/scripts/secrets-seed.sh --env aws
```
**Verify:** `aws secretsmanager get-secret-value --secret-id app/ecommerce --profile microecom --query SecretString --output text | head -c 80`

### 6. Apps — `deploy/scripts/aws-deploy.sh` (same as `make deploy ENV=aws`)
**Why the gate:** the next seed stage needs schema that the apps create via
Hibernate `ddl-auto` on first connect — `authorization-server` (accounts) and
`inventory-service` (stock tables). This replaces the deleted
`kubectl apply -k k8s/apps/overlays/aws` — `aws-deploy.sh` resolves the S3
IRSA role ARN, ECR registry, and image tag, then runs
`helm upgrade --install ... --set apps.enabled=true --set infra.enabled=false
--wait --timeout 30m` (see `deploy/README.md`'s "AWS cut-over" section for
the full input-resolution table).
```bash
bash deploy/scripts/aws-deploy.sh
```
**Verify (and gate):**
```bash
kubectl -n apps rollout status deploy/authorization-server --timeout=600s
kubectl -n apps rollout status deploy/inventory-service --timeout=600s
kubectl -n apps get externalsecrets                 # SecretSynced=True
```

### 7. RDS accounts — `deploy/scripts/seed.sh --env aws --stage post-apps`
**Why after step 6:** `deploy/seed/ecommerce.sql` is data-only; the tables
exist only after `authorization-server` started. `seed.sh`'s post-apps stage
checks every target table exists before writing a row, and each table's
import is separately gated on its own row count — safe to re-run. Replaces
the deleted `scripts/aws/seed-rds.sh`.
```bash
bash deploy/scripts/seed.sh --env aws --stage post-apps --context microecom-eks
```
**Verify:** the script prints per-table import counts (or "already seeded"
per table).

### 8. RDS inventory stock — same command as step 7
**Why after step 6:** `inventory_product` / `product_quantity_history` exist
only after `inventory-service` started. Without this, cart shows "0
available". `seed.sh` has no inventory-only scope — its post-apps stage
imports accounts AND the derived inventory rows AND restarts
inventory-service (so `AvailableStockSeeder` rebuilds the Redis
`available:*` counters from the ledger) in one idempotent pass. This
replaces the deleted `scripts/aws/seed-inventory.sh`; running the same
`--stage post-apps` command from step 7 again here is intentionally
redundant (row-count gates make the SQL a no-op, the reconcile restart is
idempotent) — kept as its own numbered step for output-shape parity with the
old 9-step sequence.
```bash
bash deploy/scripts/seed.sh --env aws --stage post-apps --context microecom-eks
```
**Verify:** the script prints row counts seeded (or the tables-not-ready message).

### 9. S3 product images — same command as step 4
Product image upload is not a separate stage — `deploy/scripts/seed.sh`'s
pre-apps stage already uploaded the 30 sample JPGs in step 4. This replaces
the deleted `scripts/aws/seed-images.sh`; re-running `--stage pre-apps` here
is intentionally redundant (mongo upsert + `mc cp` overwrite, both
idempotent) — kept as its own numbered step for output-shape parity with the
old 9-step sequence. The bucket has `force_destroy = true`, so it is emptied
+ destroyed by `aws-down` (re-run after a fresh `aws-up`).
```bash
bash deploy/scripts/seed.sh --env aws --stage pre-apps --context microecom-eks
```
**Verify:** `aws s3 ls s3://<bucket>/products/ --recursive --profile microecom`
lists the objects; the storefront catalog renders real images.

## Teardown
```bash
make aws-down            # deletes Ingress (removes ALB), then terraform destroy
make aws-leak-check      # confirm nothing still bills (ALB, NAT, EIP, EBS, EKS)
```
