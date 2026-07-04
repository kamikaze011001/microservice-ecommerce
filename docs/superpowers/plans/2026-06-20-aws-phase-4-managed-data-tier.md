# AWS Phase 4 — Managed Data Tier (RDS · ElastiCache · S3+IRSA) Implementation Plan

> **For agentic workers:** This is a **coworking learning plan**. Tasks tagged **[HUMAN ✍️]** are written by the user (Terraform, for interview prep) — the plan gives REQUIREMENTS, never the solution. Tasks tagged **[CLAUDE]** are scripts / app code / kustomize that Claude writes in full. Steps use checkbox (`- [ ]`) syntax. Do NOT auto-run billed AWS commands (`terraform apply`, `aws …`, `kubectl apply`, seed scripts) — those are the USER's to run against account `583178372344` / profile `microecom` / region `ap-southeast-1`. Claude runs OFFLINE gates only (`terraform validate`, `terraform fmt -check`, `bash -n`, `kubectl kustomize`).

**Goal:** Swap the three self-hosted stateful stores for managed AWS services — MySQL→RDS (primary + 1 read replica), Redis→ElastiCache, MinIO→S3 (via IRSA) — so all 11 workloads run on managed data with zero application code rewrites beyond one credential-provider guard.

**Architecture:** The app reads every datastore coordinate (JDBC URLs, Redis host, S3 endpoint/creds) from AWS Secrets Manager via ESO/configtree — populated by `scripts/aws/seed-secrets.sh`. So each substitution is two moves: (1) **[HUMAN]** Terraform creates the managed resource + a security group that admits the EKS node SG, (2) **[CLAUDE]** `seed-secrets.sh` swaps the in-cluster DNS coordinate for the managed endpoint read from `terraform output`. Only S3 also needs app identity (IRSA) + a one-line code guard, because S3 auth is per-pod IAM rather than a network-reachable host. Sub-phases run **4a RDS → 4b ElastiCache → 4c S3, each fully verified before the next** — isolating any failure to a single swap (spec §8).

**Tech Stack:** Terraform (`terraform-aws-modules/rds`, hand-written `aws_elasticache_*`, `aws_s3_bucket`, `aws_security_group`, IRSA submodule), AWS Secrets Manager + External Secrets Operator, EKS 1.31, Spring Boot config-tree, AWS SDK for Java v2 (`DefaultCredentialsProvider`).

---

## Context You Must Know Before Starting

**Where the config values come from (read `scripts/aws/seed-secrets.sh` once).** It pushes one JSON blob per service into Secrets Manager; the JSON keys are *exact dotted Spring property names*. Today they point at in-cluster DNS:
- `spring.datasource.master.url` → `jdbc:mysql://mysql.infra.svc.cluster.local:3306/ecommerce_dev?…`
- `spring.datasource.slave1.url` / `slave2.url` → `mysql-replica.infra.svc.cluster.local:3306`
- `orchestrator-service` has its own single `spring.datasource.url` → `mysql.infra…` (no master/slave split)
- `spring.data.redis.host` → `redis-master.infra.svc.cluster.local`
- `core-s3`: `s3.endpoint` → `http://minio.infra…:9000`, `s3.access-key`/`s3.secret-key` = `minioadmin`, `s3.path-style` = `true`

Phase 4 rewrites exactly those values to managed endpoints. **Everything else in the file stays byte-for-byte identical.**

**MySQL username on RDS.** RDS reserves `root`/`admin` rules vary; we use master username **`admin`** (not `root`). The app reads the username from config, so this is a config-only change. `db_name = ecommerce_dev` is created by RDS.

**Schema & seed (read `k8s/infra/jobs/01-mysql-seed/seed.sh`).** The JPA services create the schema themselves via Hibernate `ddl-auto` on first connect. A separate seed job then loads **data** from `docker/ecommerce.sql` (guarded on `account` row count, idempotent). RDS starts empty, so after the DB services connect-and-create-schema we must run that data seed against the RDS endpoint. Cart-stock seeds (`scripts/seed/mysql-inventory-products.sh`, `scripts/seed/mysql-product-quantity-history.sh`) are also needed for the buy flow (see memory `project_inventory_seed`).

**Security groups are the Phase-4 IAM-of-the-network learning beat.** RDS and ElastiCache are reachable only if their SG admits inbound from the EKS **node** security group (`module.eks.node_security_group_id`) on 3306 / 6379. No public access, no `0.0.0.0/0`.

**IRSA only for S3.** RDS/ElastiCache authenticate with username/password over a network path (SG). S3 authenticates with an IAM identity per pod — so only 4c needs ServiceAccounts + IRSA roles, and only for the **two** services that call core-s3: **authorization-server** (avatars) and **product-service** (product images). `inventory-service` does NOT touch S3.

**IRSA / SG patterns to mirror.** `aws/main/storage.tf` and `aws/main/alb-controller.tf` are your reference IRSA shapes. `module.eks` (v20) exposes `oidc_provider_arn`, `node_security_group_id`, `cluster_name`. `module.vpc` (v5) exposes `private_subnets` (list, AZ-ordered), `vpc_id`. The node group is pinned to `private_subnets[0]` (AZ-a) — RDS/ElastiCache reach cross-AZ fine (unlike AZ-locked EBS), so their subnet groups span both private subnets.

**Cost.** RDS `db.t4g.micro` ×2 (primary+replica) + ElastiCache `cache.t4g.micro` add ~$0.10–0.15/hr on top of the cluster. `make aws-down` between sessions; RDS/ElastiCache/S3 are torn down with the cluster (Task 16). Only the Phase-0 state bucket + ECR persist.

---

## File Structure

| File | Owner | Responsibility |
|---|---|---|
| `aws/main/rds.tf` | **HUMAN** | DB SG, DB subnet group, RDS primary + read replica, endpoint outputs |
| `aws/main/cache.tf` | **HUMAN** | Redis SG, cache subnet group, ElastiCache single-node, endpoint output |
| `aws/main/s3.tf` | **HUMAN** | media bucket + public-read policy, 2 app IRSA roles, bucket/role-arn outputs |
| `aws/main/variables.tf` | CLAUDE | add `db_master_password` (sensitive) |
| `aws/main/terraform.tfvars` | USER (gitignored) | set `db_master_password` value |
| `aws/main/outputs.tf` | shared | endpoints + db password (sensitive) consumed by seed-secrets.sh |
| `scripts/aws/seed-secrets.sh` | CLAUDE | read `terraform output`, swap 3 coordinate sets |
| `scripts/aws/seed-rds.sh` | CLAUDE | run `ecommerce.sql` + stock seeds against RDS endpoint |
| `core/core-s3/.../S3Config.java` | CLAUDE | blank-key guard → `DefaultCredentialsProvider` (IRSA) |
| `k8s/apps/overlays/aws/<svc>/serviceaccount.yaml` + patch | CLAUDE | named SA + role-arn annotation for the 2 S3 services |
| `scripts/aws/down.sh` | CLAUDE | extend leak check to RDS/ElastiCache/S3 |

---

# PHASE 4a — RDS MySQL (primary + read replica)

### Task 1: [HUMAN ✍️] Write `aws/main/rds.tf`

**Files:**
- Create: `aws/main/rds.tf`
- Modify: `aws/main/variables.tf` (CLAUDE adds the password var in Task 2 — you reference `var.db_master_password`)

- [ ] **Step 1: Write the DB security group** — `resource "aws_security_group" "rds"`
  - `vpc_id = module.vpc.vpc_id`
  - one ingress rule: TCP **3306** from `security_groups = [module.eks.node_security_group_id]` (NOT a CIDR — source the node SG so only cluster nodes can reach the DB)
  - egress all (`0.0.0.0/0`, protocol `-1`)
  - 🎓 Be ready to explain: why SG-to-SG beats a CIDR allowlist (follows the nodes as they scale/replace; no IP drift).

- [ ] **Step 2: Write the DB subnet group** — `resource "aws_db_subnet_group" "main"`
  - `subnet_ids = module.vpc.private_subnets` (BOTH private subnets — RDS requires ≥2 AZs for a subnet group even when the instance is single-AZ)

- [ ] **Step 3: Write the RDS primary** using `module "rds"`, source `terraform-aws-modules/rds/aws`, version `~> 6.0`. Requirements:
  - `identifier = "${var.project}-mysql"`
  - `engine = "mysql"`, `engine_version = "8.0"`, `family = "mysql8.0"`, `major_engine_version = "8.0"`
  - `instance_class = "db.t4g.micro"` (Graviton — match the arm theme), `allocated_storage = 20`
  - `db_name = "ecommerce_dev"`, `username = "admin"`, `password = var.db_master_password`, `manage_master_user_password = false` (we feed the same value to seed-secrets via an output — RDS-managed secret would add a second indirection to learn later)
  - `port = 3306`
  - `multi_az = false` (sandbox cost), `publicly_accessible = false`
  - `db_subnet_group_name = aws_db_subnet_group.main.name`, `vpc_security_group_ids = [aws_security_group.rds.id]`
  - `skip_final_snapshot = true`, `deletion_protection = false` (ephemeral — must `terraform destroy` cleanly)
  - `create_db_subnet_group = false` (you made it in Step 2)
  - Docs: https://registry.terraform.io/modules/terraform-aws-modules/rds/aws/latest

- [ ] **Step 4: Write the read replica.** The app's slave routing needs a second endpoint. Two valid shapes — pick and be ready to defend:
  - **(a) Module replica:** a second `module "rds_replica"` with `replicate_source_db = module.rds.db_instance_identifier`, no `db_name`/`username`/`password` (inherited), same `instance_class`, its own `identifier = "${var.project}-mysql-replica"`, `vpc_security_group_ids = [aws_security_group.rds.id]`, `create_db_subnet_group = false`, `db_subnet_group_name = aws_db_subnet_group.main.name`, `skip_final_snapshot = true`.
  - **(b) Raw `aws_db_instance` replica** with `replicate_source_db`. Either is fine; (a) keeps it consistent with the primary.
  - 🎓 Be ready to explain: the app keeps its master/slave *routing datasource* unchanged — both `slave1.url` and `slave2.url` will point at this one replica endpoint. "Replica count is config, not code" (spec §3).

- [ ] **Step 5: Add outputs** at the bottom of `rds.tf` (or `outputs.tf` — your call, keep co-located is fine):
  - `output "rds_primary_endpoint" { value = module.rds.db_instance_address }` (address = host only, no `:3306` — seed-secrets adds the port)
  - `output "rds_replica_endpoint" { value = module.rds_replica.db_instance_address }` (or the raw replica's `.address`)
  - 🎓 `db_instance_address` (host) vs `db_instance_endpoint` (`host:port`): we want the host so the JDBC URL template controls the rest.

- [ ] **Step 6: Tell Claude "review".** Claude runs `terraform -chdir=aws/main fmt -check` + `terraform -chdir=aws/main validate` (offline; validate needs `terraform init` already done) and checks the SG source, subnet count, replica wiring, and output attribute names against this spec.

### Task 2: [CLAUDE] Add the password variable + output

**Files:**
- Modify: `aws/main/variables.tf`
- Modify: `aws/main/outputs.tf`

- [ ] **Step 1: Add the variable** to `aws/main/variables.tf`:

```hcl
variable "db_master_password" {
  description = "Master password for the RDS MySQL instance (set in gitignored terraform.tfvars)"
  type        = string
  sensitive   = true
}
```

- [ ] **Step 2: Add a sensitive output** so `seed-secrets.sh` reads ONE source of truth (avoids the tfvars value drifting from the seeded value):

```hcl
output "db_master_password" {
  description = "RDS master password — read by seed-secrets.sh so it never drifts from tfvars"
  value       = var.db_master_password
  sensitive   = true
}
```

- [ ] **Step 3: Tell the USER** to add to `aws/main/terraform.tfvars` (gitignored — never commit):

```hcl
db_master_password = "<choose a strong password, no @ / : in it to keep the JDBC URL clean>"
```

- [ ] **Step 4: Commit** (Claude, after HUMAN's rds.tf is reviewed green):

```bash
git add aws/main/rds.tf aws/main/variables.tf aws/main/outputs.tf
git commit -m "feat(aws): RDS MySQL primary + read replica with node-SG ingress (Phase 4a)"
```

### Task 3: [CLAUDE] Point `seed-secrets.sh` at RDS

**Files:**
- Modify: `scripts/aws/seed-secrets.sh`

- [ ] **Step 1: Add a terraform-output reader block** just after `REGION=…` (line ~17). This reads the managed endpoints so values never hardcode:

```bash
# ── Managed-endpoint discovery (Phase 4) ─────────────────────────────────────
# Read the RDS/ElastiCache/S3 coordinates straight from terraform state so the
# seed can never drift from what was actually provisioned. -chdir points at the
# root module; -raw strips quotes. Added incrementally per sub-phase.
TF=aws/main
RDS_PRIMARY="$(terraform -chdir="$TF" output -raw rds_primary_endpoint)"
RDS_REPLICA="$(terraform -chdir="$TF" output -raw rds_replica_endpoint)"
DB_PASS="$(terraform -chdir="$TF" output -raw db_master_password)"
```

- [ ] **Step 2: Replace the `put ecommerce` datasource block.** Change the three `spring.datasource.*.url` hosts to the RDS endpoints, `username` to `admin`, `password` to `$DB_PASS`. The slave1 and slave2 URLs both use `$RDS_REPLICA`:

```bash
put ecommerce "$(jq -n \
  --arg mu "$APPLICATION_MAIL_USERNAME" --arg mp "$APPLICATION_MAIL_PASSWORD" \
  --arg dpw "$DB_PASS" --arg mhost "$RDS_PRIMARY" --arg rhost "$RDS_REPLICA" '{
  "spring.datasource.master.url":("jdbc:mysql://"+$mhost+":3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
  "spring.datasource.master.username":"admin","spring.datasource.master.password":$dpw,
  "spring.datasource.master.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.datasource.slave1.url":("jdbc:mysql://"+$rhost+":3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
  "spring.datasource.slave1.username":"admin","spring.datasource.slave1.password":$dpw,
  "spring.datasource.slave1.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.datasource.slave2.url":("jdbc:mysql://"+$rhost+":3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
  "spring.datasource.slave2.username":"admin","spring.datasource.slave2.password":$dpw,
  "spring.datasource.slave2.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.data.redis.host":"redis-master.infra.svc.cluster.local","spring.data.redis.port":"6379",
  "spring.data.redis.password":"","spring.data.redis.database":"0",
  "spring.data.mongodb.uri":"mongodb://ecommerce:ecommerce123@mongodb.infra.svc.cluster.local:27017/ecommerce_inventory?authSource=admin",
  "spring.data.mongodb.database":"ecommerce_inventory",
  "spring.kafka.bootstrap-servers":"kafka.infra.svc.cluster.local:9092",
  "spring.kafka.properties.schema.registry.url":"http://schema-registry.infra.svc.cluster.local:8081",
  "eureka.client.enabled":"false",
  "spring.mail.host":"smtp.gmail.com","spring.mail.port":"587","spring.mail.protocol":"smtp",
  "spring.mail.properties.mail.smtp.auth":"true","spring.mail.properties.mail.smtp.starttls.enable":"true",
  "spring.mail.username":$mu,"spring.mail.password":$mp,
  "management.metrics.distribution.percentiles-histogram.http.server.requests":"true"
}')"
```
*(Redis/Mongo/Kafka lines unchanged here — Redis flips in Task 7.)*

- [ ] **Step 3: Replace the `put orchestrator-service` datasource lines** (single datasource → primary):

```bash
# inside the orchestrator-service jq object, replace the three datasource lines:
  "spring.datasource.url":("jdbc:mysql://"+$mhost+":3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
  "spring.datasource.username":"admin","spring.datasource.password":$dpw,
```
…and add `--arg dpw "$DB_PASS" --arg mhost "$RDS_PRIMARY"` to that block's `jq -n` invocation.

- [ ] **Step 4: Offline gate** — `bash -n scripts/aws/seed-secrets.sh`. Expected: no output (syntax OK).

- [ ] **Step 5: Commit:**

```bash
git add scripts/aws/seed-secrets.sh
git commit -m "feat(aws): seed-secrets reads RDS endpoints from terraform output (Phase 4a)"
```

### Task 4: [CLAUDE] Seed schema-data into RDS

**Files:**
- Create: `scripts/aws/seed-rds.sh`

- [ ] **Step 1: Write `scripts/aws/seed-rds.sh`** — runs from a throwaway in-cluster `mysql:8.0` pod (so it sits inside the SG that can reach RDS), guarded idempotently on `account` rows like the kind seed:

```bash
#!/usr/bin/env bash
# Seed RDS with ecommerce.sql DATA (schema is created by the apps' Hibernate
# ddl-auto on first connect — run this AFTER the DB services are Running). Runs
# the mysql client from inside the cluster so it inherits the node SG that the
# RDS security group admits. Idempotent: guards on the `account` row count.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
TF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../aws/main" && pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RDS_HOST="$(terraform -chdir="$TF" output -raw rds_primary_endpoint)"
DB_PASS="$(terraform -chdir="$TF" output -raw db_master_password)"

echo "▶ seeding RDS at ${RDS_HOST} (data only; schema via ddl-auto)"
kubectl run rds-seed-$$ -n apps --rm -i --restart=Never --image=mysql:8.0 \
  --env=MYSQL_PWD="$DB_PASS" --command -- sh -c "
    SEEDED=\$(mysql -h ${RDS_HOST} -uadmin ecommerce_dev -N -e 'SELECT COUNT(*) FROM account;' 2>/dev/null || echo 0)
    if [ \"\${SEEDED}\" -gt 0 ]; then echo 'RDS already seeded; skipping'; exit 0; fi
    echo 'seeding...'
  " || true

# Pipe the SQL in via stdin (the run above only checked the guard; this does the load).
kubectl run rds-seed-load-$$ -n apps --rm -i --restart=Never --image=mysql:8.0 \
  --env=MYSQL_PWD="$DB_PASS" --command -- \
  mysql -h "$RDS_HOST" -uadmin ecommerce_dev < "$ROOT/docker/ecommerce.sql"
echo "✅ RDS data seed complete. (Run scripts/seed/mysql-inventory-products.sh + mysql-product-quantity-history.sh equivalents for the buy flow if needed.)"
```

> **Note for the executor:** the two-`kubectl run` split above is deliberate but clunky. If during execution you find the guard+load is cleaner as a single heredoc piping `ecommerce.sql` through `kubectl run … -i`, consolidate it — the REQUIREMENT is: idempotent, runs inside the cluster, loads `docker/ecommerce.sql` into `ecommerce_dev` on RDS. Keep the `account`-rows idempotency guard.

- [ ] **Step 2: Offline gate** — `bash -n scripts/aws/seed-rds.sh`. Expected: no output.

- [ ] **Step 3: Commit:**

```bash
git add scripts/aws/seed-rds.sh
git commit -m "feat(aws): seed-rds.sh — load ecommerce.sql data into RDS (Phase 4a)"
```

### Task 5: [USER runs / CLAUDE verifies] Apply & verify 4a

- [ ] **Step 1 (USER):** `terraform -chdir=aws/main apply` — creates RDS primary + replica (~8–12 min).
- [ ] **Step 2 (USER):** re-run the secrets seed so the DB services get RDS coordinates:
  ```bash
  AWS_PROFILE=microecom PAYPAL_CLIENT_ID=… PAYPAL_CLIENT_SECRET=… \
  APPLICATION_MAIL_USERNAME=… APPLICATION_MAIL_PASSWORD=… APPLICATION_JWK=… \
  scripts/aws/seed-secrets.sh
  ```
- [ ] **Step 3 (USER):** force ESO to re-pull + restart the DB services:
  ```bash
  kubectl rollout restart deployment -n apps \
    authorization-server inventory-service order-service payment-service orchestrator-service
  ```
- [ ] **Step 4 (USER):** once those pods reach `Running` (schema auto-created), seed data: `scripts/aws/seed-rds.sh`
- [ ] **Step 5 (CLAUDE verifies):** Expected — `kubectl get pods -n apps` shows the 5 DB services `Running` (no `Communications link failure` in logs); a login through the gateway ALB returns a JWT. **This is the moment Bug B from the debugging session is resolved.**
- [ ] **Step 6:** Update memory `project_aws_deploy_progress` → "Phase 4a (RDS) DONE".

---

# PHASE 4b — ElastiCache Redis

### Task 6: [HUMAN ✍️] Write `aws/main/cache.tf`

**Files:**
- Create: `aws/main/cache.tf`

- [ ] **Step 1: Redis security group** — `resource "aws_security_group" "redis"`: ingress TCP **6379** from `security_groups = [module.eks.node_security_group_id]`, egress all, `vpc_id = module.vpc.vpc_id`. (Same shape as the RDS SG — copy it, change the port.)

- [ ] **Step 2: Cache subnet group** — `resource "aws_elasticache_subnet_group" "main"` with `subnet_ids = module.vpc.private_subnets`.

- [ ] **Step 3: Single-node Redis** — `resource "aws_elasticache_cluster" "redis"`:
  - `cluster_id = "${var.project}-redis"`, `engine = "redis"`, `node_type = "cache.t4g.micro"`, `num_cache_nodes = 1`, `port = 6379`, `engine_version = "7.1"`
  - `subnet_group_name = aws_elasticache_subnet_group.main.name`, `security_group_ids = [aws_security_group.redis.id]`
  - No AUTH token / no in-transit encryption — keeps `spring.data.redis.password` empty for the sandbox.
  - 🎓 Be ready to explain the tradeoff: prod would use a `replication_group` with `transit_encryption_enabled = true` + an AUTH token in Secrets Manager. The app's single `spring.data.redis.host` doesn't change shape — Redis here is a cache, not master/slave-routed like MySQL.
  - Docs: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_cluster

- [ ] **Step 4: Output** — `output "redis_endpoint" { value = aws_elasticache_cluster.redis.cache_nodes[0].address }` (single-node clusters expose the host under `cache_nodes[0].address`).

- [ ] **Step 5: Tell Claude "review"** — Claude runs fmt/validate and checks the SG port, subnet group, and the `cache_nodes[0].address` output path.

### Task 7: [CLAUDE] Point `seed-secrets.sh` at ElastiCache

**Files:**
- Modify: `scripts/aws/seed-secrets.sh`

- [ ] **Step 1: Extend the discovery block** (added in Task 3) with:
  ```bash
  REDIS_HOST="$(terraform -chdir="$TF" output -raw redis_endpoint)"
  ```
- [ ] **Step 2: In the `put ecommerce` block**, change the Redis host line to use it — add `--arg rh "$REDIS_HOST"` to that `jq -n` and set:
  ```bash
  "spring.data.redis.host":$rh,"spring.data.redis.port":"6379",
  ```
- [ ] **Step 3: Offline gate** — `bash -n scripts/aws/seed-secrets.sh`. Expected: no output.
- [ ] **Step 4: Commit:**
  ```bash
  git add aws/main/cache.tf scripts/aws/seed-secrets.sh
  git commit -m "feat(aws): ElastiCache Redis + seed-secrets redis host swap (Phase 4b)"
  ```

### Task 8: [USER runs / CLAUDE verifies] Apply & verify 4b

- [ ] **Step 1 (USER):** `terraform -chdir=aws/main apply` (~5–8 min for the cache node).
- [ ] **Step 2 (USER):** re-run `seed-secrets.sh` (same env as Task 5 Step 2).
- [ ] **Step 3 (USER):** `kubectl rollout restart deployment -n apps authorization-server order-service payment-service` (the Redis consumers — auth uses it for refresh-token families/sessions).
- [ ] **Step 4 (CLAUDE verifies):** Expected — restarted pods `Running`, no `Unable to connect to Redis` in logs; a login → refresh-token round-trip succeeds through the ALB.
- [ ] **Step 5:** Update memory `project_aws_deploy_progress` → "Phase 4b (ElastiCache) DONE".

---

# PHASE 4c — S3 + IRSA

### Task 9: [CLAUDE] Make core-s3 fall back to the IRSA credential chain

**Files:**
- Modify: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java:54-57`

The current `credentials()` always returns `StaticCredentialsProvider`. Guard it so blank keys → `DefaultCredentialsProvider` (which picks up the pod's IRSA web-identity token). Backward compatible: MinIO-local still sets keys → static; AWS sets keys blank → IRSA.

- [ ] **Step 1: Replace the `credentials(...)` helper:**

```java
private static AwsCredentialsProvider credentials(S3Properties props) {
    // Blank keys → fall back to the AWS default credential chain so the pod's
    // IRSA web-identity token is used (real S3). Non-blank → static creds (MinIO,
    // local dev). This keeps one image working in both environments.
    if (props.getAccessKey() == null || props.getAccessKey().isBlank()) {
        return DefaultCredentialsProvider.create();
    }
    return StaticCredentialsProvider.create(
        AwsBasicCredentials.create(props.getAccessKey(), props.getSecretKey()));
}
```

- [ ] **Step 2: Add the import** at the top of `S3Config.java`:
  ```java
  import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
  ```
- [ ] **Step 3: Build gate** — `cd core/core-s3 && mvn -q -o compile` (offline). Expected: BUILD SUCCESS.
- [ ] **Step 4: Commit:**
  ```bash
  git add core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java
  git commit -m "feat(core-s3): fall back to IRSA default credential chain when keys are blank (Phase 4c)"
  ```

### Task 10: [HUMAN ✍️] Write `aws/main/s3.tf`

**Files:**
- Create: `aws/main/s3.tf`

- [ ] **Step 1: The media bucket** — `resource "aws_s3_bucket" "media"` with `bucket = "${var.project}-media-${data.aws_caller_identity.current.account_id}"` (globally-unique). You'll need a `data "aws_caller_identity" "current" {}` in `data.tf` — add it there.

- [ ] **Step 2: Public-read for the object prefixes** the app serves directly. core-s3 stores public URLs for `products/*` and `avatars/*`. Write:
  - `resource "aws_s3_bucket_public_access_block" "media"` allowing public policy (`block_public_policy = false`, `restrict_public_buckets = false`; keep `block_public_acls = true` — we use a *policy*, not ACLs)
  - `resource "aws_s3_bucket_policy" "media"` granting `s3:GetObject` to `Principal "*"` on `${bucket}/products/*` and `${bucket}/avatars/*` ONLY (not the whole bucket).
  - 🎓 Be ready to explain ACL-disabled + bucket-policy public read (the modern S3 pattern) vs legacy public ACLs.

- [ ] **Step 3: Two app IRSA roles** — one per S3-writing service, scoped to PutObject/GetObject on this bucket. Mirror `storage.tf`'s `iam-role-for-service-accounts-eks` submodule, but there's no "magic flag" for app S3, so attach a custom policy. For EACH of `authorization-server` and `product-service`:
  ```
  module "<svc>_s3_irsa" {
    source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
    version = "~> 5.0"
    role_name = "${var.project}-<svc>-s3"
    oidc_providers = {
      main = {
        provider_arn               = module.eks.oidc_provider_arn
        namespace_service_accounts = ["apps:<svc>"]   # the SA Claude creates in Task 11
      }
    }
  }
  ```
  …plus an `aws_iam_role_policy` attaching `s3:PutObject` + `s3:GetObject` on `${aws_s3_bucket.media.arn}/products/*` (and `/avatars/*` for authorization-server) to that role.
  - 🎓 Why two roles not one: least privilege + the trust policy binds each role to exactly one `apps:<svc>` ServiceAccount. A compromised product-service pod can't write to avatars.

- [ ] **Step 4: Outputs:**
  - `output "s3_bucket_name" { value = aws_s3_bucket.media.bucket }`
  - `output "authorization_server_s3_role_arn" { value = module.authorization_server_s3_irsa.iam_role_arn }`
  - `output "product_service_s3_role_arn" { value = module.product_service_s3_irsa.iam_role_arn }`

- [ ] **Step 5: Tell Claude "review"** — fmt/validate + check the policy scoping (prefix-limited, not bucket-wide), the SA namespace strings, and output names.

### Task 11: [CLAUDE] Named ServiceAccounts + role-arn annotation for the 2 S3 services

**Files:**
- Create: `k8s/apps/overlays/aws/authorization-server/serviceaccount.yaml`
- Create: `k8s/apps/overlays/aws/product-service/serviceaccount.yaml`
- Modify: each service's overlay `kustomization.yaml` (add the SA + a deployment patch setting `serviceAccountName`)

- [ ] **Step 1: `authorization-server/serviceaccount.yaml`** (role ARN is filled from the Task-10 output at apply time — Claude will templatize via a tiny `sed`/kustomize replacement or instruct the USER to paste the ARN; the manifest skeleton):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: authorization-server
  namespace: apps
  annotations:
    eks.amazonaws.com/role-arn: ROLE_ARN_PLACEHOLDER  # ← terraform output authorization_server_s3_role_arn
```
*(product-service/serviceaccount.yaml identical with name `product-service` and its role ARN.)*

> **Executor note:** prefer NOT to commit a literal account-ARN into the manifest if you want it portable. Two clean options — pick one during execution: (a) a kustomize `replacements`/`configMapGenerator` that injects the ARN from an env-substituted file at apply time; (b) a one-line `scripts/aws/stamp-s3-irsa.sh` that runs `kubectl annotate sa <svc> -n apps eks.amazonaws.com/role-arn=$(terraform output -raw …)` post-apply. Option (b) mirrors how `infra-up.sh` already stamps the ESO SA — **prefer (b) for consistency**.

- [ ] **Step 2: Deployment patch** in each overlay to set `serviceAccountName`. Add to the overlay `kustomization.yaml` `patches:` a strategic-merge that sets `spec.template.spec.serviceAccountName: <svc>`. Restarting the pod under a SA with the IRSA annotation injects the web-identity token env vars that `DefaultCredentialsProvider` (Task 9) consumes.

- [ ] **Step 3: Offline gate** — `kubectl kustomize k8s/apps/overlays/aws/authorization-server` and `…/product-service` render without error and show `serviceAccountName` + the SA resource.

- [ ] **Step 4: Commit:**
  ```bash
  git add k8s/apps/overlays/aws/authorization-server k8s/apps/overlays/aws/product-service scripts/aws/stamp-s3-irsa.sh
  git commit -m "feat(aws): IRSA ServiceAccounts for S3-writing services (Phase 4c)"
  ```

### Task 12: [CLAUDE] Point `seed-secrets.sh` core-s3 at real S3

**Files:**
- Modify: `scripts/aws/seed-secrets.sh`

- [ ] **Step 1: Extend the discovery block:**
  ```bash
  S3_BUCKET="$(terraform -chdir="$TF" output -raw s3_bucket_name)"
  ```
- [ ] **Step 2: Replace the `put core-s3` block** — blank endpoint (SDK uses the regional AWS endpoint), `path-style=false`, real region/bucket, **blank access/secret keys** (→ IRSA via Task 9), public base URL = the S3 virtual-hosted URL:
  ```bash
  put core-s3 "$(jq -n --arg b "$S3_BUCKET" '{
    "s3.endpoint":"",
    "s3.public-endpoint":("https://"+$b+".s3.ap-southeast-1.amazonaws.com"),
    "s3.region":"ap-southeast-1","s3.bucket":$b,
    "s3.access-key":"","s3.secret-key":"","s3.path-style":"false",
    "s3.public-base-url":("https://"+$b+".s3.ap-southeast-1.amazonaws.com"),
    "s3.presign-ttl":"PT5M","s3.max-upload-size":"5242880",
    "s3.allowed-types":"image/jpeg,image/png,image/webp"
  }')"
  ```
  - ⚠️ **Verify during execution:** `S3Config.java` must tolerate a blank `s3.endpoint` (use the SDK default region endpoint when blank) and `path-style=false`. If `S3Config` always calls `.endpointOverride(...)`, add a blank-guard there too (same pattern as Task 9). Check `S3Config.java` lines that read `props.getEndpoint()` before applying.
- [ ] **Step 3: Offline gate** — `bash -n scripts/aws/seed-secrets.sh`.
- [ ] **Step 4: Commit:**
  ```bash
  git add scripts/aws/seed-secrets.sh
  git commit -m "feat(aws): core-s3 seed points at real S3 with IRSA (Phase 4c)"
  ```

### Task 13: [USER runs / CLAUDE verifies] Apply & verify 4c

- [ ] **Step 1 (USER):** rebuild + push the two S3 services (Task 9 changed core-s3, so their images must be rebuilt against the new core JAR — see memory `project_k8s_cores_image_rebuild`): `scripts/aws/push-images.sh authorization-server` then `… product-service` (each rebuilds maven-cores first).
- [ ] **Step 2 (USER):** `terraform -chdir=aws/main apply` (bucket + IRSA roles, ~1 min).
- [ ] **Step 3 (USER):** `scripts/aws/stamp-s3-irsa.sh` (annotate the two SAs with their role ARNs), then re-run `seed-secrets.sh`.
- [ ] **Step 4 (USER):** `kubectl apply -k k8s/apps/overlays/aws/authorization-server && kubectl apply -k k8s/apps/overlays/aws/product-service`, then `kubectl rollout restart deployment -n apps authorization-server product-service`.
- [ ] **Step 5 (CLAUDE verifies):** Expected — presign an avatar (`POST /authorization-server/v1/users/self/avatar/presign`), `PUT` bytes to the returned S3 URL, then `PUT …/avatar {objectKey}` returns 200 and the public URL fetches the image. No `AccessDenied` (IRSA scoped correctly) and no static-key errors (Task 9 fallback working).
- [ ] **Step 6:** Update memory → "Phase 4c (S3+IRSA) DONE; Phase 4 complete".

---

# Finalization

### Task 14: [CLAUDE] Teardown leak guard for the new managed resources

**Files:**
- Modify: `scripts/aws/down.sh`

- [ ] **Step 1:** RDS/ElastiCache/S3 are all `module.eks`/root-module Terraform resources, so `terraform destroy` (already in down.sh) removes them. Add a post-destroy leak check mirroring the existing Secrets-Manager one:
  ```bash
  echo "▶ post-destroy RDS / ElastiCache / S3 leak check:"
  aws rds describe-db-instances --region ap-southeast-1 \
    --query "DBInstances[?starts_with(DBInstanceIdentifier,'microecom')].DBInstanceIdentifier" --output table || true
  aws elasticache describe-cache-clusters --region ap-southeast-1 \
    --query "CacheClusters[?starts_with(CacheClusterId,'microecom')].CacheClusterId" --output table || true
  aws s3 ls | grep microecom-media || echo "  no media bucket lingering"
  ```
  - ⚠️ **S3 bucket destroy:** a non-empty bucket blocks `terraform destroy`. Either set `force_destroy = true` on `aws_s3_bucket.media` (Task 10 — add it; acceptable for an ephemeral sandbox bucket) OR empty it in down.sh before destroy. **Prefer `force_destroy = true`** and note the tradeoff (never on a prod bucket).
- [ ] **Step 2:** If `force_destroy` is the chosen path, tell the HUMAN to add `force_destroy = true` to `aws_s3_bucket.media` in `s3.tf` (one line) and re-review.
- [ ] **Step 3: Commit:**
  ```bash
  git add scripts/aws/down.sh
  git commit -m "chore(aws): teardown leak check for RDS/ElastiCache/S3 (Phase 4)"
  ```

### Task 15: [CLAUDE] Update progress memory + spec status

- [ ] Update `project_aws_deploy_progress` memory: Phase 4 complete (RDS primary+replica, ElastiCache, S3+IRSA); note the four substitutions landed and the seed-secrets value-flow.
- [ ] One-line note in the deployment spec or a short `docs/superpowers/plans/` status if the team tracks phase completion there.

---

## Self-Review (run by Claude after writing)

**Spec coverage (design §3–§4 "four substitutions" table):**
- MySQL master+2 slaves → RDS primary + 1 replica (JDBC URLs only) → Tasks 1,3 ✅
- Redis pod → ElastiCache (host/port config) → Tasks 6,7 ✅
- MinIO → S3 + IRSA → Tasks 9–12 ✅
- Secrets Manager already done (Phase 3) — Phase 4 only rewrites values ✅
- §3 "both slave JDBC URLs point at the single replica" → Task 3 Step 2 (slave1+slave2 = `$RDS_REPLICA`) ✅
- §4 "hand-written resources for S3/IAM so raw Terraform is learned" → s3.tf is HUMAN ✅

**Placeholder scan:** `ROLE_ARN_PLACEHOLDER` in Task 11 is intentional and resolved by the stamp script (Option b) — flagged, not a gap. No "TBD"/"handle edge cases". HUMAN tasks intentionally omit solutions (coworking constraint) but every one lists concrete requirements + attribute names.

**Type/name consistency:** output names (`rds_primary_endpoint`, `rds_replica_endpoint`, `redis_endpoint`, `s3_bucket_name`, `db_master_password`, `*_s3_role_arn`) are referenced identically in the seed-secrets reads and the verify steps. RDS attr `db_instance_address`, ElastiCache `cache_nodes[0].address`, caller-identity `account_id` all named consistently. SA namespace `apps:<svc>` matches between s3.tf IRSA trust and the SA manifests.

**Known execution-time checks flagged inline:** (a) `S3Config.java` blank-endpoint tolerance (Task 12 Step 2), (b) consolidate the two-pod seed if cleaner (Task 4), (c) `force_destroy` choice (Task 14).
