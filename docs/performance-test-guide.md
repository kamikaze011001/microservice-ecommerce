# Performance Test Guide — In-Cluster Payment-Saga Stress Test

A practical guide to running the k6 load test against the e-commerce platform on
the local kind cluster: **how to run it**, **how many users it simulates**, and
**what metrics we measure**. Written so the numbers are explainable end-to-end
(e.g. for an interview walkthrough).

---

## 1. What this test proves (TL;DR)

It drives the **full distributed payment saga** — login → create order →
create payment → PayPal approve/cancel/fail → callback — under sustained
concurrent load, and checks the system holds a fixed **SLO**:

| SLO target | Value |
|---|---|
| Sustained concurrent users (VUs) | **50, held for 3 minutes** |
| Error rate (`http_req_failed`) | **< 5%** |
| Functional check pass rate | **> 95%** |
| p95 latency — create payment | **< 2000 ms** |
| p95 latency — login | **< 800 ms** |

If every threshold passes, the held VU level is the **sustained throughput**
you can quote. The run also produces a populated Grafana dashboard and an
**autoscaling (HPA) scale-up** you can point to.

Source files:
- Load script: `k8s/apps/base/k6-stress/payment-flow.js`
- k6 Job manifest: `k8s/apps/base/k6-stress/payment-job.yaml`
- User seed: `k8s/infra/jobs/06-perftest-seed/` (run by `make k8s-seed-perftest`)

---

## 2. The system under test (one VU iteration)

Each virtual user repeats this loop. Requests go to the **gateway via in-cluster
Service DNS** (`gateway.apps.svc.cluster.local:6868`) — Ingress is skipped so
latency reflects the backend, not the proxy.

```
   k6 VU (a simulated shopper)
        │  POST /authorization-server/v1/auth:login        (tag: login)
        ▼
   authorization-server ── issues JWT
        │  POST /order-service/v1/orders                    (tag: create_order)
        ▼
   order-service ── validates stock via gRPC → inventory-service → creates order
        │  POST /payment-service/v1/payments?orderId=…      (tag: create_payment)
        ▼
   payment-service ── calls mock-paypal-service → returns approve link
        │  GET <approve link>?decision=approve|cancel|fail  (tag: paypal_<decision>)
        ▼
   mock-paypal → payment-service callback → 302 chain       (tag: paypal_callback)
        │
        ▼
   saga settles asynchronously (Kafka → orchestrator-service)
   check: "flow settled" (final 200/302 means the callback ran)
   sleep(1s), then the VU starts the next iteration
```

**Why mock-paypal:** `mock-paypal-service` (Java 25) stands in for PayPal's REST
API so the full payment flow — including the **failure/compensation** paths —
runs locally without real PayPal. `fail` returns HTTP 422 at capture to trigger
the `PaymentFailed` compensation branch of the saga.

---

## 3. How many users we simulate (the load model)

### Virtual Users (VUs) and the load profile

k6 runs **Virtual Users** — independent loops each behaving like one shopper
hammering the API back-to-back (with a 1-second think-time between iterations).
The profile (`payment-flow.js` → `options.stages`):

| Phase | Duration | VUs | Purpose |
|---|---|---|---|
| Ramp-up | 1 min | 0 → 50 | warm the system, JIT, connection pools |
| **Hold** | **3 min** | **50** | the sustained-throughput measurement window |
| Ramp-down | 30 s | 50 → 0 | graceful drain |

Total ≈ **4.5 minutes**, peak **50 concurrent VUs**.

### VUs vs throughput — the important distinction

- **50 VUs = 50 *concurrent* shoppers**, not 50 requests. Each VU runs the
  multi-step saga, then `sleep(1s)`, then repeats.
- **Throughput** is the *result*, reported by k6 as iterations/sec and
  `http_reqs`/sec. Roughly: `throughput ≈ VUs / (avg_iteration_time)`, where one
  iteration ≈ login + order + payment + redirect chain + 1s think-time. So 50
  VUs at ~1.5 s/iteration ≈ ~33 completed payment sagas/sec. **Read the real
  number off the k6 summary; don't estimate it in the interview.**

### The 100 seeded users

The 50 VUs authenticate as real accounts seeded into MySQL:
`perftest_user_1 … perftest_user_100` (VU *n* uses `perftest_user_(n mod 100)+1`),
plus one `perftest_admin`. They are created by the `06-perftest-seed` bootstrap
Job (`make k8s-seed-perftest`, run automatically inside `make k8s-bootstrap`).
Regular users need no special role (order/payment endpoints require only
`AUTHORIZED`); `perftest_admin` has the `ADMIN` role because the test's `setup()`
phase tops up product stock via the admin-only `PATCH /inventory-service/...`.

### The 90/5/5 decision mix

To exercise both the happy path **and** the compensation paths, each iteration
randomly picks a PayPal outcome (`payment-flow.js`):

| Decision | Share | Saga effect |
|---|---|---|
| `approve` | 90% | payment captured → order completes |
| `cancel` | 5% | payer cancels → `PaymentCanceled` compensation |
| `fail` | 5% | capture returns 422 → `PaymentFailed` compensation |

This is deliberate: a load test that only does the happy path won't surface
locking/consistency issues on the rollback branches.

### Tuning the load

Override via env (defaults in parentheses): `USER_COUNT` (100), and the VU/stage
targets in `options.stages`. If a laptop kind cluster saturates at 50, lower the
two `target: 50` values to 30 or 20 and re-run — **the highest level that stays
under the thresholds is the number you quote.**

---

## 4. What metrics we measure

### Threshold metrics (the pass/fail SLO)

These appear in a **THRESHOLDS** block at the end of the run; any breach exits
k6 non-zero:

| Metric | Meaning | Bar |
|---|---|---|
| `http_req_failed` | fraction of HTTP requests that failed (network error / 5xx) | rate < **0.05** |
| `checks` | fraction of functional assertions that passed | rate > **0.95** |
| `http_req_duration{name:create_payment}` | latency of the create-payment call (the heaviest hop — it reaches mock-paypal) | p95 < **2000 ms** |
| `http_req_duration{name:login}` | latency of the auth call | p95 < **800 ms** |

### Functional checks (correctness under load)

Per iteration the script asserts: `login 200`, `order 201`, `payment 200`,
`has links` (payment returned a PayPal approve link), and `flow settled` (the
redirect chain ended in 200/302, i.e. the callback ran). The `checks` rate above
aggregates these.

### Per-step latency via tags

Every request is tagged so you can read latency per saga step independently:
`login`, `create_order`, `create_payment`, `paypal_approve` / `paypal_cancel` /
`paypal_fail`, `paypal_callback` (plus `admin_login` / `setup_inventory` from
setup). In Grafana, filter `http_req_duration` by the `name` tag to see which
hop dominates.

### Throughput & standard k6 metrics

From the summary: `iterations` (total completed sagas) and iterations/sec;
`http_reqs` (total requests) and req/sec; `iteration_duration` (full-saga
latency) p95/p99; `vus` / `vus_max`.

### Where the metrics go (Grafana)

> **Live monitoring runbook:** for where to look *during* a run (k6 logs, Grafana,
> k9s, consumer-group lag) plus healthy-vs-red-flag signals, see
> [`stress-test-monitoring.md`](stress-test-monitoring.md).

The k6 Job remote-writes live metrics to **VictoriaMetrics**
(`vmsingle.monitoring.svc.cluster.local:8428`). View them on the provisioned
**Grafana k6 dashboard (gnetId #19665)**:

```bash
kubectl -n monitoring port-forward svc/grafana 3000:80
# open http://localhost:3000 → dashboard #19665 (k6 Prometheus)
```

### The autoscaling (HPA) story

Under load, several services autoscale on CPU (target **60%** of CPU requests).
Watch it live during the run:

```bash
kubectl -n apps get hpa -w
```

| Service | min → max replicas | Autoscales? |
|---|---|---|
| order-service | 1 → **3** | yes (scales widest — it's the saga hot path) |
| inventory-service | 1 → 2 | yes (gRPC stock checks per order) |
| product-service | 1 → 2 | yes |
| gateway | 1 → 2 | yes |
| **payment-service** | fixed | **no HPA by design** |

The interview-ready sentence: *"Holding 50 VUs drove order-service CPU past 60%,
so the HPA scaled it from 1 to N pods; the held error rate stayed under the 5%
SLO and p95 create-payment under 2 s."* (Fill N and the latencies from the run.)

---

## 5. How to run it

### Prerequisites

- Docker running; the kind cluster image toolchain available.
- `/etc/hosts` has `127.0.0.1  microecom.local api.microecom.local` (added once).
- A JDK 25 toolchain for building `mock-paypal-service` (the bootstrap builds it).

### Step 1 — Bring the whole platform up (first run, ~20–40 min)

```bash
make k8s-bootstrap
```

This is one-shot: create cluster → infra → build all images (incl. the Java-25
mock-paypal) → seed → deploy all apps → seed MySQL → seed inventory → **seed the
perftest users** (`k8s-seed-perftest`, runs last). It finishes with a status
table. Confirm every pod is Ready, including `mock-paypal-service`:

```bash
kubectl -n apps get pods
```

> If the cluster is already up and only the perftest users are missing, you can
> run just `make k8s-seed-perftest` instead of a full bootstrap.

### Step 2 — Verify the wiring (pre-flight)

```bash
# perftest users seeded? expect 100
kubectl -n infra exec -i $(kubectl -n infra get pod -l app=mysql -o jsonpath='{.items[0].metadata.name}') -- \
  mysql -uroot -proot -N -e "SELECT COUNT(*) FROM ecommerce_dev.account WHERE username LIKE 'perftest_user_%';"

# payment-service points at the mock?
kubectl -n apps exec deploy/payment-service -- printenv | grep -i paypal

# metrics sink reachable?
kubectl -n monitoring get svc vmsingle
```

### Step 3 — Single-VU dry run (the gate)

Prove one full saga goes green before applying load. (Runs the same script with
1 VU / 1 iteration.)

```bash
kubectl -n apps delete pod k6-payment-dryrun --ignore-not-found
kubectl -n apps create configmap k6-payment-script \
  --from-file=k8s/apps/base/k6-stress/payment-flow.js --dry-run=client -o yaml | kubectl apply -f -
kubectl -n apps run k6-payment-dryrun --image=grafana/k6:0.54.0 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"k6","image":"grafana/k6:0.54.0","args":["run","--vus","1","--iterations","1","/scripts/payment-flow.js"],"env":[{"name":"BASE_URL","value":"http://gateway.apps.svc.cluster.local:6868"},{"name":"INGRESS_ORIGIN","value":"http://api.microecom.local"},{"name":"PRODUCT_IDS","value":"67c000000000000000000001,67c000000000000000000002,67c000000000000000000003"}],"volumeMounts":[{"name":"script","mountPath":"/scripts"}]}],"volumes":[{"name":"script","configMap":{"name":"k6-payment-script"}}]}}'
kubectl -n apps wait --for=condition=Ready pod/k6-payment-dryrun --timeout=60s || true
kubectl -n apps logs -f pod/k6-payment-dryrun
kubectl -n apps delete pod k6-payment-dryrun --ignore-not-found   # cleanup
```

Expect all checks green (`login 200`, `order 201`, `payment 200`, `has links`,
`flow settled`). Optionally confirm the saga actually settled end-to-end:

```bash
kubectl -n infra exec -i $(kubectl -n infra get pod -l app=mysql -o jsonpath='{.items[0].metadata.name}') -- \
  mysql -uroot -proot -N -e "SELECT status, COUNT(*) FROM ecommerce_dev.\`order\` GROUP BY status;"
```

### Step 4 — The SLO run

Open two watchers first (separate terminals): `kubectl -n apps get hpa -w` and
the Grafana port-forward (Step in §4). Then fire it:

```bash
make k8s-payment-stress        # ramps 0→50, holds 50 for 3m, ramps down
make k8s-payment-stress-logs   # tail to completion
```

Re-runnable — the target deletes the prior Job first.

### Step 5 — Read the results

At the end of `k8s-payment-stress-logs`, capture from the k6 summary:
- the **THRESHOLDS** block (all four pass?),
- `iterations` + iterations/sec, `http_reqs` + req/sec (**throughput**),
- `iteration_duration` p95, and per-tag p95 for `create_payment` / `login`,
- from the HPA watch: did `order-service` scale up, and to how many replicas?

Write it as one line, e.g.: *"Sustained 50 VUs ≈ M payment sagas/s, p95
create-payment X ms, error rate Y% (< 5% SLO); order-service autoscaled 1→K
pods under load."*

---

## 6. Calibration & troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `admin login failed` in setup() | perftest users not seeded → `make k8s-seed-perftest` |
| `gateway/product-service not reachable` | apps not Ready, or wrong `BASE_URL` |
| `http_req_failed` > 5% with timeouts/503s | cluster saturated → lower `target: 50` to 30/20 and re-run; the highest passing level is your quoted figure |
| orders stuck (saga not settling) | check the Mongo-CDC → Kafka → orchestrator path (see `k8s/CLAUDE.md`) |
| k6 Job errors immediately on metrics | VictoriaMetrics endpoint unreachable — verify `vmsingle` svc, or drop the `-o experimental-prometheus-rw` output |
| Grafana dashboard empty | confirm the run used remote-write and you're viewing dashboard #19665 over the run's time window |

---

## 7. Interview talking points

- **What you load-tested:** not a single endpoint, but a *distributed saga*
  across 5+ services with sync (REST/gRPC) and async (Kafka) hops, including the
  failure/compensation branches (90/5/5 mix).
- **What "50 VUs" means:** 50 concurrent shoppers, each running the whole
  checkout loop; throughput is the measured iterations/sec, not the VU count.
- **How you know it's healthy under load:** four SLO thresholds (error rate,
  functional checks, and p95 latency on the two latency-critical hops) — all
  enforced by k6, fail the run if breached.
- **Elasticity:** CPU-based HPAs (60% target) scale order/inventory/product/
  gateway out under load; payment-service is intentionally fixed (single-replica
  dependency boundary), which is itself a discussion point.
- **Reproducibility:** users are seeded by a bootstrap Job wired into
  `make k8s-bootstrap`; the test points at real catalog product IDs; metrics
  flow to Grafana — so anyone can re-run and get comparable numbers.

## Running the production-shaped funnel (storefront-flow.js)

Prerequisites: cluster up (`make k8s-up` or equivalent) and perftest fixtures
seeded once (`make k8s-seed-perftest`).

```bash
make k8s-storefront-smoke    # ~4.5m — fast gate; expect 0% errors, checks ~100%
make k8s-storefront-soak     # 30m   — leak/drift; READ THE TREND on Grafana #19665
make k8s-storefront-stress   # ~15m  — open-model ramp; reports the discovered ceiling
make k8s-storefront-logs     # tail the running Job's k6 output + end summary
```

Override knobs inline, e.g. a shorter soak or a higher stress peak:
```bash
# edit via env in the Job, or re-run with a tweaked storefront-job.yaml:
#   SOAK_DURATION=10m SOAK_VUS=20   (soak)
#   STRESS_PEAK_RATE=200 STRESS_MAX_VUS=250   (stress)
```

### What "pass" means per profile

- **smoke** — `http_req_failed < 5%`, `checks > 95%`, `create_payment p95 < 2s`,
  `login p95 < 800ms`. k6 prints a green check per threshold.
- **soak** — `http_req_failed < 1%`, `checks > 99%`, browse/detail p95 < 500ms,
  `login p95 < 1500ms`. **k6 thresholds alone are not the soak verdict** — open
  Grafana dashboard **#19665** and confirm there is **no upward p95 or RSS trend**
  over the 30m window. A flat trend = no leak/drift (the thing the soak exists to
  catch). k6 cannot assert a trend; the eyeball on #19665 is the real gate.
- **stress** — thresholds are `abortOnFail: false`, so the ramp always completes.
  Read off the **arrival rate and concurrency at which `http_req_failed` first
  crosses 5%** — that is the discovered ceiling. Watch `kubectl -n apps get hpa -w`
  during the run to confirm order-service / auth HPA scaled.

The existing `make k8s-payment-stress` (pure-saga baseline) is unchanged and
remains the apples-to-apples regression comparison.
