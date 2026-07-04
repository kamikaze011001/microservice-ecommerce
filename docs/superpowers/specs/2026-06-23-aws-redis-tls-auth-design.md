# Phase 4d — Redis TLS + AUTH — Design

**Status:** approved 2026-06-23
**Branch:** `feat/aws-deploy` (continuation of the AWS deployment workstream)
**Predecessor:** Phase 4b (ElastiCache Redis, Option A = no TLS / no AUTH)

## Goal

Turn on ElastiCache **encryption-in-transit** plus a **RedisAUTH token**, and wire
both Redis clients in `core-redis` to use them — without changing local dev, which
stays plaintext / no-auth.

## Background

Phase 4b deployed a single-node `aws_elasticache_replication_group` with
`transit_encryption_enabled = false` and no auth token ("Option A"), for exact
parity with the in-cluster Redis it replaced. AWS couples the two settings:
ElastiCache refuses an `auth_token` unless `transit_encryption_enabled = true`.
So "password but no TLS" is impossible, and enabling either means enabling both —
which also requires a client-side scheme change (`redis://` → `rediss://`). That
client change is why this was deferred to its own phase.

## The one-knob seam

A single standard Spring Boot property, **`spring.data.redis.ssl.enabled`**, drives
every client:

- **Lettuce** (Spring Data `LettuceConnectionFactory`, auto-configured from
  `spring.data.redis.*`) reads it natively → TLS on, zero code.
- **Redisson** (manually configured in `RedisConfiguration`) reads the same flag
  and selects the scheme for its `.setAddress(...)` call.
- **Local dev:** the property is absent → defaults to `false` → `redis://`, and the
  password stays empty. Local config is untouched.

### Why no truststore work is needed

ElastiCache in-transit encryption presents a certificate chain issued by a **public
Amazon CA** already present in the JVM default truststore. `rediss://` therefore
works with the default SSL context — no custom `cacerts`, no Spring `ssl.bundle`,
no Redisson `SslContext`. This is the main thing that looks harder than it is.

## Components & the AI / HUMAN split (coworking-learning)

### HUMAN writes — Terraform (`aws/main/elasticache.tf`)

1. `resource "random_password" "redis_auth"` — `length = 32`, ElastiCache-safe
   charset via `override_special` (printable ASCII; must exclude space, `/`, `"`,
   `@`). ElastiCache `auth_token` must be 16–128 chars.
2. On the existing `aws_elasticache_replication_group.redis`:
   - `transit_encryption_enabled = true` (was `false`)
   - `auth_token = random_password.redis_auth.result`
   - description bumped to reflect Phase 4d (TLS + AUTH)
3. New `output "redis_auth_token"` with `sensitive = true`, value
   `random_password.redis_auth.result`.

Claude scaffolds the PART/TODO markers + interview-prep comments; Claude does **not**
write the HCL bodies.

### CLAUDE writes

1. **`core/core-redis/.../configuration/RedisConfiguration.java`** — in the
   `redissonClient` bean, inject
   `@Value("${spring.data.redis.ssl.enabled:false}") boolean ssl`, compute
   `scheme = ssl ? "rediss://" : "redis://"`, and use it in `.setAddress(scheme + host + ":" + port)`.
   Password logic (the existing non-empty check + `setPassword`) is unchanged. No
   other bean changes — Lettuce needs nothing in code.
2. **`scripts/aws/seed-secrets.sh`** — read the new `redis_auth_token` output into a
   variable, pass it as a jq `--arg`, set `spring.data.redis.password` to the token,
   and add `spring.data.redis.ssl.enabled":"true"` to the AWS `app/ecommerce` secret
   blob. Update the inline "Option A (Phase 4b)" comment to Phase 4d. The local Vault
   seed is not touched.

## Data flow

```
random_password.redis_auth
   ├─ auth_token  ──────────────► ElastiCache replication group (RedisAUTH)
   └─ output redis_auth_token ──► seed-secrets.sh
                                    └─ writes spring.data.redis.password = token
                                       + spring.data.redis.ssl.enabled = true
                                       into Secrets Manager app/ecommerce
                                          └─ ESO syncs to pod env/secret
                                             ├─ Lettuce: TLS via ssl.enabled
                                             └─ Redisson: rediss:// + password
```

## Verification

**Offline gates (Claude, pre-handoff):**
- `mvn -pl core/core-redis -am compile`
- `terraform fmt -check aws/main/elasticache.tf`
- `bash -n scripts/aws/seed-secrets.sh`
- grep cross-checks: scheme selection present, `ssl.enabled` and token wired, the
  output name `redis_auth_token` matches between TF and the script.

**Billed (USER):**
- Rebuild the **cores image + 5 service images** that import `core-redis`
  (authorization-server, order-service, inventory-service, payment-service,
  orchestrator-service), push to ECR, then `make aws-all`.
- Confirm the three readiness-gated services (auth, order, inventory) come up green,
  and that a plaintext (non-TLS / no-AUTH) connection to the cache is refused.

## Out of scope (YAGNI)

- **No read replica / automatic failover** — the cache stays single-node. Adding a
  replica is a separate availability concern, not part of TLS+AUTH.
- **No token rotation automation.** `random_password` regenerates only on
  taint/recreate.
- Phase 5 (domain / DNS / TLS for the ALB) is unaffected and unrelated.

## Known trade-off

Flipping `transit_encryption_enabled` on an existing replication group **forces a
replacement**, wiping the cache. It is a pure cache and the stack is ephemeral, so
this is harmless; on a fresh `make aws-all` the group is created with TLS from the
start.

## Interview-prep talking points

- Why ElastiCache couples `auth_token` with `transit_encryption_enabled` (no
  "password without TLS").
- Why `rediss://` needs no custom truststore (public Amazon CA in the JVM default).
- One standard property (`spring.data.redis.ssl.enabled`) driving two different
  clients (Lettuce auto-config + manual Redisson) — the value of reusing the
  framework's contract instead of a bespoke flag.
- Why enabling transit encryption forces a replacement, and why that's acceptable
  for a cache.
