# Load-Test Model & SUT Capacity

**What the k6 load test actually exercises, how it differs from real production, and what the system under test (SUT) can currently bear.**

Companions: [`performance-test-guide.md`](performance-test-guide.md) (how to run it), [`stress-test-monitoring.md`](stress-test-monitoring.md) (where to watch it), [`performance-tuning-report.md`](performance-tuning-report.md) (how we got the numbers below).

---

## 1. The load model (current settings)

Source: `k8s/apps/base/k6-stress/payment-flow.js` + `payment-job.yaml`. Run with `make k8s-payment-stress`.

| Setting | Value |
|---|---|
| Virtual Users (VUs) | ramp 0→50 over 1m, **hold 50 for 3m**, ramp 50→0 over 30s (~4.5m total) |
| Per-VU loop | login → create order → create payment → PayPal decision → callback, then `sleep(1s)` |
| Decision mix | 90% approve / 5% cancel / 5% fail (exercises saga success **and** compensation) |
| Users | 100 seeded `perftest_user_N` + 1 `perftest_admin` |
| Where it runs | **in-cluster** Job; hits the gateway via Service DNS (`gateway.apps.svc.cluster.local:6868`) — **skips the ingress/TLS** so latency reflects the backend, not the proxy |
| Metrics sink | remote-write → VictoriaMetrics → Grafana dashboard #19665 |

**SLO thresholds** (a breach fails the run): `http_req_failed < 5%`, `checks > 95%`, `create_payment p95 < 2000ms`, `login p95 < 800ms`.

A VU is a *concurrent shopper*, not a request rate. Throughput is the **result** k6 reports (`iterations/s`, `http_reqs/s`), not an input.

## 2. How this differs from real production

These numbers are a **relative floor for regression-tracking on a laptop**, not an absolute production SLA. Key differences:

| Dimension | This test | Real production |
|---|---|---|
| PayPal | `mock-paypal-service` in-cluster (sub-ms) | real PayPal REST over the internet (100s of ms, variable) |
| Network | pod→pod inside one kind node | client→CDN→LB→gateway over the internet (RTT, TLS handshakes) |
| Ingress/TLS | **bypassed** (Service DNS) | every request through ingress-nginx + TLS termination |
| Host | one kind cluster on a laptop; **all pods share the host's CPU** | dedicated nodes, isolated resources, multi-AZ |
| Users | 100 fixed accounts, uniform `sleep(1s)` | millions of users, bursty/heavy-tailed think-time, varied catalogs |
| Data | 3 hot products (topped to 1M in setup) | large catalog, realistic contention hotspots |
| Topology | single replica of MySQL primary / Mongo / Kafka; single region | replicated, sharded, multi-region, with failover |
| Caching | no CDN, cold caches | CDN + warm caches absorb a large fraction of reads |

**Implication:** the test is excellent for *finding bottlenecks and tracking regressions* (which it did — see the tuning report), but the absolute TPS/latency would change materially on real infra. Treat the figures below as "this code+config on this host," comparable run-to-run.

## 3. Measured capacity (current best — run E)

Sustained 50 VUs for the SLO window, after all tuning:

| Metric | Value |
|---|---|
| **TPS** (completed payment sagas) | **≈ 21.5 / s** (5,843 iterations) |
| **RPS** (HTTP requests) | **≈ 108 / s** (29,220 requests; ~5 requests per saga) |
| **Error rate** (`http_req_failed`) | **0.00%** (0 / 29,220) |
| **Functional checks** | **100%** (29,215 / 29,215) |
| login latency | p50 **247ms**, p90 1.53s, **p95 1.70s**, max 2.5s |
| create_payment latency | p50 32ms, **p95 251ms**, max 924ms |
| Autoscaling | order-service and authorization-server scaled to **3 replicas** under load |

**SLO status:** all green **except `login p95` (1.70s vs 800ms target)** — see the ceiling below.

### The current ceiling: bcrypt login CPU
Login verifies a password with **bcrypt (cost 10 ≈ 60–100ms of CPU per attempt)**. That is the heaviest single-request CPU cost in the system and the bottleneck at higher load. The p50 (247ms) is healthy; the p95 tail (1.7s) is dominated by **HPA scale-up lag** — auth starts at 1 replica and the first ~minute of the ramp queues before it scales to 3. Everything else (DB, payment, saga) has ample headroom (create_payment p95 251ms).

## 4. Scaling levers (to push capacity higher)

- **Login p95 under 800ms:** set authorization-server `minReplicas: 2` (remove scale-up lag) and/or lower bcrypt cost 10→8 (4× less CPU/hash, a security trade-off). Both are cheap.
- **Higher TPS:** raise the VU hold target; order-service/auth will scale (HPA max 3 — raise if the host has cores). MySQL primary is the next likely contention point (single writer).
- **Realistic ceiling test:** point at real PayPal + through the ingress to measure end-to-end latency, and seed a large catalog to surface real lock contention.
- **Known correctness item:** stock decrement isn't atomic (observed oversell to −1 under load) — fix before trusting inventory numbers at scale.

---

## Narrative / talking points

- *"The test drives the full distributed payment saga — login → order → payment → PayPal → async settle — at 50 concurrent users, and verifies a fixed SLO."*
- *"It deliberately runs in-cluster and mocks PayPal so the numbers isolate **our** backend, not the internet or the payment provider — which is what makes it useful for regression tracking."*
- *"Current sustained capacity on a single dev host: ~21.5 payment sagas/s, ~108 req/s, 0% errors, p50 login 247ms. The remaining bottleneck is bcrypt CPU on the auth tier, which now autoscales."*
- *"These are relative numbers — a floor on a laptop — not a production SLA; prod would be dominated by real-PayPal and internet latency."*

## Production-shaped funnel model (storefront-flow.js)

Alongside the pure-saga regression test (`payment-flow.js`, every VU pays), a
production-shaped **conversion funnel** lives in
`k8s/apps/base/k6-stress/storefront-flow.js`. Most sessions only browse; a
checkout-heavy minority pay. One script, three profiles via the `PROFILE` env.

### Per-session funnel (cumulative reach)

| Step | Endpoint | Auth | Reach | Think-time after |
|---|---|---|---|---|
| Browse page | `GET /product-service/v1/products?page&size=12` | anon | 100% | 1–4s |
| Product detail | `GET /product-service/v1/products/{id}` | anon | 60% | 2–6s |
| Login | `POST /authorization-server/v1/auth:login` | — | 40% | — |
| Add to cart | `POST /order-service/v1/shopping-carts:add-item` | Bearer | 40% | 1–3s |
| Create order | `POST /order-service/v1/orders` | Bearer | 25% | 1–2s |
| Create payment | `POST /payment-service/v1/payments?orderId` | Bearer | 20% | — |
| Approve/cancel/fail | mock-paypal 302 chain (90/5/5) | — | 20% | — |

Reach is realized via sequential conditional gates (continue probs
0.60 / 0.667 / 0.625 / 0.80). Login fires only for sessions that will add to
cart, so anonymous browsing costs no bcrypt — this is what lets the funnel
sustain more concurrent sessions than the all-pay loop.

### Profiles

| Profile | Executor | Shape | Purpose |
|---|---|---|---|
| `smoke` | `ramping-vus` | 0→50/1m, hold 50/3m, →0/30s | fast regression gate (parity with payment-flow) |
| `soak` | `constant-vus` | 30 VU for 30m (`SOAK_VUS`,`SOAK_DURATION`) | leak/drift detection |
| `stress` | `ramping-arrival-rate` | open model 10→120/s over 15m, maxVUs 150 | discover the ceiling, validate HPA |

Stress compresses think-time by 10× (`THINK_SCALE=0.1`) so the open-model
arrival rate loads the SUT instead of pinning VUs. All numeric knobs are
env-overridable (`STRESS_START_RATE`, `STRESS_PEAK_RATE`, `STRESS_DURATION`,
`STRESS_MAX_VUS`, …). Same in-cluster envelope as payment-flow (gateway Service
DNS, mock PayPal, ingress/TLS bypassed) — figures are "this code+config on this
host," not an absolute production SLA. Full suite stays under 1h.

### Latest smoke baseline

- **2026-06-09 smoke:** checks 100.00% (6008/6008), http_req_failed 0.00% (0/6013),
  1880 iterations / 0 interrupted, all funnel tags present; login p95 81ms,
  create_payment p95 31ms.
