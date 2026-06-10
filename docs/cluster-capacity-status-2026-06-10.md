# Cluster Capacity & Status Report — 2026-06-10

Companion to `docs/load-test-model-and-capacity.md` (the user model) and
`docs/performance-stress-report-2026-06-10.md` (the original stress run + fixes).
This report answers: **how many users can this system serve, at what RPS/QPS,
and where does the next wall sit** — derived from the post-fix k6 re-run
(13:10–13:25 UTC, after PR #21's cart/payment/replication fixes).

> Same caveat as the capacity doc: numbers are from a kind cluster on one
> laptop (4 nominal nodes sharing 12 physical cores). Treat everything as a
> **relative floor**, not a production SLA. On real hardware with real network
> latency, absolute numbers shift — the ratios and bottleneck order are what
> transfer.

---

## TL;DR — validated capacity (floor, not ceiling)

| Metric | Validated value | Notes |
|---|---|---|
| Session arrival rate | **120 sessions/s sustained** | 15-min ramp 10→120/s, zero degradation at peak |
| Gateway throughput | **365 req/s peak**, 211 req/s avg | previous knee (~230 req/s) passed cleanly |
| Concurrent active users | **~760** (with realistic think times) | Little's law, see math below |
| Completed checkouts | **24 payments/s** (≈ 86k/hour) | 20% of sessions convert in the model |
| Error rate | **0.00%** (0 / 190,462 requests) | all 8 check types 100% |
| Overall latency | p95 **96 ms**, median 7.7 ms | p90 77 ms, max 2.11 s |
| Login (bcrypt) | p95 160 ms | the known CPU hog |
| Payment create | p95 152 ms | was 957 ms before the JTA fix |

**The true ceiling was not reached.** Every check passed at the test's maximum
arrival rate — the system was still healthy when the profile topped out. The
real knee is somewhere above 120 sessions/s / 365 req/s.

---

## 1. What was tested

`k8s/apps/base/k6-stress/storefront-flow.js`, stress profile:
ramping-arrival-rate **10 → 120 sessions/s over 15 min**, maxVUs 150,
`THINK_SCALE=0.1` (think times compressed 10× so the load generator doesn't
need thousands of VUs). In-cluster, hitting the gateway Service directly.

Each "session" walks the storefront funnel from
`docs/load-test-model-and-capacity.md`:

| Step | % of sessions | Real think time before next step |
|---|---|---|
| browse (product list) | 100% | 1–4 s |
| product detail | 60% | 2–6 s |
| login | 40% | — (only cart-bound sessions log in) |
| add to cart | 40% | 1–3 s |
| create order | 25% | 1–2 s |
| create payment | 20% | — |
| approve/cancel/fail | 20% | 90/5/5 split |

Result: **58,407 sessions**, 190,462 HTTP requests → **3.26 req/session**
(matches the funnel sum exactly: 1 + 0.6 + 0.4 + 0.4 + 0.25 + 0.2 + ~0.4 ✓).

---

## 2. Capacity math — "how many users is that?"

### Sessions/s → concurrent users (Little's law)

`concurrent users = arrival rate × average session duration`

With **real** (uncompressed) think times, the expected session duration is the
funnel-weighted sum of thinks plus request time:

```
E[think] ≈ 2.5s (browse) + 0.6×4s (detail) + 0.4×2s (cart) + 0.25×1.5s (order)
        ≈ 6.1 s
E[session] ≈ 6.1s + ~0.2s request time ≈ 6.3 s
```

```
120 sessions/s × 6.3 s ≈ 760 users actively clicking at any instant
```

The compressed run confirms the model: measured iteration avg 716 ms ≈
0.63 s think (6.3 × 0.1) + request time ✓.

### Concurrent users → "users on the site"

760 is *active* users mid-funnel. Real traffic has idle tabs, readers, and
returners — a common 5–10× ratio between "logged-in/browsing population" and
"actively requesting" puts the comfortable serving population around
**4,000–8,000 simultaneous visitors**, with the validated floor being the
760 actives / 120 new sessions per second.

### RPS / QPS summary

| Layer | Avg over run | Peak (1-min rate) |
|---|---|---|
| Gateway (all traffic) | 211 req/s | **365 req/s** |
| product-service | — | 181 req/s |
| order-service | — | 74 req/s |
| payment-service | — | 45 req/s |
| authorization-server | — | 45 req/s (logins + token ops) |

---

## 3. Service status at peak load

p95 measured server-side over the peak 5 minutes; CPU is per-pod peak.

| Service | p95 | Peak CPU (cores) | Limit | Throttling | Verdict |
|---|---|---|---|---|---|
| gateway | 118 ms | 0.34 / 0.28 (×2) | 1.5 | <1% | healthy, HPA at 1–2/2 |
| product-service | 5.5 ms | 0.64 | 1.5 | 2.3% | effectively idle |
| order-service | 75 ms | 0.52 / 0.16 (×2) | 1.5 | <1% | healthy |
| authorization-server | 154 ms | **1.05 / 1.52 / 1.17 (×3)** | 2.0 | **13.4%** (hottest pod) | ⚠ **HPA maxed at 3/3** |
| payment-service | 637 ms¹ | 0.16 | 1.0 | <1% | healthy (I/O-bound, not CPU) |
| inventory-service | — | 0.10 | — | <1% | idle |

¹ payment p95 is the server-side view including the `paypal:success` callback
(capture + getOrderDetails against mock-paypal = two serial HTTP calls). The
client-visible `create_payment` p95 was 152 ms. After the call-then-record fix
this latency no longer holds DB transactions — it's wait, not work.

### Infra at peak

| Component | Observation | Verdict |
|---|---|---|
| MySQL primary | 94 / 300 connections (31%), 0.50 cores | comfortable |
| MySQL replicas ×2 | lag ≤ **1 s** at peak (was 15 s pre-fix), 0.22 cores each | fixed by WRITESET + 8 workers |
| MongoDB | 0.40 cores, 7.3% throttling at 1.5-core limit | watch — on the saga CDC path |
| Kafka | 0.07 cores | idle |
| Redis | 0.02 cores | idle |
| Vault | 12.3% throttling (tiny limit) | harmless — only token renewals |

### Cluster total

Peak whole-cluster CPU: **5.6 cores** (all namespaces). The kind "nodes"
advertise 4×12 cores but share one 12-core laptop, so real utilization peaked
around **~47% of the physical machine** — k6 itself and Docker overhead live
on the same host.

---

## 4. Where the next wall is

**authorization-server (bcrypt) is the next knee**, same as predicted in
`docs/load-test-model-and-capacity.md`:

- It consumed **3.7 of the cluster's 5.6 peak cores (66%)** while serving only
  45 req/s — bcrypt cost-10 is ~60–100 ms of pure CPU per login.
- The HPA was **pinned at maxReplicas=3** for the peak. The hottest pod ran at
  1.52 / 2.0 cores with 13.4% CFS throttling — throttling is what turns into
  latency cliffs first.
- At 120 sessions/s the model generates ~48 logins/s. Linear extrapolation:
  ~180–200 sessions/s would need ~6 auth cores — more than the current
  HPA ceiling can provide.

Cheap levers, in order:

1. Raise auth HPA `maxReplicas` 3 → 5 (one line; the cluster has CPU spare).
2. Login-token caching / refresh-token reuse in the k6 script if the goal is
   to stress the *rest* of the system past the bcrypt wall.
3. Longer-term: session reuse in the real frontend (returning users don't
   re-bcrypt) makes the modeled 40% login rate pessimistic.

Secondary watch items: MongoDB throttling (7.3% — raise limit if `flow
settled` ever degrades again) and payment-service's serial PayPal calls
(637 ms server-side; harmless now but a real-PayPal 99th percentile will be
slower than mock).

---

## 5. How to find the actual ceiling

This run validated 120 sessions/s with zero errors — a passing grade, not a
limit. To locate the knee:

```bash
# bump the stress profile and re-run
STRESS_PEAK_RATE=200 STRESS_MAX_VUS=300 make k8s-storefront-stress
```

Expect the failure signature to be: auth p95 → seconds, then
`dropped_iterations` climbing (arrival rate unmet), then login 5xx. Watch
`vmsingle` for auth pod throttling crossing ~25% — that's the leading
indicator.

---

## 6. Bottom line

| Question | Answer |
|---|---|
| How many users can it serve? | **~760 concurrently active** (validated); ~4–8k casual visitors by typical active-ratio estimates |
| What RPS can it bear? | **≥ 365 req/s at the gateway** with p95 < 100 ms and 0 errors — ceiling not yet found |
| Checkout throughput? | **24 completed payments/s** (≈ 86k orders/hour) |
| Cluster health at that load? | All green. Auth tier is the stressed one (HPA maxed, 13% throttled); everything else < 50% of limits |
| Next action if more capacity needed | Raise auth HPA max (3→5), then re-run at 200 sessions/s to find the true knee |
