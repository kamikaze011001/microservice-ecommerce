# AWS ElastiCache Redis (Phase 4b) — Design

**Date:** 2026-06-21
**Branch:** `feat/aws-deploy` (continuation — full-AWS-ecosystem workstream, no new branch)
**Status:** Approved design → ready for implementation plan

## Goal

Provision managed Redis (ElastiCache) on AWS so the three services whose readiness
probe includes `redis` come up Ready, and `make aws-all` reaches a fully green
stack that runs "like local." This is the hard prerequisite that unblocks the
from-scratch runner: today there is no Redis on AWS and `seed-secrets.sh` points
the app at an in-cluster host that doesn't exist.

## Problem

Three services declare `management.endpoint.health.group.readiness.include:
readinessState,db,redis`:

- `authorization-server/src/main/resources/application.yml:49`
- `order-service/src/main/resources/application.yml:60`
- `inventory-service/src/main/resources/application.yml:56`

With `redis` in the readiness group, the pod is **not Ready until the Redis
health indicator is UP**. On AWS there is no Redis: `seed-secrets.sh:81` ships
`spring.data.redis.host = redis-master.infra.svc.cluster.local`, a Service that
`infra-up.sh` never deploys (Mongo/Kafka stay in-cluster in Phase 4; Redis was
slated to move to a managed service). Result: those three deployments never go
Ready, and `up-all.sh`'s step-6 rollout gate (which *requires* `authorization-server`
and `inventory-service`) times out at 600s. `make aws-all` cannot go green until
Redis exists on AWS and the app is pointed at it.

## Decision: managed ElastiCache, Option A (no TLS / no AUTH)

**Backing store — ElastiCache (managed), not in-cluster Redis.** Aligns with the
"fully AWS ecosystem" goal and mirrors the existing RDS pattern (`aws/main/rds.tf`),
whose own comment foreshadows this: *"(Same idea you'll repeat for Redis.)"*

**Security posture — Option A: `transit_encryption_enabled = false`, no AUTH
token.** This is an explicit, evidence-based choice between a binary fork (the two
are *coupled* on ElastiCache — an `auth_token` is only permitted when transit
encryption is enabled, so "password but no TLS," which the redis manifest comment
imagined, is not actually possible on ElastiCache):

| | **A — no TLS, no AUTH** (chosen) | **B — TLS + AUTH** (deferred → Phase 4d) |
|---|---|---|
| App change | none (config only) | one line in `core-redis` `RedisConfiguration.java:43` (`redis://` → `rediss://`) + rebuild cores image + all service images |
| ElastiCache | `transit_encryption_enabled = false` | `= true` + `auth_token` |
| `seed-secrets.sh` | `spring.data.redis.password = ""` | password = the AUTH token |
| Exposure | private subnet, SG-locked to node SG (not internet-reachable) | same + encrypted in transit |

**Why A for 4b:** it meets the stated goal ("run successfully like in local env",
unblock `make aws-all`) with the smallest blast radius, and exactly matches the
local posture — `k8s/infra/manifests/redis.yaml:4-5` runs a "pure cache: no auth,
no persistence," and `seed-secrets.sh:82` already ships an empty password. The
cache lives in a private subnet reachable only via SG-to-SG from the node group,
so it is not internet-exposed.

**Why B is its own phase, not now:** the app runs **two** Redis clients — Lettuce
(Spring auto-config, would honor `spring.data.redis.ssl.enabled` as pure config)
and **Redisson** (`core-redis/.../RedisConfiguration.java:43`), which hardcodes the
`redis://` scheme. TLS-on therefore requires a code change (`rediss://`) + a cores
image rebuild + all service image rebuilds — a clean, self-contained hardening unit
better done on its own as Phase 4d. AUTH (the password) is already pure-config
(lines 47-49 set it only when non-empty), but ElastiCache couples it to TLS, so it
rides along with 4d.

## Architecture

ElastiCache lives in the `aws/main` Terraform stack — the same stack as VPC / EKS /
ALB / RDS. Therefore it is provisioned **inside** `up-all.sh` step 1
(`terraform apply`), in parallel with RDS and EKS (no added wall-clock), and is
**destroyed and recreated by `aws-down` / a from-scratch re-run**, exactly like RDS.
The runner needs **no structural change**: step 1 already applies the whole stack,
and step 5 (`seed-secrets.sh`) already runs before the apps so the ExternalSecrets
resolve a real endpoint.

```
make aws-all ──▶ up-all.sh
  1. terraform apply (aws/main)   ← NOW also creates ElastiCache + output redis_primary_endpoint
  ...
  5. seed-secrets.sh              ← redis.host = $(tf_out redis_primary_endpoint), was a phantom in-cluster host
  6. apps + rollout gate          ← redis health UP → auth-server/inventory/order Ready → gate clears
```

| Layer | Stack | Survives `aws-down`? |
|---|---|---|
| ECR images, TF state, lock table | `aws/bootstrap` | Yes |
| VPC, EKS, ALB, RDS, **ElastiCache** | `aws/main` | No (rebuilt) |

## Components

### New file — `aws/main/elasticache.tf` — `[CHECKPOINT — HUMAN ✍️]`

The user writes this himself (interview-prep learning), mirroring `aws/main/rds.tf`
beat-for-beat. Claude scaffolds the PART A/B/C/D skeleton with `TODO` markers and
reviews; Claude does **not** write the solution.

- **PART A** — `aws_security_group "redis"`: ingress `tcp 6379` from
  `module.eks.node_security_group_id` (SG-to-SG, never a CIDR), egress all.
- **PART B** — `aws_elasticache_subnet_group "main"`:
  `subnet_ids = module.vpc.private_subnets`.
- **PART C** — `aws_elasticache_replication_group "redis"`:
  `node_type = "cache.t4g.micro"`, `engine = "redis"`, `num_cache_clusters = 1`,
  `automatic_failover_enabled = false`, `transit_encryption_enabled = false`,
  `port = 6379`, wired to PART A's SG (`security_group_ids`) and PART B's subnet
  group (`subnet_group_name`).
- **PART D** — `output "redis_primary_endpoint"`
  `{ value = aws_elasticache_replication_group.redis.primary_endpoint_address }`.

**Why `replication_group` with `num_cache_clusters = 1`, not `aws_elasticache_cluster`:**
the replication group exposes a stable `primary_endpoint_address` regardless of
node count, so Phase 4d (scale to a replica) is a one-number change and the
endpoint the app reads never moves. `aws_elasticache_cluster` would force reading
`cache_nodes[0].address` and rewiring the output when a node is added.

### Modified file — `scripts/aws/seed-secrets.sh` — *Claude owns*

Redis config lives in **one** place: the shared `app/ecommerce` secret (the
`put ecommerce` block, lines 69-92) that every service reads via the
ClusterSecretStore. Per-service blocks (`authorization-server`, `order-service`,
`orchestrator-service`, …) carry no redis keys — they inherit from the shared
secret. The edit is therefore a single jq block:

1. Add `REDIS_HOST="$(tf_out redis_primary_endpoint)"` beside the existing
   `RDS_PRIMARY` / `RDS_REPLICA` lines (~42). `tf_out` (lines 37-39) already fails
   loud if the output is missing.
2. Thread `--arg redishost "$REDIS_HOST"` into the `put ecommerce` jq invocation
   (line 71's arg list).
3. Change line 81 from the hardcoded
   `"spring.data.redis.host":"redis-master.infra.'"$DNS"'"` to
   `"spring.data.redis.host":$redishost`.

Port stays `6379`; `spring.data.redis.password` stays `""` (Option A); database
stays `0`.

### Doc touch-ups — `scripts/aws/up-all.sh`, `scripts/aws/RUNBOOK.md` — *Claude owns*

Documentation only, **no logic change**. Confirm the step-1 banner and the
"what persists across `aws-down`" note name ElastiCache as an `aws/main` resource
created in step 1 and wired by step 5. (The runner spec already lists ElastiCache
in its persistence table — this is a wording confirmation, not a new step.)

### Explicitly unchanged

- **`Makefile`** — `aws-all` already exists and rides `terraform apply`; no new
  target.
- **`scripts/aws/leak-check.sh`** — scans only resources that *escape* Terraform
  (NAT gateways, EIPs, ELBs, unattached EBS volumes). RDS is not in it because
  Terraform destroys it cleanly; ElastiCache is identical (TF-managed in
  `aws/main`), so it is intentionally **not** added — matching the RDS precedent.
- **`core-redis` / app code** — Option A is config-only; Redisson connects with
  the existing `redis://` scheme and an empty password.

## Data flow

1. `terraform apply` (step 1) creates the ElastiCache replication group and
   publishes `redis_primary_endpoint`.
2. `seed-secrets.sh` (step 5) reads that output and writes
   `spring.data.redis.host` into the `app/ecommerce` Secrets Manager secret,
   before the apps start.
3. Apps boot (step 6); ESO has materialized the secret; `core-redis`'s Redisson
   client connects `redis://<endpoint>:6379` with no password.
4. The `redis` health indicator goes UP → the three redis-readiness services
   reach Ready → the step-6 rollout gate (auth-server + inventory-service)
   clears → the SQL seeds (steps 7-8) run → stack is green.

## Error handling

- **Missing TF output fails loud:** `tf_out redis_primary_endpoint` aborts
  `seed-secrets.sh` with an actionable message if step 1 didn't run / the output
  is absent — no silent empty host.
- **Readiness is the backstop:** if Redis is unreachable, the `redis` health
  indicator stays DOWN and the step-6 rollout gate surfaces the failing
  deployment's state (it already `describe`s + points at logs on timeout) rather
  than masking a broken cache.
- **Idempotent resume:** `terraform apply` is a no-op when current;
  `seed-secrets.sh` overwrites the secret each run. A re-run after a mid-way
  failure is safe.

## Verification

Offline gates only (no AWS spend; Claude runs these):
- `terraform fmt -check` on `aws/main/elasticache.tf` (HUMAN file, after the user
  writes it — Claude reviews and fmt-checks).
- `bash -n scripts/aws/seed-secrets.sh`.
- `grep` proving `spring.data.redis.host` now reads `$redishost` (the TF output),
  not the in-cluster phantom.

The billed end-to-end run is the user's:
- `make aws-all` from a clean teardown → all steps green; the step-6 rollout gate
  clears (previously timed out on redis-readiness).
- Verify: login returns a JWT; catalog lists products; cart shows real stock;
  `authorization-server` / `inventory-service` / `order-service` are Ready.
- `make aws-down` after; ElastiCache is destroyed with the rest of `aws/main`.

## Coworking-learning split

| Artifact | Owner |
|---|---|
| `aws/main/elasticache.tf` (PART A/B/C/D) | **HUMAN ✍️** — writes it for interview prep; Claude scaffolds the skeleton + `TODO`s and reviews |
| `scripts/aws/seed-secrets.sh` redis swap | Claude |
| `up-all.sh` / `RUNBOOK.md` wording | Claude |
| Offline gates | Claude |
| `make aws-all` (billed) | HUMAN — runs it |

## Out of scope

- **TLS + RedisAUTH (Phase 4d)** — the `rediss://` code change in `core-redis` +
  image rebuilds; documented above as the deferred B option.
- **S3 product images (Phase 4c)** — unrelated, already a separate phase.
- **In-cluster Redis on AWS** — rejected in favor of the managed service.
- **Multi-node / replica topology** — the app has no Redis read/write split (one
  `spring.data.redis.host`, no reader endpoint), so a replica would be decorative;
  single node is both YAGNI and the honest topology. The `replication_group`
  shape leaves the door open to add one in 4d at near-zero cost.

## Operating constraints

All steps bill AWS (account `583178372344` / profile `microecom` / region
`ap-southeast-1`) — the user runs `make aws-all`; Claude writes the script edit and
runs only the offline gates. Never log secrets. Never commit tfvars / state /
`.terraform` (the `.terraform.lock.hcl` **is** committed). Commit messages end with
the `Co-Authored-By: Claude Opus 4.8` trailer. The cluster bills ~$0.25-0.30/hr —
`make aws-down` between sessions.
