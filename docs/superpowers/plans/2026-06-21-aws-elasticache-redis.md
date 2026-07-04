# AWS ElastiCache Redis (Phase 4b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision managed ElastiCache Redis on AWS and point the app at it, so the three redis-readiness services come up Ready and `make aws-all` reaches a fully green stack.

**Architecture:** A new `aws/main/elasticache.tf` (single-node `aws_elasticache_replication_group`, no TLS / no AUTH — exact local parity) provisions inside `up-all.sh` step 1's `terraform apply`, in parallel with RDS/EKS. `seed-secrets.sh` swaps the phantom in-cluster Redis host for the ElastiCache endpoint in a single shared-secret jq block. The runner and Makefile are unchanged; two docs get wording touch-ups.

**Tech Stack:** Terraform (HCL, AWS provider), Bash, jq, AWS ElastiCache (Redis), EKS. No app code change (Redisson connects `redis://` with an empty password).

**Verification model:** This is infra/bash/docs — there is no unit-test harness. The TDD analog is **offline gates**: `terraform fmt -check`, `bash -n`, and targeted `grep`. They run with **zero AWS spend**. The billed end-to-end (`make aws-all`) is the **user's** to run — never run it, `terraform apply/destroy/output`, `aws`, or `kubectl`-against-a-cluster yourself.

**Coworking-learning note:** Task 2 is a **`[CHECKPOINT — HUMAN ✍️]`** — the user writes the Terraform resource bodies himself for interview prep. Task 1 scaffolds the skeleton (comments + `TODO(HUMAN)` markers, no resource bodies). Do **not** write the PART A/B/C/D solutions; pause and hand off after Task 1, resume at Task 3 after the user says "review".

---

## File Structure

| File | Responsibility | Owner |
|---|---|---|
| `aws/main/elasticache.tf` | Skeleton (Task 1, Claude) → resource bodies (Task 2, HUMAN). The managed Redis: SG, subnet group, single-node replication group, endpoint output. | Claude scaffolds / HUMAN fills |
| `scripts/aws/seed-secrets.sh` | Swap `spring.data.redis.host` in the shared `app/ecommerce` secret from the in-cluster phantom to the ElastiCache endpoint. | Claude |
| `scripts/aws/up-all.sh` | Doc-only: step-1 banner + ORDER comment + persist note name ElastiCache. | Claude |
| `scripts/aws/RUNBOOK.md` | Doc-only: persist note + step-1 verify + step-5 description name ElastiCache. | Claude |

Explicitly unchanged: `Makefile` (`aws-all` already rides `terraform apply`), `scripts/aws/leak-check.sh` (scans only TF-escapees — RDS/ElastiCache are TF-managed, destroyed cleanly), `core-redis` / app code (Option A is config-only).

---

### Task 1: Scaffold `aws/main/elasticache.tf` (Claude — skeleton only)

Mirror the teaching shape of `aws/main/rds.tf`: a header explaining WHY, then PART A/B/C/D comment blocks listing exactly what to write, each followed by a `# TODO(HUMAN): ...` marker and **no resource body**. The user fills the bodies in Task 2.

**Files:**
- Create: `aws/main/elasticache.tf`

- [ ] **Step 1: Create the skeleton file**

Create `aws/main/elasticache.tf` with exactly this content:

```hcl
# aws/main/elasticache.tf  —  [CHECKPOINT — HUMAN ✍️]  (Phase 4b)
#
# WHY THIS FILE EXISTS
# Three services (authorization-server, order-service, inventory-service) gate
# their readiness probe on a live Redis (readiness.include: ...,redis). Until now
# Redis ran as a self-hosted in-cluster Deployment (redis-master.infra). We're
# swapping that for managed Amazon ElastiCache. The apps don't change — they read
# spring.data.redis.host from Secrets Manager, and seed-secrets.sh (Task 3, Claude)
# will point it at the ElastiCache endpoint.
#
# The whole substitution is two moves, and THIS FILE is move #1:
#   move #1 (here):        Terraform creates ElastiCache + a security group that
#                          admits the EKS node SG on 6379.
#   move #2 (seed-secrets): swap the in-cluster DNS host for the ElastiCache endpoint.
#
# Network model — identical to rds.tf (the "IAM of the network" beat):
# ElastiCache lives in the VPC private subnets with NO public access. It is
# reachable ONLY because its security group allows inbound 6379 from the EKS *node*
# security group. SG-to-SG, never a CIDR — the rule follows the nodes as they
# scale/replace. (Exactly what you did for RDS on 3306.)
#
# SECURITY POSTURE — Phase 4b is Option A: transit_encryption_enabled = false and
# NO auth token. This is EXACT local parity (the in-cluster redis is a pure cache,
# no auth, no TLS) and the smallest change to go green. TLS + RedisAUTH are coupled
# on ElastiCache (a token requires transit encryption) and need a core-redis
# rediss:// code change — deliberately deferred to Phase 4d.
#
# ─────────────────────────────────────────────────────────────────────────────
# PART A — [HUMAN ✍️]  the cache security group   resource "aws_security_group" "redis"
#   - vpc_id = module.vpc.vpc_id
#   - ONE ingress rule: protocol "tcp", from_port/to_port = 6379,
#       security_groups = [module.eks.node_security_group_id]   # NOT a cidr_block
#   - egress all: from/to 0, protocol "-1", cidr_blocks = ["0.0.0.0/0"]
# TODO(HUMAN): write resource "aws_security_group" "redis" here
#
# ─────────────────────────────────────────────────────────────────────────────
# PART B — [HUMAN ✍️]  the cache subnet group   resource "aws_elasticache_subnet_group" "main"
#   - name        = "${var.project}-redis"
#   - subnet_ids  = module.vpc.private_subnets    # >=2 AZs, same as the DB subnet group.
#       (Nodes are pinned to private_subnets[0]; ElastiCache is NOT AZ-locked like
#        EBS, so cross-AZ reach from the node to the cache is fine.)
# TODO(HUMAN): write resource "aws_elasticache_subnet_group" "main" here
#
# ─────────────────────────────────────────────────────────────────────────────
# PART C — [HUMAN ✍️]  the Redis node   resource "aws_elasticache_replication_group" "redis"
#   Requirements:
#     - replication_group_id      = "${var.project}-redis"
#     - description                = "microecom cache (Phase 4b, single node)"
#     - engine="redis", engine_version="7.1"
#     - node_type="cache.t4g.micro"            (Graviton, matches the t4g theme)
#     - num_cache_clusters         = 1          (single node — no replica in 4b)
#     - automatic_failover_enabled = false      (required false for a single node)
#     - transit_encryption_enabled = false      (Option A — local parity, no app change)
#     - port                       = 6379
#     - parameter_group_name       = "default.redis7"
#     - subnet_group_name          = aws_elasticache_subnet_group.main.name
#     - security_group_ids         = [aws_security_group.redis.id]
#   🎓 Why aws_elasticache_replication_group with num_cache_clusters=1 (not the
#     simpler aws_elasticache_cluster): the replication group exposes a stable
#     primary_endpoint_address regardless of node count. Phase 4d (add a replica)
#     becomes a one-number change and the endpoint the app reads never moves.
#   Docs: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_replication_group
# TODO(HUMAN): write resource "aws_elasticache_replication_group" "redis" here
#
# ─────────────────────────────────────────────────────────────────────────────
# PART D — [HUMAN ✍️]  output (seed-secrets.sh reads this)
#   output "redis_primary_endpoint" {
#     value = aws_elasticache_replication_group.redis.primary_endpoint_address
#   }
#   NOTE: primary_endpoint_address is host only (no :6379). seed-secrets.sh sets
#   spring.data.redis.port separately — keep this host-only, same as rds.tf.
#
# 🎓 Interview prep — be ready to explain:
#   - SG-to-SG ingress on 6379 vs a CIDR allowlist (follows the nodes; no IP drift).
#   - Why ElastiCache is NOT AZ-locked the way an EBS volume is.
#   - Option A vs B: TLS + RedisAUTH are coupled on ElastiCache; enabling them needs
#     a Redisson redis://→rediss:// change in core-redis — that's Phase 4d, not now.
#   - primary_endpoint_address (host) vs configuration_endpoint (cluster mode) —
#     why single-node cluster-mode-disabled uses the primary endpoint.
# TODO(HUMAN): write output "redis_primary_endpoint" here
#
# Write PART A–D above the TODO markers, then tell Claude "review".
# ─────────────────────────────────────────────────────────────────────────────
```

- [ ] **Step 2: Offline gate — file is valid HCL comments and lists all four parts**

Run:
```bash
terraform fmt -check aws/main/elasticache.tf && \
grep -cE '^# PART [A-D] ' aws/main/elasticache.tf
```
Expected: `terraform fmt -check` exits 0 (no diff — a comments-only file is already canonical), and the grep prints `4` (PART A, B, C, D present). If `terraform` is unavailable, substitute `bash -lc 'test -f aws/main/elasticache.tf'` and rely on the grep alone.

- [ ] **Step 3: Commit**

```bash
git add aws/main/elasticache.tf
git commit -m "$(cat <<'EOF'
feat(aws): scaffold elasticache.tf skeleton (Phase 4b HUMAN checkpoint)

PART A/B/C/D comment guidance + TODO(HUMAN) markers mirroring rds.tf, no
resource bodies — the user writes the ElastiCache resources for interview prep.
Single-node replication_group, transit_encryption off / no AUTH (Option A).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: STOP — hand off to the human**

This is the `[CHECKPOINT — HUMAN ✍️]` boundary. Output the coworking handoff header and stop. Do **not** start Task 2's resource bodies.

```
## What I did
- aws/main/elasticache.tf   — skeleton: PART A/B/C/D guidance + TODO(HUMAN) markers

## What YOU need to write
- aws/main/elasticache.tf   — PART A (SG, ingress 6379 from node SG), PART B
                              (subnet group on private_subnets), PART C
                              (single-node replication_group), PART D
                              (output redis_primary_endpoint). Then say "review".
```

---

### Task 2: `[CHECKPOINT — HUMAN ✍️]` — user writes the resource bodies, Claude reviews

**The user writes PART A–D in `aws/main/elasticache.tf`.** When the user says "review", Claude verifies — but does **not** author the resources.

**Files:**
- Modify: `aws/main/elasticache.tf` (HUMAN writes the four `TODO(HUMAN)` blocks)

- [ ] **Step 1: Wait for the user to write the bodies and say "review"**

Do not proceed until the user signals the resources are written.

- [ ] **Step 2: Offline gate — formatting**

Run:
```bash
terraform fmt -check aws/main/elasticache.tf
```
Expected: exits 0. If it reports a diff, run `terraform fmt aws/main/elasticache.tf` to normalize and note it in the review.

- [ ] **Step 3: Offline gate — required properties present**

Run:
```bash
grep -E 'security_groups *= *\[module\.eks\.node_security_group_id\]' aws/main/elasticache.tf && \
grep -E 'from_port *= *6379|to_port *= *6379' aws/main/elasticache.tf && \
grep -E 'subnet_ids *= *module\.vpc\.private_subnets' aws/main/elasticache.tf && \
grep -E 'num_cache_clusters *= *1' aws/main/elasticache.tf && \
grep -E 'transit_encryption_enabled *= *false' aws/main/elasticache.tf && \
grep -E 'automatic_failover_enabled *= *false' aws/main/elasticache.tf && \
grep -E 'node_type *= *"cache\.t4g\.micro"' aws/main/elasticache.tf && \
grep -E 'output "redis_primary_endpoint"' aws/main/elasticache.tf && \
grep -E 'primary_endpoint_address' aws/main/elasticache.tf
```
Expected: every line matches (each prints its found line). Any miss = the corresponding requirement is not yet met — point the user at the specific PART, don't fix it yourself.

- [ ] **Step 4: Review and report (no commit yet — the user commits their own checkpoint work, or asks Claude to)**

Confirm in prose: SG-to-SG (not a CIDR) on 6379, subnet group on `module.vpc.private_subnets`, single-node (`num_cache_clusters = 1`, `automatic_failover_enabled = false`), `transit_encryption_enabled = false`, and the `redis_primary_endpoint` output reads `primary_endpoint_address`. Note that `terraform validate`/`apply` (which would prove the schema against AWS) is the user's billed step — the offline gates above are as far as Claude verifies.

> **Note:** `terraform validate` is NOT an offline-safe gate here — it requires `terraform init` (provider download) and a complete resource graph. Leave it to the user's `make aws-all` run; do not run it.

---

### Task 3: Point `seed-secrets.sh` at the ElastiCache endpoint (Claude)

Redis config lives in exactly one place: the shared `app/ecommerce` secret (the `put ecommerce` block) that every service reads via the ClusterSecretStore. Per-service blocks carry no redis keys. So this is a single-block edit: read the new TF output, thread it through jq, and replace the hardcoded in-cluster host.

**Files:**
- Modify: `scripts/aws/seed-secrets.sh` (the `RDS_*` output block ~line 41, the `put ecommerce` jq args ~line 71, and the redis host ~line 81)

- [ ] **Step 1: Read the new output beside the RDS outputs**

In `scripts/aws/seed-secrets.sh`, find:
```bash
RDS_PRIMARY="$(tf_out rds_primary_endpoint)"
RDS_REPLICA="$(tf_out rds_replica_endpoint)"
DB_PASS="$(tf_out db_master_password)"
```
Add a line so it reads:
```bash
RDS_PRIMARY="$(tf_out rds_primary_endpoint)"
RDS_REPLICA="$(tf_out rds_replica_endpoint)"
REDIS_HOST="$(tf_out redis_primary_endpoint)"
DB_PASS="$(tf_out db_master_password)"
```
(`tf_out` already fails loud with an actionable message if the output is missing — no extra guard needed.)

- [ ] **Step 2: Thread the host into the shared-secret jq invocation**

Find the `put ecommerce` opener:
```bash
put ecommerce "$(jq -n \
  --arg mu "$APPLICATION_MAIL_USERNAME" --arg mp "$APPLICATION_MAIL_PASSWORD" \
  --arg dpw "$DB_PASS" --arg mhost "$RDS_PRIMARY" --arg rhost "$RDS_REPLICA" '{
```
Append `--arg redishost "$REDIS_HOST"` to the third line so it reads:
```bash
put ecommerce "$(jq -n \
  --arg mu "$APPLICATION_MAIL_USERNAME" --arg mp "$APPLICATION_MAIL_PASSWORD" \
  --arg dpw "$DB_PASS" --arg mhost "$RDS_PRIMARY" --arg rhost "$RDS_REPLICA" --arg redishost "$REDIS_HOST" '{
```

- [ ] **Step 3: Replace the hardcoded redis host**

Find:
```bash
  "spring.data.redis.host":"redis-master.infra.'"$DNS"'","spring.data.redis.port":"6379",
```
Replace with (use the jq `$redishost` arg; port/password unchanged — Option A keeps the empty password on the next line):
```bash
  "spring.data.redis.host":$redishost,"spring.data.redis.port":"6379",
```

- [ ] **Step 4: Offline gate — shell syntax + the swap actually happened**

Run:
```bash
bash -n scripts/aws/seed-secrets.sh && \
grep -q '"spring.data.redis.host":\$redishost,' scripts/aws/seed-secrets.sh && \
! grep -q 'redis-master.infra' scripts/aws/seed-secrets.sh && \
grep -q 'REDIS_HOST="\$(tf_out redis_primary_endpoint)"' scripts/aws/seed-secrets.sh && \
echo GATE_OK
```
Expected: prints `GATE_OK`. (Confirms: valid bash; host now reads `$redishost`; the in-cluster phantom string is gone; the new output is read.)

- [ ] **Step 5: Offline gate — the jq template still parses with the new arg**

Run (proves the `$redishost` reference resolves inside the jq object — uses dummy values, hits no AWS):
```bash
jq -n --arg mu x --arg mp x --arg dpw x --arg mhost x --arg rhost x --arg redishost test.host '{
  "spring.data.redis.host":$redishost,"spring.data.redis.port":"6379",
  "spring.data.redis.password":""
}'
```
Expected: prints a JSON object with `"spring.data.redis.host": "test.host"`. A jq parse error here means the arg name is mismatched — fix before committing.

- [ ] **Step 6: Commit**

```bash
git add scripts/aws/seed-secrets.sh
git commit -m "$(cat <<'EOF'
feat(aws): point seed-secrets redis host at ElastiCache endpoint

Read redis_primary_endpoint (Task 2 TF output) and write it into the shared
app/ecommerce secret's spring.data.redis.host, replacing the phantom in-cluster
redis-master.infra host. Single-block change — redis config lives only in the
shared secret. Port 6379 / empty password unchanged (Option A).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Doc touch-ups — name ElastiCache in the runner + runbook (Claude)

No logic change. Make the step-1 / persistence / step-5 wording mention ElastiCache so the docs match reality (ElastiCache is created in step 1 and wired in step 5).

**Files:**
- Modify: `scripts/aws/up-all.sh` (ORDER comment line ~16, persist comment lines ~8-11, step-1 banner line ~88, step-5 comment line ~21)
- Modify: `scripts/aws/RUNBOOK.md` (persist note line ~8, step-1 verify lines ~22-29, step-5 description lines ~54-58)

- [ ] **Step 1: `up-all.sh` — ORDER comment**

Find:
```
#   1 up.sh        VPC+EKS+ALB+ESO IRSA+RDS, kubeconfig (RDS outputs exist after)
```
Replace with:
```
#   1 up.sh        VPC+EKS+ALB+ESO IRSA+RDS+ElastiCache, kubeconfig (endpoints exist after)
```

- [ ] **Step 2: `up-all.sh` — step-5 ORDER comment**

Find:
```
#   5 seed-secrets RDS JDBC URLs + app config → Secrets Manager (needs step-1
```
Replace with:
```
#   5 seed-secrets RDS JDBC URLs + Redis host + app config → Secrets Manager (needs step-1
```

- [ ] **Step 3: `up-all.sh` — persist comment**

Find:
```
# WHAT PERSISTS across aws-down: aws/bootstrap (ECR repos, TF state, lock table)
# is a SEPARATE stack — aws-down only destroys aws/main, so pushed ECR images
```
Leave both lines as-is (they don't enumerate `aws/main` resources). No change needed here — the enumerated resource list lives in the step-1 banner (Step 4) and RUNBOOK (Step 6).

- [ ] **Step 4: `up-all.sh` — step-1 banner**

Find:
```bash
banner "Step 1/9 · terraform apply (VPC + EKS + ALB + ESO IRSA + RDS) — ~15-20 min"
```
Replace with:
```bash
banner "Step 1/9 · terraform apply (VPC + EKS + ALB + ESO IRSA + RDS + ElastiCache) — ~15-20 min"
```

- [ ] **Step 5: Offline gate — `up-all.sh` still parses**

Run:
```bash
bash -n scripts/aws/up-all.sh && grep -c ElastiCache scripts/aws/up-all.sh
```
Expected: `bash -n` exits 0; grep prints `2` (ORDER comment line 1 + step-1 banner).

- [ ] **Step 6: `RUNBOOK.md` — persist note**

Find:
```
`aws-down` destroys **`aws/main` only** (VPC, EKS, ALB, RDS). The separate
```
Replace with:
```
`aws-down` destroys **`aws/main` only** (VPC, EKS, ALB, RDS, ElastiCache). The separate
```

- [ ] **Step 7: `RUNBOOK.md` — step-1 verify**

Find:
```bash
kubectl get nodes                                   # nodes Ready
terraform -chdir=aws/main output rds_primary_endpoint
```
Replace with:
```bash
kubectl get nodes                                   # nodes Ready
terraform -chdir=aws/main output rds_primary_endpoint
terraform -chdir=aws/main output redis_primary_endpoint
```

- [ ] **Step 8: `RUNBOOK.md` — step-5 description**

Find:
```
**Why before apps:** pushes the RDS JDBC URLs (from step-1 outputs) + app config
into Secrets Manager; the apps' ExternalSecrets sync from here. Reads PayPal/mail
```
Replace with:
```
**Why before apps:** pushes the RDS JDBC URLs + the ElastiCache Redis host (from
step-1 outputs) + app config into Secrets Manager; the apps' ExternalSecrets sync
from here. Reads PayPal/mail
```

- [ ] **Step 9: Offline gate — RUNBOOK mentions ElastiCache/Redis in the right places**

Run:
```bash
grep -c -E 'ElastiCache|redis_primary_endpoint' scripts/aws/RUNBOOK.md
```
Expected: prints `3` (persist note + step-1 verify output + step-5 description).

- [ ] **Step 10: Commit**

```bash
git add scripts/aws/up-all.sh scripts/aws/RUNBOOK.md
git commit -m "$(cat <<'EOF'
docs(aws): name ElastiCache in runner + runbook (Phase 4b)

Step-1 banner/ORDER comment, persist note, and step-5 description now mention
ElastiCache (created in step 1) and the Redis host (wired in step 5). No logic
change — ElastiCache rides the existing terraform apply.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Managed ElastiCache in `aws/main`, single-node replication group, Option A (no TLS/AUTH) → Task 1 scaffold + Task 2 HUMAN bodies. ✓
- HUMAN-checkpoint coworking split (user writes the TF) → Task 1 hands off, Task 2 is the checkpoint, Claude reviews but doesn't author. ✓
- `seed-secrets.sh` single-block host swap → Task 3. ✓
- Doc touch-ups (`up-all.sh`, `RUNBOOK.md`), no Makefile/leak-check change → Task 4 + the "Explicitly unchanged" table. ✓
- Offline gates only; billed run is the user's → every task ends on `terraform fmt -check`/`bash -n`/`grep`/`jq`, none of which bill; the plan repeatedly states `apply`/`validate`/`make aws-all` are the user's. ✓
- Endpoint flow (step 1 creates → step 5 wires → step 6 readiness clears) → captured in the header Architecture + Task 3. ✓

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". The only `TODO(HUMAN)` strings are intentional checkpoint markers inside the scaffold file content, not plan gaps.

**Type/name consistency:** The TF output name `redis_primary_endpoint`, the jq arg `redishost`, the bash var `REDIS_HOST`, and the resource attribute `primary_endpoint_address` are used identically across Tasks 1→2→3 and the verify greps. SG ingress port `6379`, `cache.t4g.micro`, `num_cache_clusters = 1`, `automatic_failover_enabled = false`, `transit_encryption_enabled = false` match between the Task 1 scaffold guidance and the Task 2 verification greps.
