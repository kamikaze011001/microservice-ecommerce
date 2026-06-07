# Performance Tuning Report — Payment-Saga Load Test

**Date:** 2026-06-07 · **SUT:** in-cluster e-commerce platform (kind) · **Tool:** k6, 50 VUs / 3-min hold
**Companions:** [`load-test-model-and-capacity.md`](load-test-model-and-capacity.md), [`performance-test-guide.md`](performance-test-guide.md), [`stress-test-monitoring.md`](stress-test-monitoring.md).

## Executive summary

A first load test of the payment saga failed hard: **89% of requests failed, login p95 49s, 1.7 sagas/s.** Iterating run-by-run, each fix removed one bottleneck and exposed the next. After five changes the same test runs **0% errors, 100% checks, login p95 1.7s (p50 247ms), 21.5 sagas/s** — roughly a **13× throughput gain and a ~30× login-latency improvement**, with the auth and order tiers now autoscaling safely. One SLO (login p95 < 800ms) remains, with a known, cheap remedy.

## Method

Classic bottleneck-chasing loop, evidence-first:
1. Run the fixed 50-VU SLO test.
2. Read the failure signature (k6 thresholds + per-step latency), then trace it to the failing component (pod logs, DB state, JWKS) — **no fixes before root cause**.
3. Apply **one** change.
4. Re-measure. The load moves to the next bottleneck; repeat.

## Results progression

| Run | Change before this run | http_req_failed | checks | login p95 | throughput | Bottleneck it exposed |
|---|---|---|---|---|---|---|
| **A** baseline | as-found | 89% | 10% | 49s | 1.68/s | login collapsing |
| **B** | Atomikos pool 1→20 | 48% | ~52% | 4.0s | 12.4/s | order creation (stock) |
| **C** | ADMIN role + seed guard + dump fix | **0%** | **100%** | 3.78s | 13.2/s | login latency |
| **D** | auth CPU↑ + HPA | *aborted* | — | — | — | JWT key per-pod (401) |
| **E** | externalize JWT key (+ keep HPA) | **0%** | **100%** | **1.7s** (p50 247ms) | **21.5/s** | bcrypt login CPU (p95 tail) |

*Pre-load-test memory/stability hardening (k9s-surfaced, not in the table):* kafka-connect memory 1Gi→2Gi (was OOMKilled ×16), and `MALLOC_ARENA_MAX=2` on all 9 JVM services (RSS −23–39%, glibc arena bloat).

---

## Fix deep-dives

### 1. Atomikos connection pool: default `maxPoolSize=1`
- **Symptom (run A):** 98% of logins failed; login p50 = **30.01s**.
- **Root cause:** `core-routing-db` built `AtomikosDataSourceBean`s but never called `setMaxPoolSize`, so each master/slave datasource used the Atomikos default of **1** connection. 50 concurrent logins → 49 wait the default 30s `borrowConnectionTimeout` (hence the exact 30.01s median) → `AtomikosSQLException: Connection pool exhausted`. MySQL itself was idle (peak 37/151 connections) — the cap was purely app-side.
- **Fix:** `setMinPoolSize(5)` / `setMaxPoolSize(20)` on all three datasources (worst-case ~120 master conns < 151).
- **Result:** login p95 49s→4s, failures 89%→48%, throughput 1.68→12.4/s. **Load moved to order creation.**

### 2. Empty `role` table → admin can't top up stock
- **Symptom (run B):** login now fine, but `order 201` failed ~half the time with `InvalidProductQuantity`; stock drained to 0/−1.
- **Root cause (two silent skips):** the k6 `setup()` tops up stock via an admin-only PATCH, but it 403'd ("no roles") — `perftest_admin` had no role because the **`role` table was empty**. Why empty: `01-mysql-seed` loads the data-only `ecommerce.sql` (which seeds roles) but its idempotency guard was *"skip if any table exists"* — and the JPA apps create the tables (Hibernate `ddl-auto`) **before** the seed runs by design, so the guard always tripped and the seed **never ran**. The `setup()` PATCH was also unchecked, so the 403 was invisible and the catalog silently depleted.
- **Fix:** (a) guard on **data** (`SELECT COUNT(*) FROM account`) not table existence; (b) **column-name** `ecommerce.sql`'s INSERTs (the positional `account` dump no longer matched the Hibernate column order and would have failed the load — validated against a schema-mirror); (c) `06-perftest-seed` now ensures the ADMIN role itself; (d) k6 `setup()` now **throws** on a non-2xx top-up (fail loud).
- **Result:** failures 48%→**0%**, checks→**100%**, 13.2/s, stock stays full. **Load moved to login latency.**

### 3. JWT signing key generated per-pod → can't restart or scale auth
- **Symptom (run D):** after raising auth CPU + adding an HPA, the run **aborted** — `setup()` got `401 invalid_token` on a freshly issued token.
- **Root cause:** `AuthorizationServerConfiguration` generated a **new RSA keypair on every startup** (`RSAKeyGenerator`) under a *constant* `kid`. The gateway caches JWKS by `kid`, so after any auth restart it kept validating against the old key → all tokens 401. Worse, with the new HPA, each replica signed with a *different* key under the same `kid` → the gateway validated only one replica's tokens. **The auth tier could not be restarted or scaled.** (The loud-check from fix #2 is what surfaced this instead of hiding it.)
- **Fix:** load a **stable RSA key from Vault** (`application.jwk`, seeded in docker + k8s), shared across restarts and replicas.
- **Result:** auth boots from the shared key; **0 token errors** with auth scaled to **3 replicas**; this also un-broke the live cluster's auth.

### 4. Auth CPU + HPA (bcrypt parallelism)
- **Symptom (run C):** login succeeded but p95 = 3.78s — bcrypt (cost 10, ~80ms CPU/hash) bottlenecked on auth's **1-core** limit under 50 concurrent logins.
- **Fix:** CPU request 100m→250m, limit 1→2 cores; HPA 1→3 @ 60% CPU. (Safe only *after* fix #3.)
- **Result (run E):** login p95 3.78s→**1.7s**, p50 **247ms**; throughput 13.2→**21.5/s** (login no longer gates the saga).

### Supporting memory tuning (earlier this session)
- **kafka-connect** OOMKilled ×16 (exit 137) at a 1Gi limit (RSS peak 963Mi) → raised to 2Gi (now ~52% of limit).
- **`MALLOC_ARENA_MAX=2`** on all JVM services: container RSS was ~2× the JVM's committed memory due to glibc spawning `8×CPU` malloc arenas; capping arenas cut RSS 23–39% with no heap/limit change (order-service 715→441Mi).

---

## Remaining work & recommendations

| Item | Recommendation | Cost |
|---|---|---|
| **login p95 1.7s > 800ms SLO** | auth `minReplicas: 2` (kill HPA scale-up lag) and/or bcrypt cost 10→8 | 1 line / small |
| **Oversell race** | stock decremented to **−1** under load — no atomic check-and-decrement; add a row lock / conditional update | small-medium |
| **Test realism** | one-off run through the ingress + against real PayPal to get an end-to-end latency picture | medium |
| **Auth key in prod** | the committed JWK is a **dev** key; prod must supply its own via real Vault | config |

## Narrative / talking points

- *"The first run failed at 89% — and the win was resisting the urge to 'add memory.' Each failure had a specific root cause I proved before touching anything: a 30-second median login pointed straight at a connection-pool `borrowConnectionTimeout`; a positional SQL dump that never matched the live schema; a JWT key regenerated per pod."*
- *"The most valuable bug was found by load testing, not code review: the auth tier literally couldn't be scaled or restarted because the signing key lived in each pod's memory. The load test's own admin-setup is what exposed it."*
- *"Net: ~13× throughput, ~30× login-latency, 89%→0% errors, and two tiers that now autoscale — by removing bottlenecks one at a time, not by throwing hardware at it."*
