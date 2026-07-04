# Phase 4d — Redis TLS + AUTH Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable ElastiCache encryption-in-transit + a RedisAUTH token, and wire both Redis clients in `core-redis` to use them, while leaving local dev plaintext/no-auth.

**Architecture:** One standard Spring property (`spring.data.redis.ssl.enabled`) drives both clients — Lettuce auto-config reads it natively, and Redisson reads it to pick `rediss://` vs `redis://`. The token is a `random_password` in Terraform, surfaced as an output and seeded into Secrets Manager by `seed-secrets.sh`. No truststore work (public Amazon CA is in the JVM default).

**Tech Stack:** Terraform (AWS provider, ElastiCache), Java 17 / Spring Boot 3.3.6 / Redisson + Spring Data Lettuce, bash + jq + AWS Secrets Manager (via ESO).

**Coworking-learning split:** Task 1 (`aws/main/elasticache.tf`) is a **HUMAN checkpoint** — Claude scaffolds the markers and reviews, the user writes the HCL bodies. Tasks 2 and 3 are Claude-owned. Tasks 2 and 3 depend only on the *name* of the new output (`redis_auth_token`) and the property name (`spring.data.redis.ssl.enabled`), both fixed by the spec — so they can proceed in parallel with the human's Task 1.

**Offline gates only** (Claude + subagents): `terraform fmt -check`, `mvn -pl core/core-redis -am compile`, `mvn -pl core/core-redis test`, `bash -n`, `grep`. The billed cores + 5-service image rebuilds and `make aws-all` are the **user's**.

---

### Task 1: ElastiCache TLS + AUTH (HUMAN checkpoint)

**Files:**
- Modify: `aws/main/elasticache.tf` (add `random_password`, edit the existing `aws_elasticache_replication_group.redis`, add an output)

The file already contains the Phase 4b bodies. This task adds a token generator, flips two settings on the existing replication group, and exposes the token as an output. **Claude scaffolds the PART markers + interview notes only; the user writes the three HCL bodies.**

- [ ] **Step 1 (CLAUDE): scaffold the Phase 4d markers**

Append this block to the end of `aws/main/elasticache.tf` (after the existing `output "redis_primary_endpoint"`), and edit the inline `transit_encryption_enabled` line's trailing comment context as noted. Do **not** write the HCL bodies — only the guidance comments + TODO markers.

```hcl
# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4d — [HUMAN ✍️]  TLS in transit + RedisAUTH token
#
# Phase 4b shipped Option A (no TLS, no auth) for local parity. AWS couples the
# two: ElastiCache refuses an auth_token unless transit_encryption_enabled = true.
# So this phase flips BOTH and surfaces the token for seed-secrets.sh.
#
# PART 4d-A — the token generator   resource "random_password" "redis_auth"
#   - length           = 32
#   - special          = true
#   - override_special  = "!#$^&*-_=+"   # ElastiCache auth_token forbids space / "/" / '"' / "@"
#   (ElastiCache requires auth_token to be 16–128 printable chars.)
#
# PART 4d-B — edit the EXISTING aws_elasticache_replication_group.redis (above):
#   - transit_encryption_enabled = true                          # was false
#   - auth_token                 = random_password.redis_auth.result   # NEW line
#   - description                = "microecom cache (Phase 4d, single node, TLS+AUTH)"
#   NOTE: flipping transit_encryption_enabled forces a REPLACEMENT of the group.
#   It's a pure cache and the stack is ephemeral, so the wipe is harmless.
#
# PART 4d-C — output the token   output "redis_auth_token"
#   - value     = random_password.redis_auth.result
#   - sensitive = true     # keeps the token out of plan/apply console output
#
# 🎓 Interview prep — be ready to explain:
#   - Why auth_token needs transit_encryption_enabled (no "password without TLS").
#   - Why rediss:// needs no custom truststore (cert chain from a public Amazon CA
#     already in the JVM default truststore).
#   - Why enabling transit encryption forces a replacement, and why that's fine here.
#
# TODO(HUMAN): PART 4d-A — resource "random_password" "redis_auth"
# TODO(HUMAN): PART 4d-B — edit the replication group (transit_encryption_enabled,
#              auth_token, description)
# TODO(HUMAN): PART 4d-C — output "redis_auth_token"
# Write PARTs 4d-A..C, then tell Claude "review".
# ─────────────────────────────────────────────────────────────────────────────
```

- [ ] **Step 2 (HUMAN): write the three HCL bodies**

The user adds `random_password.redis_auth`, edits the replication group's three lines, and adds `output "redis_auth_token"` per the markers. Then says "review".

- [ ] **Step 3 (CLAUDE): review + offline gate**

Run:
```bash
terraform fmt -check aws/main/elasticache.tf
```
Expected: exits 0 (clean) after the human's edits are formatted.

Review checklist:
- `random_password.redis_auth` has `length = 32` and an `override_special` that excludes space, `/`, `"`, `@`.
- The replication group now has `transit_encryption_enabled = true` and `auth_token = random_password.redis_auth.result`.
- `output "redis_auth_token"` exists, value is `random_password.redis_auth.result`, `sensitive = true`.
- No other resource was changed.

- [ ] **Step 4 (CLAUDE): commit**

```bash
git add aws/main/elasticache.tf
git commit -m "feat(aws): ElastiCache TLS in transit + RedisAUTH token (Phase 4d)"
```

---

### Task 2: Redisson scheme toggle in core-redis

**Files:**
- Modify: `core/core-redis/src/main/java/org/aibles/ecommerce/core_redis/configuration/RedisConfiguration.java:34-52`
- Test: `core/core-redis/src/test/java/org/aibles/ecommerce/core_redis/configuration/RedisConfigurationTest.java` (create)

The scheme decision is extracted into a pure static helper so it's unit-testable offline without a live Redis. The bean reads the new `spring.data.redis.ssl.enabled` property (default `false`) and delegates to the helper.

- [ ] **Step 1: Write the failing test**

Create `core/core-redis/src/test/java/org/aibles/ecommerce/core_redis/configuration/RedisConfigurationTest.java`:

```java
package org.aibles.ecommerce.core_redis.configuration;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class RedisConfigurationTest {

    @Test
    void buildAddress_usesPlaintextScheme_whenSslDisabled() {
        assertThat(RedisConfiguration.buildAddress(false, "cache.example.com", 6379))
                .isEqualTo("redis://cache.example.com:6379");
    }

    @Test
    void buildAddress_usesTlsScheme_whenSslEnabled() {
        assertThat(RedisConfiguration.buildAddress(true, "cache.example.com", 6379))
                .isEqualTo("rediss://cache.example.com:6379");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
mvn -q -pl core/core-redis test -Dtest=RedisConfigurationTest
```
Expected: FAIL — compilation error, `buildAddress` does not exist on `RedisConfiguration`.

- [ ] **Step 3: Implement the helper + wire the bean**

In `RedisConfiguration.java`, change the `redissonClient` bean to accept the SSL flag and call the helper, and add the static helper. The full replacement for the bean method (lines 34-52) plus the new method:

```java
    @Bean
    public RedissonClient redissonClient(
            @Value("${spring.data.redis.host:localhost}") String host,
            @Value("${spring.data.redis.port:6379}") int port,
            @Value("${spring.data.redis.password:}") String password,
            @Value("${spring.data.redis.ssl.enabled:false}") boolean sslEnabled
    ) {
        Config config = new Config();

        SingleServerConfig serverConfig = config.useSingleServer()
                .setAddress(buildAddress(sslEnabled, host, port))
                .setConnectionMinimumIdleSize(1)
                .setConnectionPoolSize(10);

        if (password != null && !password.isEmpty()) {
            serverConfig.setPassword(password);
        }

        return Redisson.create(config);
    }

    static String buildAddress(boolean sslEnabled, String host, int port) {
        String scheme = sslEnabled ? "rediss://" : "redis://";
        return scheme + host + ":" + port;
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
mvn -q -pl core/core-redis test -Dtest=RedisConfigurationTest
```
Expected: PASS (2 tests green).

- [ ] **Step 5: Verify the module still compiles**

Run:
```bash
mvn -q -pl core/core-redis -am compile
```
Expected: BUILD SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add core/core-redis/src/main/java/org/aibles/ecommerce/core_redis/configuration/RedisConfiguration.java \
        core/core-redis/src/test/java/org/aibles/ecommerce/core_redis/configuration/RedisConfigurationTest.java
git commit -m "feat(core-redis): pick rediss:// scheme when spring.data.redis.ssl.enabled"
```

---

### Task 3: seed-secrets.sh — token + ssl.enabled in the AWS secret

**Files:**
- Modify: `scripts/aws/seed-secrets.sh` (read the new output near line 44; edit the jq `--arg` on line 80; edit the redis properties on lines 90-91)

Reads the `redis_auth_token` Terraform output and writes it (plus `ssl.enabled=true`) into the `app/ecommerce` Secrets Manager blob. The local Vault seed is untouched.

- [ ] **Step 1: Read the token output**

After the existing `REDIS_HOST="$(tf_out redis_primary_endpoint)"` line (currently line 44), add:

```bash
REDIS_AUTH="$(tf_out redis_auth_token)"
```

- [ ] **Step 2: Thread the token into the jq invocation**

On the `jq -n` line that builds the `ecommerce` blob (currently line 80), append a `--arg` for the token. The line becomes:

```bash
  --arg dpw "$DB_PASS" --arg mhost "$RDS_PRIMARY" --arg rhost "$RDS_REPLICA" --arg redishost "$REDIS_HOST" --arg redispw "$REDIS_AUTH" '{
```

- [ ] **Step 3: Set the password + enable TLS in the redis properties**

Replace the current Phase 4b redis lines (lines 90-91):

```jq
  "spring.data.redis.host":$redishost,"spring.data.redis.port":"6379",
  "spring.data.redis.password":"","spring.data.redis.database":"0", # Option A (Phase 4b): no Redis AUTH — transit_encryption_enabled=false, see elasticache.tf
```

with:

```jq
  "spring.data.redis.host":$redishost,"spring.data.redis.port":"6379",
  "spring.data.redis.password":$redispw,"spring.data.redis.database":"0",
  "spring.data.redis.ssl.enabled":"true", # Phase 4d: TLS in transit + RedisAUTH — token from elasticache.tf random_password
```

- [ ] **Step 4: Syntax-check the script**

Run:
```bash
bash -n scripts/aws/seed-secrets.sh
```
Expected: no output, exit 0.

- [ ] **Step 5: Grep-verify the wiring**

Run:
```bash
grep -n 'redis_auth_token\|redispw\|spring.data.redis.password\|spring.data.redis.ssl.enabled' scripts/aws/seed-secrets.sh
```
Expected: shows `REDIS_AUTH="$(tf_out redis_auth_token)"`, the `--arg redispw`, `"spring.data.redis.password":$redispw`, and `"spring.data.redis.ssl.enabled":"true"`. Confirm the output name `redis_auth_token` matches Task 1's output exactly.

- [ ] **Step 6: Commit**

```bash
git add scripts/aws/seed-secrets.sh
git commit -m "feat(aws): seed Redis AUTH token + ssl.enabled into the AWS secret (Phase 4d)"
```

---

## Post-implementation (USER — billed, not part of subagent execution)

1. Rebuild the **cores image** (core-redis changed) and the **5 services** that import it — authorization-server, order-service, inventory-service, payment-service, orchestrator-service — and push to ECR. Per the cores-rebuild gotcha, build cores first (the service builds use `SKIP_CORES=1`).
2. `make aws-all`.
3. Verify: the three readiness-gated services (auth, order, inventory) come up green; a plaintext / no-AUTH connection to the cache is now refused.

## Notes for the executor

- **Do not** run `terraform apply/plan/validate/init`, `aws`, `kubectl` against a cluster, `helm`, or `make aws-*` — they bill the real account. Offline gates only.
- Tasks 2 and 3 are independent of the human's Task 1 (they rely only on the fixed output/property names) and of each other — either order is fine.
- Local dev is intentionally untouched: `spring.data.redis.ssl.enabled` is absent locally → defaults to `false` → `redis://`, empty password.
