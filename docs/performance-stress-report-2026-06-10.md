# Stress-Run Report — Storefront Flow at 150 VUs

**Date:** 2026-06-10 (test window 09:56:35–10:11:37 UTC) · **SUT:** in-cluster e-commerce platform (kind, 3 workers) · **Tool:** k6 `storefront` scenario, 15-min ramp to 150 VUs / 120 iters/s
**Companions:** [`performance-tuning-report.md`](performance-tuning-report.md) (2026-06-07 baseline tuning), [`load-test-model-and-capacity.md`](load-test-model-and-capacity.md), [`stress-test-monitoring.md`](stress-test-monitoring.md).

## Executive summary

The platform sustained **211 req/s with 99.75% checks passing and an overall p95 of 149ms** — all fixes from the 2026-06-07 tuning round held (no pool exhaustion, no oversell, no OOM, zero pod restarts). However, the final third of the ramp (gateway > ~230 req/s) exposed **two new load-threshold bugs and one systemic limit**, all of which fired together in the last ~4 minutes:

1. **Cart upsert race → persistent data corruption** — `NonUniqueResultException` ×269; duplicate cart rows are *still in the table* and will 500 those user/product pairs at any load.
2. **Payment JTA transaction cap** — Atomikos default `maxActives=50` saturated because ~1.3s PayPal HTTP calls are held inside `@Transactional`; `IllegalStateException` ×108.
3. **MySQL replication lag 0 → 15s at peak write load** — the amplifier behind bug 1 and a standing threat to every read-after-write path on the slaves.

Nothing failed before minute ~10. These are capacity-edge defects, not regressions.

## Test shape & headline results

| Metric | Value |
|---|---|
| Iterations / HTTP requests | 58,298 / 190,279 (211 req/s avg) |
| Checks | 99.75% (189,887 / 190,349) |
| `http_req_failed` | 0.20% (387) |
| Latency | med 11.9ms · p90 90ms · p95 149ms · max 3.06s |
| Dropped iterations | 202 (k6 protecting arrival rate as latency rose — symptom of bugs 1–2) |
| Failed checks | cart ×279 · payment ×75 · has-links ×75 · flow-settled ×33 |

**Per-service latency & traffic (15-min window):**

| Service | avg rps | p95 | p99 |
|---|---|---|---|
| cloud-gateway | 229.4 | 150ms | 761ms |
| product-service | 159.2 | **8.2ms** | 27ms |
| order-service | 60.0 | 157ms | 308ms |
| authorization-server | 27.4 | 194ms | 321ms |
| payment-service | 27.3 | **957ms** | **1.63s** |
| inventory-service (gRPC-backed reads) | — | 27.5ms | 28ms |

**Timeline (the load-threshold pattern):** gateway ramped 45 → 338 req/s; payment p95 degraded 30ms → 430ms → **1.25s**; replica lag was **0 for the first ~12 minutes**, then climbed to 13–15s; all 500s landed in the final ~4 minutes. The system has a hard knee at ≈230 req/s gateway throughput.

## What held up (verified wins)

- **Previous fixes all confirmed under 3× the previous load:** no `Connection pool exhausted` (Atomikos min5/max20), no `InvalidProductQuantity`/stock depletion, no negative stock (Redis atomic counter, PR #18), no JWT/key errors, no OOM (`MALLOC_ARENA_MAX=2`).
- **JVM health excellent across all 9 services:** heap peak 37% (authorization-server), worst single GC pause 49ms, worst total GC 5.1s/15min (gateway, 0.6% of wall time), zero restarts, no CPU throttling on any app pod.
- **Read path is very strong:** product browse p95 **8.2ms at 159 rps**; read/write split works (replicas served ~1,300 QPS combined vs 810 on primary).
- **Kafka is nowhere near limits:** max consumer lag 78 messages (mongo-event-group), drained immediately.

---

## Problem deep-dives

### P1 — Cart upsert race: duplicate rows + `NonUniqueResultException` (269 × 500) — **CORRECTNESS, data still corrupted**

- **Symptom:** `POST /v1/shopping-carts:add-item` → HTTP 500, `org.hibernate.NonUniqueResultException: Query did not return a unique result: 2 results were returned`. Started only when replica lag appeared (final 4 minutes), ~0.7 errors/s sustained.
- **Root cause (three layers, code: `order-service/.../ShoppingCartServiceImpl.java:38-58`):**
  1. **Check-then-act race:** `addItem()` reads the item via `slaveShoppingCartItemRepo.findByShoppingCartIdAndProductId(...)`, then inserts via master repo if absent. Two concurrent requests both see "absent" and both insert. Unsafe even with zero lag.
  2. **Replica-lag amplifier:** the check reads a **replica** that was **13–15s behind** the primary at peak. For 15s after the first insert, every re-add for the same user+product sees "no row" and inserts another duplicate. The race window grew from milliseconds to seconds. (This is the read-after-write hazard predicted when real replication was introduced.)
  3. **No safety net:** `shopping_cart_item` has **no unique constraint** on `(shopping_cart_id, product_id)`, so the primary accepted the duplicates.
- **Lasting damage:** the duplicate rows **persist after the test**. Every future `add-item` (and any single-result cart query) for the affected pairs returns 500 at *any* load until the table is deduplicated.
- **Fix direction:** (a) one-off dedup migration (merge quantities); (b) `ALTER TABLE ... ADD UNIQUE KEY uq_cart_product (shopping_cart_id, product_id)`; (c) replace check-then-insert with a single atomic `INSERT ... ON DUPLICATE KEY UPDATE quantity = quantity + VALUES(quantity)` on the primary — the slave lookup leaves the write path entirely (the quantity-merge contract is preserved, enforced by SQL instead of Java). Same treatment for the `existsById` cart-header check at line 38.

### P2 — Payment JTA saturation: `Max number of active transactions reached:50` (108 × 500) — **SCALABILITY ceiling**

- **Symptom:** `POST /v1/payments` (75×), `paypal:success` (32×), `paypal:cancel` (1×) → HTTP 500 `IllegalStateException: Max number of active transactions reached:50`, concentrated in the last minutes. Payment p95 degraded smoothly 30ms → 1.25s before tipping into errors (textbook congestion collapse).
- **Root cause:** external **HTTP calls held inside JTA transactions**:
  - `PaymentServiceImpl.purchase()` is `@Transactional` and calls `paypalService.createOrder(...)` (HTTP) inside the transaction.
  - `handleSuccessPayment()` is `@Transactional` and makes **two** sequential HTTP calls (`captureOrder` + `getOrderDetails`).
  - `JTATransactionConfig` (core-routing-db) builds `UserTransactionManager` with **all defaults** → Atomikos `maxActives = 50` per JVM.
  - Capacity math: throughput ceiling = slots ÷ hold-time. At peak the mock-PayPal calls took ~1.3s → 50 ÷ 1.3s ≈ **38 tx/s ceiling**, vs 27 req/s demand + burst variance → saturation. Early in the run (100ms calls) the same 50 slots gave ~500 tx/s, which is why it only broke at peak.
- **Note:** raising `maxActives` only moves the knee. The defect is that PayPal's response time controls how long scarce local resources (tx slot + DB connections) are held. The transaction also never actually protected the external call — a rollback after a successful PayPal call cannot un-call PayPal.
- **Fix direction:** restructure to **call-then-record**: do the PayPal HTTP call outside any transaction, then persist the result in a short `@Transactional` method (~10ms hold → ~5,000 tx/s ceiling on the same 50 slots). Caution: the transactional method must live in a **separate bean** (Spring proxy self-invocation skips `@Transactional`; services here are manually wired in `@Configuration`, so this means a new `@Bean` + constructor updates). Define the crash-between recovery story (PayPal order with no local row → reconcile by token via capture/IPN path). Optionally also raise `com.atomikos.icatch.max_actives` as a stopgap.
- **Side effect worth knowing:** the 1.3s payment tail also inflated the **gateway's** GC profile (see Watch items) — slow downstreams promote in-flight request state to old gen.

### P3 — MySQL replication lag: 0 → 15s under peak writes — **SYSTEMIC limit**

- **Symptom:** `mysql_slave_status_seconds_behind_master` flat at 0 until minute ~12, then 6→8→10→**15s** on both replicas through test end.
- **Why it matters beyond P1:** every slave-side read of recently written data is exposed (e.g. the deliberately deferred inventory `existsById`-on-slave). At 15s of lag, "read your own write" fails for any flow faster than 15 seconds — which is all of them.
- **Also observed — replica imbalance:** replica-0 served 515 QPS vs replica-1's 794 (primary 810). The slave load-balancing is uneven; worth checking the routing datasource's selection strategy.
- **Fix direction:** investigate MySQL parallel replication (`replica_parallel_workers`, currently likely 1) and the write burst profile at peak (order/cart/payment all writing); re-test. Treat lag as a first-class dashboard alert (it's the early-warning signal for P1-class bugs).

---

## Watch items (not failures yet)

| Item | Evidence | Risk / action |
|---|---|---|
| **MySQL primary connections** | peaked **115/151 (76%)** | next capacity wall; raise `max_connections` or trim pools before pushing load higher |
| **MongoDB CPU throttling** | mongodb-0 throttled ~12% of periods; 33 `flow settled` k6 failures all at peak | Mongo is on the saga-critical CDC path (order → Debezium → orchestrator); raise its CPU limit and re-check saga settle latency |
| **Gateway GC profile** | 105.7 MB/s allocation (~460KB/request), young GC every ~0.5s, promotion 245 KB/s (highest) | **healthy today** (old-gen peak 18.5%, max pause 35ms, GC 0.6% of wall time). Mostly a *symptom* of the payment latency tail — requests outliving GC cycles get promoted. Fixing P2 improves this for free; a larger gateway heap (576MB→1GB) is the optional knob |
| **k6 dropped iterations** | 202 | consequence of P1/P2 latency, not a separate defect |

## Recommended priority

| # | Problem | Type | Why this order | Est. cost |
|---|---|---|---|---|
| 1 | **P1 cart dedup + unique key + atomic upsert** | correctness (corruption persists right now) | bad rows break prod-like flows at any load; cleanup needed regardless | migration + 1 repo query |
| 2 | **P2 payment call-then-record split** | scalability + latency | removes the 38 tx/s ceiling *and* the p95 tail *and* cleans the gateway GC profile | service split + bean wiring |
| 3 | **P3 replication tuning + lag alert** | systemic | protects every current and future slave-read path | config + dashboard |
| 4 | Watch items (Mongo CPU, primary conns, replica balance) | capacity headroom | cheap insurance before the next, bigger run | config |

After 1–3, re-run the same 15-min/150-VU profile and push the ramp until the *next* knee appears.

---

## Fixes applied + re-run results (2026-06-10, second run 13:10–13:25 UTC)

All three problems were fixed on branch `fix/stress-20260610-cart-payment-replication` and verified with an identical 15-min/150-VU re-run. Plan: `docs/superpowers/plans/2026-06-10-stress-fixes-cart-payment-replication.md`.

**What changed:**

| Problem | Fix |
|---|---|
| P1 cart race | Dedup migration (`V2__shopping_cart_item_dedup_unique.sql`, quantities summed into keeper row) + unique key `uq_cart_product (shopping_cart_id, product_id)` + atomic `INSERT ... ON DUPLICATE KEY UPDATE` on the master (`MasterShoppingCartItemRepo.upsertItem`); slave read removed from the write path; `SlaveShoppingCartItemRepo` deleted |
| P2 payment JTA cap | Call-then-record: PayPal HTTP leaves the transaction entirely; DB writes + CDC events moved to a new `PaymentRecorder` bean with short `@Transactional` methods; guarded by a reflection test (`TransactionBoundaryTest`). Plus PayPal RestTemplate timeouts (3s connect / 10s read, timeouts now recorded as `PaymentFailed`) and Atomikos `max_actives` 50→200 as headroom |
| P3 replication lag | Primary: `binlog-transaction-dependency-tracking=WRITESET` + XXHASH64 + group-commit batching, `max_connections` 151→300. Replicas: `replica-parallel-workers` 4→8. Mongo CPU limit 800m→1500m (saga CDC path) |

**Re-run vs baseline:**

| Metric | Baseline | Re-run | Target |
|---|---|---|---|
| Checks passing | 99.75% (462 failed) | **100.00%** (190,457/190,457) | 100% ✅ |
| `http_req_failed` | 0.20% (387) | **0.00% (0)** | — ✅ |
| `cart 200` failures | 279 (`NonUniqueResultException`) | **0** (0 exceptions, both pods) | 0 ✅ |
| `payment 200` / `has links` failures | 75 / 75 (`maxActives=50` saturation) | **0 / 0** (0 max-actives errors) | 0 ✅ |
| `flow settled` failures | 33 | **0** | 0 ✅ |
| Payment p95 at peak | 957ms | **152ms** (`create_payment`, k6) | <500ms ✅ |
| Replica lag (max over run) | 15s | **1s** | ≤2s ✅ |
| Overall p95 / max | 149ms / 3.06s | **96ms / 2.11s** | — |
| Dropped iterations | 202 | 92 | — |

Functional smokes also passed before the run: cart double-add merged into one line (quantity summed, third add no 500); one full order→pay→approve round via mock-paypal settled the order at `COMPLETED` with the success event published from `PaymentRecorder`.

The only ERROR lines in payment-service during the run were two deliberate `decision=fail` k6 flows (mock-paypal 422 on capture → `PaymentFailed` path) — expected business outcomes, handled correctly.

**Still open (carried forward):** replica round-robin imbalance, no lag alerting (panel exists, no alert stack), gateway GC re-check at the next, higher knee. The system now passes cleanly at 211 req/s — the next stress run should push the ramp until a new knee appears.
