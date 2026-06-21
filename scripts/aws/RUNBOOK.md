# AWS From-Scratch Bring-Up Runbook

The manual sequence behind `make aws-all`. Run it by hand to learn the ordering
and the failure points; or just run `make aws-all` and let the orchestrator do it.

## What persists vs. what rebuilds across `aws-down`

`aws-down` destroys **`aws/main` only** (VPC, EKS, ALB, RDS, ElastiCache). The separate
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

### 4. Mongo seed — `scripts/aws/seed-mongo.sh`
**Why before apps serve traffic:** `api_role` drives the gateway's authz —
unseeded, every route 403s; `product` is the catalog. Needs Mongo (step 3) up.
**Verify:**
```bash
kubectl -n bootstrap logs job/mongo-seed | tail -5  # "...counts ... OK"
```

### 5. Secrets — `scripts/aws/seed-secrets.sh`
**Why before apps:** pushes the RDS JDBC URLs + the ElastiCache Redis host (from
step-1 outputs) + app config into Secrets Manager; the apps' ExternalSecrets sync
from here. Reads PayPal/mail
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
