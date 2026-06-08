# Production-Shaped Performance Test — Design Spec

**Status:** SPEC ONLY — implement fresh via `writing-plans` → `subagent-driven-development`.
**Date:** 2026-06-08
**Scope:** add a realistic, production-shaped load test alongside the existing pure-saga regression test — a conversion-funnel traffic model run under three profiles (smoke, soak, stress) on the in-cluster kind setup.

---

## 1. Problem

The current load test (`k8s/apps/base/k6-stress/payment-flow.js`, `make k8s-payment-stress`) is excellent for **regression tracking** but not representative of production traffic in two ways:

1. **Too short.** It holds 50 VUs for **3 minutes** (~4.5m total). That window cannot surface time-dependent failures — memory leaks, GC drift, connection/thread-pool leaks, DB/disk growth, replication-lag creep under sustained load.
2. **Unrealistic traffic shape.** Every VU runs the same loop: `login → create order → create payment → approve`. In production the vast majority of sessions only **browse**; a small fraction log in, fewer add to cart, fewer still pay. The current test exercises none of the storefront read path and over-weights login (bcrypt) and the saga.

The test also runs **in-cluster** (gateway Service DNS, mock PayPal, ingress/TLS bypassed) on a **laptop kind cluster** that saturates near 50 all-pay VUs. This spec **keeps** that environment — environment realism (real ingress/TLS, real PayPal) is explicitly out of scope (decided during brainstorming). The figures remain "this code+config on this host," comparable run-to-run, not an absolute production SLA.

## 2. Goal

A new self-contained k6 script modelling a realistic conversion **funnel** (checkout-heavy / flash-sale shape), runnable under three **profiles**:

- **smoke** — 50 VU / 3 min, parity with today (fast regression gate).
- **soak** — moderate steady load for **30 min** (leak/drift detection).
- **stress** — open-model arrival-rate ramp to the breaking point (~up to 150 VU, ~15 min) to discover the ceiling and validate autoscaling.

Total wall-clock for the full suite stays **under 1 hour** (laptop-safe). The existing `payment-flow.js` stays untouched as the pure-saga regression baseline so new-vs-old comparisons remain possible.

## 3. Approach (chosen)

**One self-contained `storefront-flow.js`; three k6 scenarios selected by a `PROFILE` env var.**

Rationale: k6 ConfigMaps mount a **single flat file with no import support** (the reason `payment-flow.js` inlines everything). Writing the funnel once and building `options.scenarios` conditionally from `__ENV.PROFILE` gives one source of truth with no duplication. A single parameterized Job manifest sets `PROFILE`.

Rejected alternatives:
- **Separate script per profile** — copy-pastes the funnel 3× (a cart-step fix would have to land in three files).
- **Extend `payment-flow.js` in place** — conflates the clean saga baseline with the new model and loses the comparison baseline.

## 4. Traffic model (the funnel)

Each VU iteration is one **shopper session**. Steps fire probabilistically (checkout-heavy mix) with **randomized think-time** between them (replacing the flat `sleep(1)`). Browse and product-detail are anonymous (`PERMIT_ALL`); cart/checkout/pay require a Bearer token (the gateway injects `X-User-Id` from the JWT — k6 only sends the token).

| Step | Endpoint | Method | Auth | Session reach | k6 tag |
|---|---|---|---|---|---|
| Browse catalog page | `/product-service/v1/products?page={rand}&size=12` | GET | anon | 100% | `browse` |
| View product detail | `/product-service/v1/products/{id}` | GET | anon | 60% | `detail` |
| Login | `/authorization-server/v1/auth:login` | POST | — | 40% | `login` |
| Add to cart | `/order-service/v1/shopping-carts:add-item` | POST | Bearer | 40% | `add_cart` |
| Create order (checkout) | `/order-service/v1/orders` | POST | Bearer | 25% | `create_order` |
| Create payment | `/payment-service/v1/payments?orderId={id}` | POST | Bearer | 20% | `create_payment` |
| Approve/cancel/fail chain | mock-paypal approve link → 302 follow | GET | — | 20% (90/5/5) | `paypal_*` |

**Funnel realization (per session, sequential gates):** at each gate draw a fresh uniform random `r ∈ [0,1)`; if `r >= continue_prob` the session ends early (after its think-time). The gates are conditional, so the **conditional continuation probabilities** below are chosen to yield the target **cumulative** reach:

| Gate | Conditional continue prob | Cumulative reach |
|---|---|---|
| browse (always runs) | 1.00 | 100% |
| browse → detail | 0.60 | 60% |
| detail → login+cart | 0.667 (= 0.40 / 0.60) | 40% |
| cart → create order | 0.625 (= 0.25 / 0.40) | 25% |
| order → pay | 0.80 (= 0.20 / 0.25) | 20% |

Login happens at the detail→cart gate (only sessions that will add to cart pay the bcrypt cost), so anonymous browse sessions cost no login CPU — this is what lets the funnel sustain more concurrent sessions than the all-pay loop. The implementer must use these conditional values (not the cumulative percentages) as the per-gate thresholds.

**Think-time (uniform random per step):**
- after browse: `1–4s`
- after detail: `2–6s`
- after add-to-cart: `1–3s`
- after checkout before pay: `1–2s`

**Payment decision mix:** 90% approve / 5% cancel / 5% fail — identical to `payment-flow.js`, exercising saga success **and** compensation. The 302 redirect-follow logic (rewriting `api.microecom.local` → in-cluster gateway DNS, stopping at the SPA host hop) is copied verbatim from `payment-flow.js`.

**Request bodies (snake_case wire format — `@JsonNaming(SnakeCaseStrategy)`):**
- add-to-cart: `{ "product_id": "<pid>", "quantity": 1 }`
- create order: `{ "address": "k6 load test", "phone_number": "0912345678", "items": [{ "product_id": "<pid>", "quantity": 1 }] }`

## 5. Profiles (`PROFILE` env → k6 scenario)

`buildScenarios(profile)` returns exactly one scenario object so a Job runs one profile. `options.thresholds` is likewise profile-dependent.

| Profile | Executor | Shape | Abort on threshold |
|---|---|---|---|
| `smoke` | `ramping-vus` | `0→50` over 1m, hold 50 for 3m, `→0` over 30s | yes |
| `soak` | `constant-vus` | steady moderate load (default **30 VU**) for **30m** | yes (strict + stability) |
| `stress` | `ramping-arrival-rate` | open model: ramp target iterations/s upward (e.g. `10→120 /s` over ~15m), `preAllocatedVUs` ~50, `maxVUs` ~150 | **no** (`abortOnFail: false`) |

Open-model arrival-rate for **stress** is deliberate: it keeps issuing at the target rate even as the system slows, exposing the true breaking point instead of closed-model VUs self-throttling. The default `soak` VU count (30) is conservative for the laptop; it is overridable via `__ENV.SOAK_VUS`.

All numeric knobs are env-overridable with the defaults above: `PROFILE`, `SOAK_VUS`, `SOAK_DURATION`, `STRESS_START_RATE`, `STRESS_PEAK_RATE`, `STRESS_DURATION`, `STRESS_MAX_VUS`, plus the existing `BASE_URL`, `INGRESS_ORIGIN`, `PRODUCT_IDS`, `USER_COUNT`, `USER_PASS`, `ADMIN_USER`, `ADMIN_PASS`.

## 6. Thresholds (per profile)

**soak** (strict — this is the regression/drift catcher):
- `http_req_failed: ['rate<0.01']`
- `checks: ['rate>0.99']`
- `http_req_duration{name:browse}: ['p(95)<500']`
- `http_req_duration{name:detail}: ['p(95)<500']`
- `http_req_duration{name:create_payment}: ['p(95)<2000']`
- `http_req_duration{name:login}: ['p(95)<1500']` — relaxed from 800ms; the bcrypt login ceiling is a **documented known item** (see `performance-tuning-report.md` §4), not what a soak measures. Latency **stability over time** is judged on Grafana dashboard #19665 (no upward p95 trend), called out in the run guide — k6 cannot assert a trend directly.

**stress** (no aborting thresholds): report the arrival rate / concurrency at which `http_req_failed` first crosses 5% as the **discovered ceiling**. Thresholds are defined but with `abortOnFail: false` so the run completes and the full ramp is captured.

**smoke** (unchanged from current SLO): `http_req_failed<0.05`, `checks>0.95`, `create_payment p95<2000`, `login p95<800`.

## 7. setup() and fixtures (reused as-is)

- Probe `GET /product-service/v1/products?page=1&size=1` (must be 200) — confirms gateway+product path.
- Admin login (`perftest_admin`) + top up each `PRODUCT_IDS` entry to 1,000,000 via `PATCH /inventory-service/v1/inventories/{pid}` `{quantity:1000000, is_add:true}`. The oversell fix made `update()` sync both the DB `stock` column and the Redis `available:` counter, so this top-up correctly seeds the new reservation authority. **Fail loud** on any non-2xx (unchecked top-up silently 403s and masquerades as a latency failure — see tuning report §2).
- Headroom check: at the conservative envelope the worst-case settled sagas over 30m is well under 1M/product, so no mid-run depletion.
- Fixtures: 100 `perftest_user_N` + `perftest_admin` from `make k8s-seed-perftest`; real catalog ObjectIds passed via `PRODUCT_IDS` (the `test-product-1..3` defaults are fake in this split architecture — the Job must override them, same as `payment-job.yaml`).

## 8. Files

- **Create** `k8s/apps/base/k6-stress/storefront-flow.js` — self-contained funnel + `buildScenarios()` + per-profile thresholds.
- **Create** `k8s/apps/base/k6-stress/storefront-job.yaml` — parameterized Job (`backoffLimit: 0`, `ttlSecondsAfterFinished: 3600`, `restartPolicy: Never`, image `grafana/k6:0.54.0`, `experimental-prometheus-rw` output, VM remote-write env, `PROFILE` env, `PRODUCT_IDS` override). Mirrors `payment-job.yaml`.
- **Modify** `Makefile` — add `k8s-storefront-smoke`, `k8s-storefront-soak`, `k8s-storefront-stress` (+ a `-logs` tailer), following the `k8s-payment-stress` pattern: imperative `kubectl create configmap k6-storefront-script --from-file=...storefront-flow.js --dry-run=client -o yaml | kubectl apply -f -`, then `kubectl apply -f storefront-job.yaml` with the profile set. Add help lines.
- **Modify** `docs/load-test-model-and-capacity.md` and `docs/performance-test-guide.md` — document the funnel model, the three profiles, how to run each, and where to read soak stability.
- **Reuse unchanged:** perftest seed, VictoriaMetrics remote-write wiring, the existing `payment-flow.js` (regression baseline).

## 9. Data flow / plumbing (unchanged from payment-flow.js)

In-cluster Job → gateway Service DNS `gateway.apps.svc.cluster.local:6868` (ingress/TLS bypassed) → services → mock-paypal in-cluster. Metrics: k6 `experimental-prometheus-rw` → `vmsingle.monitoring.svc.cluster.local:8428` → Grafana #19665. No hostAliases (the script rewrites the `api.microecom.local` origin to gateway DNS at each redirect hop).

## 10. Edge cases / error handling

- **A session that fails an early gate ends cleanly** (returns after think-time) — it is not an error; only HTTP/`check` failures count against thresholds.
- **Login failure** mid-funnel: record the failed check, end the session (don't proceed to authenticated steps).
- **Out-of-stock during stress** (if the ceiling is pushed past top-up): a non-201 order is a real signal under stress (not aborted), and a `check` failure under soak (should not happen given headroom).
- **Stress abort semantics:** `abortOnFail: false` on stress thresholds so the run completes the ramp and reports the ceiling rather than aborting at first breach.
- **Redirect chain cap:** keep the `hops < 5` guard from `payment-flow.js`.

## 11. Testing / acceptance

- **Lint:** `k6 inline` syntax is valid (the script must parse; a quick `k6 archive`/`k6 inspect` or a dry `--paused` start is enough — no unit framework for k6).
- **smoke** profile reproduces today's numbers within noise (sanity that the funnel plumbing is correct): 0% errors, checks ~100%.
- **soak** completes 30m with `http_req_failed < 1%` and a flat p95 trend on #19665 (no leak/drift). A rising RSS or p95 over the window is the bug the soak exists to find — capture it, don't mask it.
- **stress** completes the full ramp without aborting and reports the arrival rate + concurrency at which `http_req_failed` crosses 5% (the discovered ceiling) and whether order-service/auth HPA scaled.
- All three runnable via the new make targets; total suite < 1h.

## 12. Out of scope (explicit)

- Real ingress/TLS path and real PayPal (environment realism) — deliberately deferred; this stays in-cluster with the mock.
- Spike/HPA-recovery profile and 2h+ soak (the "ambitious" envelope) — not chosen; the conservative envelope is the target.
- Any change to `payment-flow.js` or the existing `k8s-payment-stress` target.
