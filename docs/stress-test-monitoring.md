# Stress-Test Monitoring Runbook

**Companion to [`performance-test-guide.md`](performance-test-guide.md)** (which covers *how to run* the test, the load model, and the SLOs). This doc answers: **while the k6 payment-saga stress test is running, where do I look, and what is healthy vs a red flag?**

Run the test with:

```bash
make k8s-payment-stress        # fires the 50-VU / 3-min payment-saga Job
```

## Prerequisites for the dashboards

The UIs are served via ingress, so your `/etc/hosts` needs:

```
127.0.0.1 grafana.microecom.local
127.0.0.1 vm.microecom.local
```

## The three zoom levels

The same run, viewed at three levels of detail. Use all three together:

| Level | Where | Best for |
|---|---|---|
| **Verdict** | `make k8s-payment-stress-logs` | Did it pass? p95 latency, checks, errors, SLO thresholds |
| **Live table** | `make k9s` → `Shift-A` | At-a-glance per-pod CPU/MEM/%limit and replica scaling, right now |
| **Time series** | Grafana #19665 | Trends over the run — latency curves, throughput, resource graphs |

Data path: the in-cluster k6 Job **remote-writes** to **VictoriaMetrics** (`vmsingle.monitoring.svc:8428`); Grafana reads from VM; pod CPU/MEM come from cAdvisor + kube-state-metrics into the same VM.

---

## 1. The k6 result (the authoritative verdict)

```bash
make k8s-payment-stress-logs
```

Watch for, at the end of the run:
- **Threshold results** (the pass/fail SLO) — e.g. `http_req_duration{name:login} p(95)<800`. A `✓` per threshold = pass.
- **Checks** — functional correctness under load (order created, payment SUCCESS, etc.). Should stay ~100%.
- **`iteration_duration` p95/p99** — full-saga latency.
- **`iterations` / sec** — throughput (completed sagas).

## 2. Grafana (#19665) — trends over time

Primary (ingress): **http://grafana.microecom.local** (login `admin` / `admin`) → open dashboard **gnetId #19665** (k6 Prometheus/VM).

Fallback (port-forward):
```bash
kubectl -n monitoring port-forward svc/grafana 3000:80   # then http://localhost:3000
```

In the dashboard, filter `http_req_duration` by the **`name`** tag (`login`, `create-order`, `create-payment`, `approve`) to see *which saga step* dominates latency.

## 3. k9s — live pod table + autoscaling

```bash
make k9s        # then Shift-A for the apps namespace
```

- Watch the **`%CPU/L`** and **`%MEM/L`** columns climb as load ramps.
- New `order-service` / etc. pods appear as the **HPA scales out** (order-service 1 → 3).
- This is also where you **confirm the `MALLOC_ARENA_MAX=2` fix holds under load** — `%MEM/L` should stay comfortably below the limit (see red flags).

## 4. HPA (autoscaling) — live

```bash
kubectl -n apps get hpa -w
```

Services autoscale on CPU (target 60% of CPU request). `order-service` scales widest (1 → 3) — it's the saga hot path.

## 5. Saga health — is the async pipeline keeping up?

The saga rides Kafka (order → CDC → orchestrator → reply). If throughput outruns the consumers, **consumer-group lag** rises — the earliest sign of a saga bottleneck.

- **k9s infra plugin:** `Shift-I` (infra) → select **`kafka-0`** → **`Shift-Z`** → consumer-group lag for `order.*` and `mongo-event-group`. Lag should hover near 0 and drain after the run.
- **CDC connector must stay RUNNING:**
  ```bash
  kubectl -n infra exec deploy/kafka-connect -- curl -s localhost:8083/connectors/mongodb-source-connector/status
  ```
- Per-service logs in k9s: `Shift-A` → select `order-service` / `payment-service` / `orchestrator-service` → `l`.

## 6. VictoriaMetrics — ad-hoc queries

**http://vm.microecom.local/vmui** for raw PromQL; scrape health at **http://vm.microecom.local/targets**.

```promql
container_memory_working_set_bytes{namespace="apps"}   # RSS vs limit per pod
jvm_memory_used_bytes{area="heap"}                      # heap, labelled app=<service>
rate(http_server_requests_seconds_count[1m])           # request rate per service
```

---

## Healthy vs red flags

| Signal | Healthy | Red flag |
|---|---|---|
| k6 thresholds | all `✓` | any `✗` (p95 over SLO) |
| k6 checks | ~100% | checks failing → functional break under load |
| `%MEM/L` (k9s) | stays < ~85% | creeping to ~95%+ → memory pressure / OOMKill risk (arena fix not holding, or real demand) |
| HPA | scales out then back | pinned at max the whole run → undersized, or stuck at 1 → HPA/metrics broken |
| Consumer-group lag (`Shift-Z`) | near 0, drains after | climbing and not draining → saga can't keep up |
| CDC connector | `RUNNING` | `FAILED`/missing → orders stick at `PROCESSING` |
| Orders | reach `COMPLETED` | stuck `PROCESSING` → check connector + orchestrator logs |

## Known caveat: stock depletion

Seeded stock is small (product `…001/002/003` = **28 / 18 / 6** units, 52 total). Approved payments decrement stock via `PaymentSuccess`, so a sustained run **depletes it**, after which order-creation fails with out-of-stock — this shows up as rising k6 check failures *partway through*, not a latency problem. For a clean run, raise the quantities in `k8s/infra/jobs/06-perftest-seed` / the inventory seed first. (The 90/5/5 approve/cancel/fail decision mix means only ~90% of iterations decrement.)

## See also

- [`performance-test-guide.md`](performance-test-guide.md) — how to run, load model, SLO definitions, calibration & troubleshooting.
- `k8s/README.md` — k9s setup, namespace hotkeys (`Shift-A/I/B`), and the `Shift-Z` infra-health plugin.
