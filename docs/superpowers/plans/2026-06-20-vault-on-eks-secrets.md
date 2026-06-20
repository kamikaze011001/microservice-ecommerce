# Vault-on-EKS Secrets (Secrets Manager + ESO, configtree) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace self-managed Vault on EKS with AWS Secrets Manager + External Secrets Operator (ESO), so every JVM service boots from the *same image* on kind (Vault) and EKS (Secrets Manager via a mounted `configtree`), with secret values kept out of Terraform state.

**Architecture:** Terraform declares empty Secrets Manager containers + an ESO IRSA role (HUMAN checkpoint). `seed-secrets.sh` (the cloud twin of the Vault seed) writes values. ESO materializes one k8s Secret per service whose keys are the exact dotted property names; pods mount it and read it via `SPRING_CONFIG_IMPORT=optional:configtree:/etc/app-config/` while `SPRING_CLOUD_VAULT_ENABLED=false` removes Vault from the boot path. No source/`.yml` change — Vault-vs-Secrets-Manager is purely an overlay concern.

**Tech Stack:** Terraform (`terraform-aws-modules/iam` IRSA submodule, `aws_secretsmanager_secret`), AWS CLI, External Secrets Operator (Helm), kustomize overlays/components, Spring Boot configtree property source.

**Spec:** `docs/superpowers/specs/2026-06-20-vault-on-eks-secrets-design.md`

**Coworking note (learning mode):** Tasks tagged **[HUMAN ✍️]** are Terraform/AWS resource blocks the user writes themselves (Claude scaffolds skeleton + teaching comments, then reviews — Claude does NOT write the solution). Everything else (scripts, k8s manifests, overlay patches) Claude implements directly. The user runs every `terraform apply` and every `aws`/`kubectl` command that bills the account `583178372344` (profile `microecom`, region `ap-southeast-1`).

**Scope:** This plan builds the secrets *mechanism* and proves it on two services: **gateway** (Phase 2, no secrets, vault-off only) and **authorization-server** (Phase 3, the canonical secret consumer — db creds + RSA JWK + token config). A generator (Task 9) emits the per-service artifacts for the remaining 9 services, since their base manifests and ECR images already exist. Out of scope: the broader "all services on EKS" deployment concerns (replicas/HPA/PDB, browser-facing URLs for payment/s3, RDS/ElastiCache) — those are a separate plan.

**Verification model:** This is infra/config, not unit-testable code — there is no `pytest`. Each task's "test" is a concrete `apply` + a `kubectl`/`aws` assertion with expected output (the gate ladder from the spec). Treat a non-matching assertion exactly like a failing test: stop and fix before moving on.

---

## File Structure

| File | Responsibility | Owner |
|---|---|---|
| `k8s/apps/overlays/aws/patch-gateway-vault-off.yaml` | Phase-2 gateway env patch (`SPRING_CLOUD_VAULT_ENABLED=false`) | CLAUDE |
| `aws/main/secrets.tf` | ESO IRSA role + 11 empty Secrets Manager containers | **HUMAN ✍️** |
| `aws/main/outputs.tf` (modify) | export `eso_irsa_role_arn` for the ClusterSecretStore SA | CLAUDE |
| `scripts/aws/services-secrets.list` | single source: service → AWS secret path | CLAUDE |
| `scripts/aws/seed-secrets.sh` | push per-service JSON values to Secrets Manager | CLAUDE |
| `scripts/aws/infra-up.sh` (modify) | install ESO via Helm + apply ClusterSecretStore | CLAUDE |
| `k8s/infra/manifests/external-secrets-store.yaml` | ESO ServiceAccount (IRSA) + ClusterSecretStore | CLAUDE |
| `k8s/apps/overlays/aws/components/spring-secrets/` | reusable kustomize component: configtree env + volume mount | CLAUDE |
| `k8s/apps/overlays/aws/authorization-server/` | auth-server ExternalSecret + volume patch + kustomization | CLAUDE |
| `scripts/aws/gen-aws-overlay.sh` | generate ExternalSecret + volume patch for the remaining services | CLAUDE |
| `scripts/aws/down.sh` (modify) | teardown: delete ExternalSecrets, leak-guard Secrets Manager | CLAUDE |

---

## Task 1: Phase 2 — gateway minimal unblock (vault-off)

The gateway needs no secrets to boot and already has in-cluster discovery (k8s profile → `lb://` resolves; the `gateway.routes.*` URI overrides are belt-and-suspenders). So it gets ONLY `SPRING_CLOUD_VAULT_ENABLED=false`. This proves the image→pod→ALB path and commits the currently-untracked gateway overlay.

**Files:**
- Create: `k8s/apps/overlays/aws/patch-gateway-vault-off.yaml`
- Modify: `k8s/apps/overlays/aws/kustomization.yaml`
- Commit (currently untracked): `k8s/apps/overlays/aws/{namespace.yaml,ingress-gateway.yaml,kustomization.yaml}`

- [ ] **Step 1: Write the vault-off patch**

Create `k8s/apps/overlays/aws/patch-gateway-vault-off.yaml`:

```yaml
# Phase 2 unblock: the gateway's application.yml has
# `spring.config.import: optional:vault://`, but `spring.cloud.vault.fail-fast:
# true` makes a missing Vault FATAL (createLeasingPropertySourceFailFast) — the
# `optional:` prefix does not save it. Disabling the Vault client entirely stops
# the JVM from dialing vault.infra.svc.cluster.local (which doesn't exist on EKS).
# The gateway needs no secrets to boot; its routes resolve via Spring Cloud
# Kubernetes discovery (SPRING_PROFILES_ACTIVE=k8s, already set in base).
# Phase 3 replaces this whole patch with the shared spring-secrets component.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  namespace: apps
spec:
  template:
    spec:
      containers:
        - name: gateway
          env:
            - { name: SPRING_CLOUD_VAULT_ENABLED, value: "false" }
```

- [ ] **Step 2: Reference the patch in the overlay**

In `k8s/apps/overlays/aws/kustomization.yaml`, add to the existing `patches:` list (which already has the nginx-Ingress `$patch: delete`):

```yaml
patches:
  - path: patch-gateway-vault-off.yaml      # ADD THIS ENTRY
  - target:
      kind: Ingress
      name: gateway
      namespace: apps
    patch: |-
      $patch: delete
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: gateway
        namespace: apps
```

- [ ] **Step 3: Render-test the overlay locally (no cluster needed)**

Run: `kubectl kustomize k8s/apps/overlays/aws | grep -A2 SPRING_CLOUD_VAULT_ENABLED`
Expected: shows `name: SPRING_CLOUD_VAULT_ENABLED` / `value: "false"` on the gateway Deployment, and the image is the ECR one (`...dkr.ecr.ap-southeast-1.amazonaws.com/gateway:dev`).

- [ ] **Step 4: Apply and verify the pod boots (HUMAN runs — billed cluster)**

Run: `kubectl apply -k k8s/apps/overlays/aws && kubectl -n apps rollout status deploy/gateway --timeout=4m`
Expected: `deployment "gateway" successfully rolled out`. Then `kubectl -n apps get pod -l app=gateway` shows `1/1 Running` (no CrashLoopBackOff, no `UnknownHostException: vault...` in `kubectl -n apps logs deploy/gateway`).

- [ ] **Step 5: Verify the ALB answers**

Run: `kubectl -n apps get ingress gateway-alb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'` to get the ALB DNS, then `curl -s -o /dev/null -w '%{http_code}\n' http://<alb-dns>/actuator/health` — note `/actuator/**` is NOT routed by the gateway, so expect a gateway 404/401, which still proves the ALB→pod path is live. A `200` from any PERMIT_ALL route (`http://<alb-dns>/product-service/v1/products`) is the stronger proof once product-service exists; for Phase 2 any HTTP status (not a connection timeout) from the ALB is the pass condition.
Expected: an HTTP status code prints (e.g. `404`/`401`/`200`), NOT `000`/timeout.

- [ ] **Step 6: Commit**

```bash
git add k8s/apps/overlays/aws/namespace.yaml \
        k8s/apps/overlays/aws/ingress-gateway.yaml \
        k8s/apps/overlays/aws/kustomization.yaml \
        k8s/apps/overlays/aws/patch-gateway-vault-off.yaml
git commit -m "feat(aws): gateway on ALB from ECR, Vault disabled (Phase 2 unblock)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Terraform — Secrets Manager containers + ESO IRSA  **[HUMAN ✍️]**

This is the keystone learning task. Claude scaffolds `secrets.tf` with teaching comments (mirroring `storage.tf` / `alb-controller.tf`); the **user** writes the `module "eso_irsa"` block and the `aws_secretsmanager_secret` containers, then says "review".

**Files:**
- Create: `aws/main/secrets.tf`

- [ ] **Step 1: Claude writes the scaffold (teaching comments only, no solution)**

Create `aws/main/secrets.tf` with exactly this content (the HUMAN fills the two marked blocks):

```hcl
# aws/main/secrets.tf  —  [CHECKPOINT — HUMAN ✍️]  (Phase 3, Secrets)
#
# WHY THIS FILE EXISTS
# Every JVM service used to read its config from a self-managed Vault pod. On EKS
# we replace Vault with AWS Secrets Manager + the External Secrets Operator (ESO).
# This file declares, in Terraform:
#   PART A — the EMPTY secret CONTAINERS (one per service). No values here — values
#            are pushed later by scripts/aws/seed-secrets.sh, so nothing secret
#            ever lands in tfstate.
#   PART B — the IRSA role ESO assumes to call secretsmanager:GetSecretValue.
#            Same IRSA shape you already wrote for the ALB controller and the EBS
#            CSI driver — open alb-controller.tf / storage.tf side by side.
#
# ─────────────────────────────────────────────────────────────────────────────
# The 11 service paths (kept in a local so PART A can for_each over them and the
# IRSA policy in PART B can scope to exactly these ARNs).
locals {
  secret_services = [
    "core-s3", "ecommerce", "authorization-server", "gateway",
    "product-service", "inventory-service", "order-service",
    "orchestrator-service", "payment-service", "bff-service",
    "mock-paypal-service",
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# PART A — [HUMAN ✍️]  one empty Secrets Manager container per service.
#
# Declare an aws_secretsmanager_secret with for_each over local.secret_services.
# Requirements:
#   - name = "app/${each.value}"            # the path ESO will read (app/<service>)
#   - recovery_window_in_days = 0           # ephemeral: allow immediate recreate,
#                                           #   no 30-day soft-delete that blocks a
#                                           #   teardown/re-apply cycle
#   - DO NOT set a secret_string here       # values come from seed-secrets.sh
#
# Reference: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret
#
# Write `resource "aws_secretsmanager_secret" "app" { ... }` below.


# ─────────────────────────────────────────────────────────────────────────────
# PART B — [HUMAN ✍️]  the ESO IRSA role.
#
# Use the SAME IRSA submodule as alb_irsa / ebs_csi_irsa. ESO has a built-in
# "magic flag" (like attach_load_balancer_controller_policy / attach_ebs_csi_policy):
#
#   module "eso_irsa" {
#     source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#     version = "~> 5.0"
#
#     role_name = "${var.project}-external-secrets"
#     attach_external_secrets_policy        = true                       # the magic flag
#     external_secrets_secrets_manager_arns = [for s in aws_secretsmanager_secret.app : s.arn]
#
#     oidc_providers = {
#       main = {
#         provider_arn               = module.eks.oidc_provider_arn
#         namespace_service_accounts = ["infra:external-secrets"]        # ESO SA we create in Task 5
#       }
#     }
#   }
#
# English: "the k8s ServiceAccount infra/external-secrets may assume this IAM role,
# and the role may GetSecretValue on exactly the app/* secrets above." Least
# privilege — ESO can read these secrets and nothing else.
#
# 🎓 Interview prep — be ready to explain:
#   - Why scope external_secrets_secrets_manager_arns to the 11 ARNs instead of "*"
#     (blast radius: a compromised ESO can't read unrelated secrets).
#   - Why values live in the seed script, not here (tfstate is plaintext-at-rest in
#     S3; keeping values out of state means a state leak ≠ a secrets leak).
#   - IRSA vs static IAM user keys in the cluster (no long-lived creds; STS issues
#     short-lived tokens scoped to the SA).
#
# Write `module "eso_irsa" { ... }` below, then tell Claude "review".
```

- [ ] **Step 2: HUMAN writes PART A + PART B, then says "review"**

The user adds the `aws_secretsmanager_secret "app"` `for_each` resource and the `module "eso_irsa"` block. Claude reviews against the requirements in the comments (name pattern, `recovery_window_in_days = 0`, no `secret_string`, the magic flag, ARN-scoped policy, correct SA `infra:external-secrets`).

- [ ] **Step 3: Validate (HUMAN runs)**

Run: `cd aws/main && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Plan and apply (HUMAN runs — billed)**

Run: `cd aws/main && terraform apply` (review the plan: 11 `aws_secretsmanager_secret` + 1 IAM role/policy to add, 0 to change/destroy).
Expected: `Apply complete!`. Then `aws secretsmanager list-secrets --region ap-southeast-1 --query 'SecretList[].Name' --output text` lists all 11 `app/<service>` paths.

- [ ] **Step 5: Commit (HUMAN — state/tfvars stay gitignored)**

```bash
git add aws/main/secrets.tf
git commit -m "feat(aws): Secrets Manager containers + ESO IRSA role

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Export the ESO IRSA role ARN

The ClusterSecretStore's ServiceAccount must be annotated with the ESO role ARN. Export it from Terraform so `infra-up.sh` can read it.

**Files:**
- Modify: `aws/main/outputs.tf`

- [ ] **Step 1: Add the output**

Append to `aws/main/outputs.tf`:

```hcl
output "eso_irsa_role_arn" {
  description = "IAM role ARN the External Secrets Operator ServiceAccount assumes (IRSA)"
  value       = module.eso_irsa.iam_role_arn
}
```

- [ ] **Step 2: Verify the output resolves (HUMAN runs)**

Run: `cd aws/main && terraform output eso_irsa_role_arn`
Expected: prints `arn:aws:iam::583178372344:role/microecom-external-secrets` (no error).

- [ ] **Step 3: Commit**

```bash
git add aws/main/outputs.tf
git commit -m "feat(aws): output ESO IRSA role ARN

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Seed script — push values to Secrets Manager

The cloud twin of the Vault seed. Values mirror `k8s/infra/jobs/03-vault-seed/seed.sh` (the EKS-correct in-cluster Service DNS — identical on kind and EKS). Genuine user-owned creds (PayPal, mail) are read from the environment, never inlined. JSON keys are the **exact dotted property names** so ESO → configtree round-trips them.

**Files:**
- Create: `scripts/aws/services-secrets.list`
- Create: `scripts/aws/seed-secrets.sh`

- [ ] **Step 1: Create the service list (single source of truth)**

Create `scripts/aws/services-secrets.list`:

```
# service-name (also the app/<name> Secrets Manager path). One per line.
core-s3
ecommerce
authorization-server
gateway
product-service
inventory-service
order-service
orchestrator-service
payment-service
bff-service
mock-paypal-service
```

- [ ] **Step 2: Write the seed script**

Create `scripts/aws/seed-secrets.sh` (mark executable in Step 3). Each service's JSON is built with `jq -n` from dotted-key args; `put-secret-value` is idempotent (writes a new version).

```bash
#!/usr/bin/env bash
# Push per-service config+secrets into AWS Secrets Manager as JSON whose keys are
# the EXACT dotted Spring property names. ESO materializes these verbatim into a
# k8s Secret; the pod mounts it and reads it via configtree (filename = property).
#
# This is the cloud twin of k8s/infra/jobs/03-vault-seed/seed.sh. Non-secret
# config (ports, in-cluster Service DNS, kafka topics) is identical kind<->EKS, so
# the values match seed.sh. Genuine user-owned creds (PayPal, mail) are read from
# the environment so they never live in git. Run AFTER `terraform apply` (the
# containers must exist) and BEFORE `kubectl apply -k` the apps overlay.
#
# Usage:  AWS_PROFILE=microecom PAYPAL_CLIENT_ID=... PAYPAL_CLIENT_SECRET=... \
#         APPLICATION_MAIL_USERNAME=... APPLICATION_MAIL_PASSWORD=... \
#         scripts/aws/seed-secrets.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
REGION="${AWS_REGION:-ap-southeast-1}"

# Required user-owned creds (fail loudly if absent rather than seeding blanks).
: "${PAYPAL_CLIENT_ID:?set PAYPAL_CLIENT_ID}"
: "${PAYPAL_CLIENT_SECRET:?set PAYPAL_CLIENT_SECRET}"
: "${APPLICATION_MAIL_USERNAME:?set APPLICATION_MAIL_USERNAME}"
: "${APPLICATION_MAIL_PASSWORD:?set APPLICATION_MAIL_PASSWORD}"

# The stable RSA signing JWK — MUST be byte-identical to seed.sh's application.jwk
# (the gateway caches JWKS by kid; a different key breaks every token). Sourced
# from the env or a file to avoid a second copy drifting; export APPLICATION_JWK.
: "${APPLICATION_JWK:?set APPLICATION_JWK (the private RSA JWK JSON from seed.sh)}"

put() {  # put <service> <json>
  local svc="$1" json="$2"
  echo "▶ app/${svc}"
  aws secretsmanager put-secret-value --region "$REGION" \
    --secret-id "app/${svc}" --secret-string "$json" >/dev/null
}

DNS=svc.cluster.local

put core-s3 "$(jq -n '{
  "s3.endpoint":"http://minio.infra.'"$DNS"':9000",
  "s3.public-endpoint":"http://media.microecom.local",
  "s3.region":"us-east-1","s3.bucket":"ecommerce-media",
  "s3.access-key":"minioadmin","s3.secret-key":"minioadmin","s3.path-style":"true",
  "s3.public-base-url":"http://media.microecom.local/ecommerce-media",
  "s3.presign-ttl":"PT5M","s3.max-upload-size":"5242880",
  "s3.allowed-types":"image/jpeg,image/png,image/webp"
}')"

put ecommerce "$(jq -n \
  --arg mu "$APPLICATION_MAIL_USERNAME" --arg mp "$APPLICATION_MAIL_PASSWORD" '{
  "spring.datasource.master.url":"jdbc:mysql://mysql.infra.'"$DNS"':3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.master.username":"root","spring.datasource.master.password":"root",
  "spring.datasource.master.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.datasource.slave1.url":"jdbc:mysql://mysql-replica.infra.'"$DNS"':3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.slave1.username":"root","spring.datasource.slave1.password":"root",
  "spring.datasource.slave1.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.datasource.slave2.url":"jdbc:mysql://mysql-replica.infra.'"$DNS"':3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.slave2.username":"root","spring.datasource.slave2.password":"root",
  "spring.datasource.slave2.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.data.redis.host":"redis-master.infra.'"$DNS"'","spring.data.redis.port":"6379",
  "spring.data.redis.password":"","spring.data.redis.database":"0",
  "spring.data.mongodb.uri":"mongodb://ecommerce:ecommerce123@mongodb.infra.'"$DNS"':27017/ecommerce_inventory?authSource=admin",
  "spring.data.mongodb.database":"ecommerce_inventory",
  "spring.kafka.bootstrap-servers":"kafka.infra.'"$DNS"':9092",
  "spring.kafka.properties.schema.registry.url":"http://schema-registry.infra.'"$DNS"':8081",
  "eureka.client.enabled":"false",
  "spring.mail.host":"smtp.gmail.com","spring.mail.port":"587","spring.mail.protocol":"smtp",
  "spring.mail.properties.mail.smtp.auth":"true","spring.mail.properties.mail.smtp.starttls.enable":"true",
  "spring.mail.username":$mu,"spring.mail.password":$mp,
  "management.metrics.distribution.percentiles-histogram.http.server.requests":"true"
}')"

put authorization-server "$(jq -n --arg jwk "$APPLICATION_JWK" '{
  "server.port":"6666",
  "application.access-token.life-time":"900000",
  "application.refresh-token.life-time":"604800000",
  "application.authentication-key-id":"ecommerce-auth-key-2024",
  "application.jwk":$jwk
}')"

put gateway "$(jq -n '{
  "server.port":"6868",
  "application.jwk-set-uri":"http://authorization-server/authorization-server/.well-known/jwks.json",
  "jwt.token.retry.max-attempts":"3","jwt.token.retry.delay":"500",
  "jwt.token.cache.refresh-minutes":"30","jwt.token.cache.force-refresh-threshold":"5",
  "gateway.routes.authorization-server.uri":"http://authorization-server.apps.'"$DNS"':6666",
  "gateway.routes.inventory-service.uri":"http://inventory-service.apps.'"$DNS"':6969",
  "gateway.routes.product-service.uri":"http://product-service.apps.'"$DNS"':7777",
  "gateway.routes.order-service.uri":"http://order-service.apps.'"$DNS"':9696",
  "gateway.routes.payment-service.uri":"http://payment-service.apps.'"$DNS"':8484",
  "gateway.routes.bff-service.uri":"http://bff-service.apps.'"$DNS"':8087",
  "gateway.routes.mock-paypal-service.uri":"http://mock-paypal-service.apps.'"$DNS"':8585"
}')"

put product-service "$(jq -n '{
  "server.port":"7777",
  "application.kafka.topics.inventory-service.product.update":"inventory-service.product.update",
  "application.kafka.topics.product-service.product.update-quantity":"product-service.product.update-quantity",
  "application.kafka.group-id.product-service.product.update-quantity":"product-service.product.update-quantity"
}')"

put inventory-service "$(jq -n '{
  "server.port":"6969","grpc.server.port":"9090",
  "application.kafka.topics.inventory-service.product.update":"inventory-service.product.update",
  "application.kafka.topics.inventory-service.inventory-product.update-quantity":"inventory-service.inventory-product.update-quantity",
  "application.kafka.group-id.product.update":"product-update-group",
  "application.kafka.group-id.payment.success":"payment-success-group"
}')"

put order-service "$(jq -n '{
  "server.port":"9696",
  "grpc.server.host":"inventory-service.apps.'"$DNS"'","grpc.server.port":"9090",
  "application.kafka.topics.order-service.order.success-status":"order-service.order.success-status",
  "application.kafka.topics.order-service.order.failed-status":"order-service.order.failed-status",
  "application.kafka.topics.order-service.order.canceled-status":"order-service.order.canceled-status",
  "application.kafka.group-id.order.update-status":"order.update-status"
}')"

put orchestrator-service "$(jq -n '{
  "server.port":"9999",
  "spring.datasource.url":"jdbc:mysql://mysql.infra.'"$DNS"':3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.username":"root","spring.datasource.password":"root",
  "spring.datasource.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "application.kafka.topics.mongo.event":"ecommerce_db.ecommerce_inventory.event",
  "application.kafka.topics.product-service.product.update-quantity":"product-service.product.update-quantity",
  "application.kafka.topics.order-service.order.success-status":"order-service.order.success-status",
  "application.kafka.topics.order-service.order.failed-status":"order-service.order.failed-status",
  "application.kafka.topics.order-service.order.canceled-status":"order-service.order.canceled-status",
  "application.kafka.topics.inventory-service.inventory-product.update-quantity":"inventory-service.inventory-product.update-quantity",
  "application.kafka.topics.inventory-service.product.update":"inventory-service.product.update",
  "application.kafka.group-id.mongo.event":"mongo-event-group",
  "application.saga.timeout-check-interval":"60000",
  "application.saga.compensation-max-retries":"3","application.saga.saga-ttl-minutes":"30"
}')"

put payment-service "$(jq -n \
  --arg cid "$PAYPAL_CLIENT_ID" --arg sec "$PAYPAL_CLIENT_SECRET" '{
  "server.port":"8484",
  "application.frontend.base-url":"http://microecom.local",
  "application.paypal.base-url":"https://api-m.sandbox.paypal.com",
  "application.paypal.success-path":"/payment-service/v1/paypal:success",
  "application.paypal.cancel-path":"/payment-service/v1/paypal:cancel",
  "application.paypal.client-id":$cid,"application.paypal.client-secret":$sec
}')"

put bff-service "$(jq -n '{
  "server.port":"8087",
  "inventory.grpc.host":"inventory-service.apps.'"$DNS"'","inventory.grpc.port":"9090",
  "feign.client.product-service.url":"http://product-service.apps.'"$DNS"':7777",
  "feign.client.order-service.url":"http://order-service.apps.'"$DNS"':9696",
  "feign.client.payment-service.url":"http://payment-service.apps.'"$DNS"':8484"
}')"

put mock-paypal-service "$(jq -n '{
  "server.port":"8585",
  "mock.public-base-url":"http://api.microecom.local/mock-paypal-service"
}')"

echo "✅ Secrets Manager seed complete."
```

- [ ] **Step 3: Make executable + lint**

Run: `chmod +x scripts/aws/seed-secrets.sh && bash -n scripts/aws/seed-secrets.sh`
Expected: no output (parse OK). These scripts run under `set -euo pipefail` — a parse error is fatal (see the seed-script SCAR in `k8s/CLAUDE.md`).

- [ ] **Step 4: Run the seed + verify a representative secret (HUMAN runs — billed)**

Run (with the four creds + `APPLICATION_JWK` exported): `scripts/aws/seed-secrets.sh`
Then: `aws secretsmanager get-secret-value --region ap-southeast-1 --secret-id app/authorization-server --query SecretString --output text | jq -r 'keys[]'`
Expected: prints the keys including `application.jwk`, `application.access-token.life-time`, `server.port` — proving the JSON keys are the dotted property names.

- [ ] **Step 5: Commit**

```bash
git add scripts/aws/services-secrets.list scripts/aws/seed-secrets.sh
git commit -m "feat(aws): seed-secrets.sh — push per-service config to Secrets Manager

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Install ESO + the ClusterSecretStore

ESO (Helm, cluster-scoped) runs the controller; the ClusterSecretStore tells it *where* (AWS Secrets Manager, our region) and *how* (IRSA via the `external-secrets` SA).

**Files:**
- Create: `k8s/infra/manifests/external-secrets-sa.yaml`
- Create: `k8s/infra/manifests/external-secrets-store.yaml`
- Modify: `scripts/aws/infra-up.sh`

**Ordering is load-bearing.** The chart runs with `serviceAccount.create=false`, so the `external-secrets` SA must EXIST before the Helm install — a pod whose `serviceAccountName` doesn't resolve is rejected by SA admission and `helm --wait` deadlocks until timeout (then `set -e` aborts the script). So the SA is split into its own manifest applied PRE-Helm; the ClusterSecretStore is applied POST-Helm because it needs the CRD the chart installs. Because the SA pre-exists, the controller pod gets its IRSA-projected token at creation — no `rollout restart` needed.

- [ ] **Step 1a: Write the ServiceAccount manifest (applied PRE-Helm)**

Create `k8s/infra/manifests/external-secrets-sa.yaml`. The IRSA annotation is patched in by `infra-up.sh` (the role ARN comes from `terraform output`), so leave a placeholder the script overwrites:

```yaml
# ESO ServiceAccount (IRSA target). Applied BEFORE the Helm install: the chart
# runs with serviceAccount.create=false, so this SA must already exist or the
# controller pod can't be scheduled (SA admission rejects it) and `helm --wait`
# deadlocks. The SA name/namespace MUST match the eso_irsa oidc_providers entry
# in aws/main/secrets.tf (infra:external-secrets). infra-up.sh stamps the real
# role ARN onto the annotation from `terraform output eso_irsa_role_arn`.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: infra
  annotations:
    eks.amazonaws.com/role-arn: PLACEHOLDER_ESO_ROLE_ARN
```

- [ ] **Step 1b: Write the ClusterSecretStore manifest (applied POST-Helm)**

Create `k8s/infra/manifests/external-secrets-store.yaml`:

```yaml
# ESO ClusterSecretStore — applied AFTER the Helm install, because it needs the
# ClusterSecretStore CRD that the chart installs (installCRDs=true). Points ESO
# at our region's Secrets Manager, authenticating as the external-secrets SA
# (see external-secrets-sa.yaml) via IRSA. The store name MUST match the
# secretStoreRef.name in every per-service ExternalSecret (aws-secrets-manager).
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-southeast-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: infra
```

- [ ] **Step 2: Add the ESO install block to `infra-up.sh`**

In `scripts/aws/infra-up.sh`, after the Helm-repo block (the `helm repo add ... grafana` lines, ~line 40) and before the MongoDB section, insert:

```bash
# ── External Secrets Operator (ESO) + ClusterSecretStore ─────────────────────
# ESO materializes AWS Secrets Manager secrets into native k8s Secrets, which the
# JVM apps consume via configtree (Phase 3). The controller's SA uses IRSA — no
# static AWS keys. installCRDs=true installs the ExternalSecret/ClusterSecretStore
# CRDs. Ordering is load-bearing: the SA must exist BEFORE the Helm install,
# because the chart runs with serviceAccount.create=false and a pod whose
# serviceAccountName doesn't exist is rejected by SA admission — `helm --wait`
# would then deadlock until timeout. So: stamp+apply the SA, THEN helm (pod
# schedules with the IRSA-annotated SA from creation, no restart needed), THEN
# apply the ClusterSecretStore (which needs the CRD the chart just installed).
echo "▶ installing External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update external-secrets

# 1. SA first, with the real IRSA role ARN from terraform (Task 2 must be applied).
ESO_ROLE_ARN="$(cd aws/main && terraform output -raw eso_irsa_role_arn)" || {
  echo "ERROR: 'terraform output eso_irsa_role_arn' failed — run Task 2 first (cd aws/main && terraform apply)" >&2
  exit 1
}
sed "s|PLACEHOLDER_ESO_ROLE_ARN|${ESO_ROLE_ARN}|" \
  "$MANIFESTS/external-secrets-sa.yaml" | kubectl apply -f -

# 2. Helm install (chart uses our pre-created SA; --wait blocks until controller is up).
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace infra --version 0.10.4 \
  --set installCRDs=true \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-secrets \
  --wait --timeout 5m

# 3. ClusterSecretStore last (needs the CRD the chart installed in step 2).
kubectl apply -f "$MANIFESTS/external-secrets-store.yaml"
```

- [ ] **Step 3: Lint the script**

Run: `bash -n scripts/aws/infra-up.sh`
Expected: no output (parse OK).

- [ ] **Step 4: Run + verify ESO is healthy and the store is valid (HUMAN runs — billed)**

Run: `scripts/aws/infra-up.sh` (idempotent; re-running is safe). Then:
`kubectl get clustersecretstore aws-secrets-manager -o jsonpath='{.status.conditions[0].reason}'`
Expected: `Valid` (ESO successfully assumed the IRSA role and reached Secrets Manager). If `InvalidProviderConfig`, check the SA annotation ARN and the eso_irsa trust policy SA name.

- [ ] **Step 5: Commit**

```bash
git add k8s/infra/manifests/external-secrets-sa.yaml k8s/infra/manifests/external-secrets-store.yaml scripts/aws/infra-up.sh
git commit -m "feat(aws): install External Secrets Operator + ClusterSecretStore

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Reusable kustomize component — configtree + vault-off

The configtree env vars + the volume mount are byte-identical across all services. Capture them once as a kustomize component; each service overlay references it. Only the *volume's secretName* differs per service (Task 7 supplies it via a per-service patch).

**Files:**
- Create: `k8s/apps/overlays/aws/components/spring-secrets/kustomization.yaml`
- Create: `k8s/apps/overlays/aws/components/spring-secrets/patch-env.yaml`

- [ ] **Step 1: Write the component env patch (shared, nameless target)**

Create `k8s/apps/overlays/aws/components/spring-secrets/patch-env.yaml`:

```yaml
# Shared across every service: remove Vault from the boot path and point Spring
# at the mounted configtree. SPRING_CONFIG_IMPORT (env) REPLACES the
# application.yml `optional:vault://` import; configtree reads /etc/app-config/
# where each file's NAME is a dotted property and its content is the value.
# Applied to ALL Deployments in the overlay (no metadata.name → matches each).
- op: add
  path: /spec/template/spec/containers/0/env/-
  value: { name: SPRING_CLOUD_VAULT_ENABLED, value: "false" }
- op: add
  path: /spec/template/spec/containers/0/env/-
  value: { name: SPRING_CONFIG_IMPORT, value: "optional:configtree:/etc/app-config/" }
```

- [ ] **Step 2: Write the component kustomization**

Create `k8s/apps/overlays/aws/components/spring-secrets/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  - path: patch-env.yaml
    target:
      kind: Deployment      # no name → applies to every Deployment in the overlay
```

- [ ] **Step 3: Render-test against a throwaway kustomization**

Run: `printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- ../../base/authorization-server\ncomponents:\n- ../../overlays/aws/components/spring-secrets\n' > /tmp/k-comp-test/kustomization.yaml 2>/dev/null; mkdir -p /tmp/k-comp-test && printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- %s/k8s/apps/base/authorization-server\ncomponents:\n- %s/k8s/apps/overlays/aws/components/spring-secrets\n' "$PWD" "$PWD" > /tmp/k-comp-test/kustomization.yaml && kubectl kustomize /tmp/k-comp-test | grep -E 'SPRING_CONFIG_IMPORT|SPRING_CLOUD_VAULT_ENABLED'`
Expected: both env vars appear on the authorization-server Deployment.

- [ ] **Step 4: Commit**

```bash
git add k8s/apps/overlays/aws/components/spring-secrets/
git commit -m "feat(aws): reusable spring-secrets kustomize component (configtree + vault-off)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: Prove the mechanism end-to-end on authorization-server

Wire auth-server into the AWS overlay: ExternalSecret (pulls `app/authorization-server` + `app/ecommerce` + `app/core-s3` → one k8s Secret), a volume patch mounting it, the shared component, and the ECR image swap. Auth-server is the canonical consumer — it needs db creds, the RSA JWK, and token config.

**Files:**
- Create: `k8s/apps/overlays/aws/authorization-server/externalsecret.yaml`
- Create: `k8s/apps/overlays/aws/authorization-server/patch-volume.yaml`
- Create: `k8s/apps/overlays/aws/authorization-server/kustomization.yaml`
- Modify: `k8s/apps/overlays/aws/kustomization.yaml`

- [ ] **Step 1: Write the ExternalSecret**

Auth-server reads three Vault contexts in the base (`authorization-server`, the common `ecommerce`, and `core-s3`). configtree merges multiple secrets if mounted into the same dir, but one k8s Secret is simpler — combine all three AWS secrets into one target via `dataFrom`. Create `k8s/apps/overlays/aws/authorization-server/externalsecret.yaml`:

```yaml
# Pulls the three Secrets Manager paths authorization-server needs and merges
# them into ONE k8s Secret (authorization-server-config). dataFrom.extract maps
# each AWS-JSON key -> a Secret data key VERBATIM (so keys stay dotted property
# names). refreshInterval re-syncs if a value changes in Secrets Manager.
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: authorization-server
  namespace: apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: authorization-server-config
    creationPolicy: Owner
  dataFrom:
    - extract: { key: app/ecommerce }
    - extract: { key: app/core-s3 }
    - extract: { key: app/authorization-server }
```

- [ ] **Step 2: Write the volume patch**

Create `k8s/apps/overlays/aws/authorization-server/patch-volume.yaml` (mounts the ESO-created Secret at the configtree path the component points to):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authorization-server
  namespace: apps
spec:
  template:
    spec:
      containers:
        - name: authorization-server
          volumeMounts:
            - { name: app-config, mountPath: /etc/app-config, readOnly: true }
      volumes:
        - name: app-config
          secret:
            secretName: authorization-server-config
```

- [ ] **Step 3: Write the per-service kustomization**

Create `k8s/apps/overlays/aws/authorization-server/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../base/authorization-server   # 3 levels up: overlays/aws/<svc>/ → apps/
  - externalsecret.yaml
components:
  - ../components/spring-secrets
patches:
  - path: patch-volume.yaml
images:
  - name: localhost:5001/authorization-server
    newName: 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com/authorization-server
    newTag: dev
```

- [ ] **Step 4: Reference it from the top-level AWS overlay**

In `k8s/apps/overlays/aws/kustomization.yaml`, add `authorization-server` to `resources:` (keep gateway as-is for now — it still uses its vault-off patch until Task 8 migrates it):

```yaml
resources:
  - namespace.yaml
  - ../../base/gateway
  - ingress-gateway.yaml
  - authorization-server          # ADD THIS (its own kustomization dir)
```

- [ ] **Step 5: Render-test**

Run: `kubectl kustomize k8s/apps/overlays/aws | grep -E 'authorization-server-config|configtree|/etc/app-config'`
Expected: shows the volume `secretName: authorization-server-config`, the mountPath `/etc/app-config`, and `SPRING_CONFIG_IMPORT=optional:configtree:/etc/app-config/`.

- [ ] **Step 6: Apply + verify the ExternalSecret syncs (HUMAN runs — billed)**

Run: `kubectl apply -k k8s/apps/overlays/aws`
Then: `kubectl -n apps get externalsecret authorization-server -o jsonpath='{.status.conditions[0].reason}'`
Expected: `SecretSynced`. And `kubectl -n apps get secret authorization-server-config -o jsonpath='{.data.application\.jwk}'` returns a non-empty base64 value (the JWK key materialized).

- [ ] **Step 7: Verify the pod boots from configtree, no Vault (HUMAN runs)**

Run: `kubectl -n apps rollout status deploy/authorization-server --timeout=5m`
Expected: rolled out, pod `1/1 Running`. `kubectl -n apps logs deploy/authorization-server | grep -iE 'vault|configtree|placeholder'` shows NO `UnknownHostException: vault...` and NO `Could not resolve placeholder` — proving it read db/jwk/token config from the mounted configtree.

- [ ] **Step 8: Commit**

```bash
git add k8s/apps/overlays/aws/authorization-server/ k8s/apps/overlays/aws/kustomization.yaml
git commit -m "feat(aws): authorization-server secrets via ESO configtree (mechanism proof)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: Migrate gateway from vault-off-only to the ESO pattern

Now that the mechanism is proven, replace the gateway's Phase-2 `vault-off-only` patch with the full ESO path (it gets `app/gateway` — its jwt config + route URIs). This makes gateway consistent with every other service and removes the one-off patch.

**Files:**
- Create: `k8s/apps/overlays/aws/gateway/externalsecret.yaml`
- Create: `k8s/apps/overlays/aws/gateway/patch-volume.yaml`
- Create: `k8s/apps/overlays/aws/gateway/kustomization.yaml`
- Delete: `k8s/apps/overlays/aws/patch-gateway-vault-off.yaml`
- Modify: `k8s/apps/overlays/aws/kustomization.yaml`

- [ ] **Step 1: Write the gateway ExternalSecret**

Create `k8s/apps/overlays/aws/gateway/externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gateway
  namespace: apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: gateway-config
    creationPolicy: Owner
  dataFrom:
    - extract: { key: app/ecommerce }     # gateway reads api_role from mongo (common ctx)
    - extract: { key: app/gateway }
```

- [ ] **Step 2: Write the gateway volume patch**

Create `k8s/apps/overlays/aws/gateway/patch-volume.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  namespace: apps
spec:
  template:
    spec:
      containers:
        - name: gateway
          volumeMounts:
            - { name: app-config, mountPath: /etc/app-config, readOnly: true }
      volumes:
        - name: app-config
          secret:
            secretName: gateway-config
```

- [ ] **Step 3: Write the gateway kustomization (moves the ECR image swap here)**

Create `k8s/apps/overlays/aws/gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../base/gateway   # 3 levels up: overlays/aws/gateway/ → apps/
  - externalsecret.yaml
components:
  - ../components/spring-secrets
patches:
  - path: patch-volume.yaml
  - target: { kind: Ingress, name: gateway, namespace: apps }
    patch: |-
      $patch: delete
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata: { name: gateway, namespace: apps }
images:
  - name: localhost:5001/gateway
    newName: 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com/gateway
    newTag: dev
```

- [ ] **Step 4: Rewire the top-level overlay**

Replace `k8s/apps/overlays/aws/kustomization.yaml` so gateway comes from its new dir and the one-off patch/image/ingress-delete move out of the top level:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - gateway                       # now its own kustomization (ESO)
  - authorization-server
  - ingress-gateway.yaml          # the ALB Ingress (unchanged)
```

- [ ] **Step 5: Delete the obsolete Phase-2 patch (HUMAN runs `rm` via `!`)**

The patch is superseded by the gateway ExternalSecret + component. Ask the user to run:
`! rm k8s/apps/overlays/aws/patch-gateway-vault-off.yaml`

- [ ] **Step 6: Render-test**

Run: `kubectl kustomize k8s/apps/overlays/aws | grep -E 'gateway-config|SPRING_CLOUD_VAULT_ENABLED' | sort -u`
Expected: `gateway-config` volume present; `SPRING_CLOUD_VAULT_ENABLED=false` present (now from the component, not the deleted patch).

- [ ] **Step 7: Apply + verify gateway still serves via ESO (HUMAN runs — billed)**

Run: `kubectl apply -k k8s/apps/overlays/aws && kubectl -n apps rollout status deploy/gateway --timeout=4m`
Then re-run the ALB curl from Task 1 Step 5.
Expected: gateway `1/1 Running`, ExternalSecret `SecretSynced`, ALB returns an HTTP status (not `000`).

- [ ] **Step 8: Commit**

```bash
git add k8s/apps/overlays/aws/gateway/ k8s/apps/overlays/aws/kustomization.yaml
git commit -m "refactor(aws): gateway secrets via ESO configtree (drop vault-off one-off)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 9: Generator for the remaining services + teardown guard

The remaining 9 services (`product-service`, `inventory-service`, `order-service`, `orchestrator-service`, `payment-service`, `bff-service`, `mock-paypal-service`, and any others) each need the identical 3-file overlay dir that authorization-server got. Generate them from the service list rather than hand-copying, then add a teardown guard so ephemeral recreates don't leak.

**Files:**
- Create: `scripts/aws/gen-aws-overlay.sh`
- Modify: `scripts/aws/down.sh`

- [ ] **Step 1: Write the generator**

Create `scripts/aws/gen-aws-overlay.sh`. It emits, per service, the same three files as Task 7 (ExternalSecret merging `app/ecommerce` + the service's own `app/<svc>` + `app/core-s3` for the S3 consumers), parameterized by the service's container name (= the base Deployment name). It does NOT overwrite the hand-written `gateway/` and `authorization-server/` dirs.

```bash
#!/usr/bin/env bash
# Generate the per-service AWS overlay dir (externalsecret + volume patch +
# kustomization) for every service that doesn't already have a hand-written one.
# Mirrors k8s/apps/overlays/aws/authorization-server/ exactly, parameterized by
# the service name. Re-runnable; skips gateway + authorization-server.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
OVERLAY="k8s/apps/overlays/aws"
ECR="583178372344.dkr.ecr.ap-southeast-1.amazonaws.com"

# service-name : extra AWS secret paths to merge (besides app/ecommerce + app/<svc>)
#   - core-s3 consumers (product/inventory/auth) get app/core-s3 too.
declare -A EXTRA=(
  [product-service]="app/core-s3"
  [inventory-service]="app/core-s3"
  [payment-service]=""
  [order-service]=""
  [orchestrator-service]=""
  [bff-service]=""
  [mock-paypal-service]=""
)

for svc in "${!EXTRA[@]}"; do
  dir="$OVERLAY/$svc"; mkdir -p "$dir"

  # dataFrom list: always app/ecommerce + app/<svc>, plus any extras.
  datafrom=$'  dataFrom:\n    - extract: { key: app/ecommerce }\n    - extract: { key: app/'"$svc"' }'
  for x in ${EXTRA[$svc]}; do datafrom+=$'\n    - extract: { key: '"$x"' }'; done

  cat > "$dir/externalsecret.yaml" <<YAML
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: $svc
  namespace: apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: $svc-config
    creationPolicy: Owner
$datafrom
YAML

  cat > "$dir/patch-volume.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $svc
  namespace: apps
spec:
  template:
    spec:
      containers:
        - name: $svc
          volumeMounts:
            - { name: app-config, mountPath: /etc/app-config, readOnly: true }
      volumes:
        - name: app-config
          secret:
            secretName: $svc-config
YAML

  cat > "$dir/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/$svc
  - externalsecret.yaml
components:
  - ../components/spring-secrets
patches:
  - path: patch-volume.yaml
images:
  - name: localhost:5001/$svc
    newName: $ECR/$svc
    newTag: dev
YAML
  echo "▶ generated $dir"
done
echo "✅ Add each new dir to $OVERLAY/kustomization.yaml resources, then apply."
```

- [ ] **Step 2: Generate + lint**

Run: `chmod +x scripts/aws/gen-aws-overlay.sh && bash -n scripts/aws/gen-aws-overlay.sh && scripts/aws/gen-aws-overlay.sh`
Expected: prints `▶ generated ...` for each service; the dirs appear under `k8s/apps/overlays/aws/`.

- [ ] **Step 3: Add the generated services to the top-level overlay**

Edit `k8s/apps/overlays/aws/kustomization.yaml` `resources:` to add each generated service dir (`product-service`, `inventory-service`, `order-service`, `orchestrator-service`, `payment-service`, `bff-service`, `mock-paypal-service`). Then render-test:
Run: `kubectl kustomize k8s/apps/overlays/aws >/dev/null && echo OK`
Expected: `OK` (no kustomize error).

- [ ] **Step 4: Add the teardown guard to `down.sh`**

In `scripts/aws/down.sh`, before any cluster/Terraform destroy, add a guard that removes the app-layer ExternalSecrets (so ESO doesn't recreate Secrets mid-teardown) and notes the Secrets Manager leak check. Append/insert:

```bash
# ── App secrets teardown ─────────────────────────────────────────────────────
# ExternalSecrets own their target k8s Secrets (creationPolicy: Owner); deleting
# the overlay removes them. The Secrets Manager CONTAINERS are Terraform-managed
# (recovery_window_in_days=0) and are destroyed by `terraform destroy` — they do
# NOT leak. Verify nothing lingers in a soft-delete state after destroy:
echo "▶ post-destroy Secrets Manager leak check:"
aws secretsmanager list-secrets --region ap-southeast-1 \
  --include-planned-deletion \
  --query "SecretList[?starts_with(Name, 'app/')].{name:Name,deletes:DeletedDate}" \
  --output table || true
```

- [ ] **Step 5: Lint + commit**

Run: `bash -n scripts/aws/down.sh scripts/aws/gen-aws-overlay.sh`
Expected: no output.

```bash
git add scripts/aws/gen-aws-overlay.sh scripts/aws/down.sh \
        k8s/apps/overlays/aws/kustomization.yaml \
        k8s/apps/overlays/aws/product-service k8s/apps/overlays/aws/inventory-service \
        k8s/apps/overlays/aws/order-service k8s/apps/overlays/aws/orchestrator-service \
        k8s/apps/overlays/aws/payment-service k8s/apps/overlays/aws/bff-service \
        k8s/apps/overlays/aws/mock-paypal-service
git commit -m "feat(aws): generate ESO overlays for remaining services + teardown leak guard

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Full rollout verification (HUMAN runs — billed; depends on infra + images present)**

Run: `kubectl apply -k k8s/apps/overlays/aws`
Then: `kubectl -n apps get externalsecret` (all `SecretSynced`) and `kubectl -n apps get pods` (each service `Running`; note MySQL/Redis/MinIO must exist for the data-tier consumers — those arrive with the broader Phase-3 deployment plan, so services needing them may stay `0/1` until then. The ESO mechanism is proven once each ExternalSecret is `SecretSynced` and gateway + authorization-server are `1/1`).
Expected: every ExternalSecret `SecretSynced`; gateway + authorization-server `1/1 Running`.

---

## Notes for the executor

- **Vault stays untouched on kind.** None of these files alter `k8s/infra/jobs/03-vault-seed/` or the local overlays. `make up` on kind still uses Vault. This is the "same image, overlay-only difference" guarantee — verify by confirming no edits land outside `aws/`, `scripts/aws/`, `k8s/apps/overlays/aws/`, and `k8s/infra/manifests/external-secrets-store.yaml`.
- **The seed values mirror `seed.sh`.** If a key drifts in the Vault seed, mirror it in `seed-secrets.sh` (the documented parallel-artifact pattern — see the vault-seed SCAR in `k8s/CLAUDE.md`). The dotted JSON keys are load-bearing: a typo surfaces as a `Could not resolve placeholder` crash, identical to a missing Vault key.
- **configtree key validity:** k8s Secret keys allow `[-._a-zA-Z0-9]`, so dotted/hyphenated property names (`gateway.routes.authorization-server.uri`) are valid Secret keys and become files configtree reads verbatim. No env-var relaxed-binding ambiguity — that's the whole reason for configtree over envFrom.
- **Cost discipline:** the cluster bills ~$0.25–0.30/hr. Run `make aws-down` between sessions.
