# Design: Replace kube-prometheus-stack with VictoriaMetrics single-node + Grafana

**Date:** 2026-06-02
**Status:** Approved (brainstorming) — pending implementation plan
**Scope:** Local kind dev cluster observability for monitoring k6 load tests + Spring Boot Micrometer metrics

## Problem

The local kind cluster runs ~9 JVM services plus full infra (MySQL master/2 slaves,
Kafka, Redis, Vault, MinIO, MongoDB) on a single memory-constrained OrbStack VM.
kube-prometheus-stack (kps) added ~8 more pods and, with default sizing, contributed
to a VM memory meltdown (kube API `TLS handshake timeout`, wedged cluster). Its
install also depends on pulling four quay.io images (Operator, node-exporter,
config-reloader, grafana sidecar); a transient quay.io outage on 2026-06-01 failed
the whole bootstrap with "Progress deadline exceeded".

We still want **Grafana dashboards** and want to monitor, during a `make k8s-stress`
k6 run:

1. **k6 client metrics** — RPS, latency p90/p95/p99, error rate, VUs
2. **App/server metrics** — per-service JVM, HTTP server timings, HikariCP/Atomikos
   connection-pool usage (the pool-exhaustion failure mode we recently debugged)
3. **Pod/node CPU & mem** — resource saturation under load, plus pod restarts/OOMKills

## Decision

Replace kps with **VictoriaMetrics single-node + standalone Grafana + kube-state-metrics**.
VM single-node collapses scraper + TSDB + remote-write receiver into one binary, uses
3–5× less RAM than Prometheus for this workload (~200–300 MB), and removes the Operator,
the node-exporter DaemonSet, and the quay.io image dependency entirely.

### Why not the alternatives

- **Slimmed kps** — least migration effort but heaviest steady state; re-uses the exact
  stack that wedged the VM, and keeps the quay.io install fragility.
- **Plain Prometheus (no operator) + Grafana** — viable, familiar PromQL, but heavier than
  VM at equal cardinality and still needs an explicit `--web.enable-remote-write-receiver`
  flag for k6.
- **Grafana Alloy as scraper** — a collector, not a TSDB; still needs a backend, so it
  adds a component rather than removing one.

## Architecture

Three pods in the `monitoring` namespace (down from kps's ~8):

| Pod | Role | Replaces |
|---|---|---|
| VictoriaMetrics single-node | TSDB + built-in scraper (`-promscrape.config`) + remote-write receiver (`/api/v1/write`) | Prometheus **+** Prometheus Operator |
| Grafana (standalone chart) | dashboards | kps bundled Grafana |
| kube-state-metrics (standalone chart) | pod restart/OOM/object state | kps bundled ksm |

Removed entirely: Prometheus Operator (−1 pod), node-exporter DaemonSet (−1 per node,
4 on the current 3-worker+control-plane cluster), Alertmanager (already disabled), and
the `install.sh` quay.io pre-pull block.

### Scope → mechanism

| Scope | How it is satisfied |
|---|---|
| k6 client metrics | k6 Job remote-writes to VM `/api/v1/write` via `-o experimental-prometheus-rw` |
| App/server (JVM, Hikari) | VM scrapes the `management` port `/actuator/prometheus` on each service via Kubernetes endpoint discovery (port **name** `management`; numbers vary, e.g. product 17777, auth 19091) |
| Pod/node CPU & mem | VM scrapes the kubelet **cAdvisor** endpoint (per-pod + per-node CPU/mem — no node-exporter needed) |
| Pod restarts / OOMKills | VM scrapes kube-state-metrics |

### Metrics discovery — ServiceMonitors → VM scrape config

The 8 services currently expose a Prometheus-Operator `ServiceMonitor` CR
(`k8s/apps/base/*/servicemonitor.yaml`) scraping `port: management` at
`/actuator/prometheus`. `ServiceMonitor` is an Operator CRD; without the Operator the
CRD is gone and applying a `ServiceMonitor` fails. They are replaced by **one VM
`-promscrape.config`** scrape job using `kubernetes_sd_configs` (endpoints role),
keeping only endpoints whose port is **named** `management` in namespace `apps` (the
port number varies per service — product 17777, auth 19091 — but the name is uniform,
so number-agnostic relabel is correct). The `management` Service port stays (probes use
it), so **no Deployment/Service changes** — only the `servicemonitor.yaml` files are
deleted and removed from each service's `kustomization.yaml`.

VM scrape jobs:

1. `spring-actuator` — `kubernetes_sd_configs` endpoints role, ns `apps`, relabel keep
   `__meta_kubernetes_endpoint_port_name == management`, path `/actuator/prometheus`.
2. `kubelet-cadvisor` — node role, scrape `/metrics/cadvisor` via the kubelet; needs
   RBAC + `insecureSkipVerify` (kind kubelet serving certs are self-signed).
3. `kube-state-metrics` — scrape the ksm Service.

## k6 wiring

`k8s/apps/base/k6-stress/job.yaml`:

```yaml
args: ["run", "-o", "experimental-prometheus-rw", "/scripts/script.js"]
env:
  - { name: BASE_URL, value: "http://gateway.apps.svc.cluster.local:8080" }
  - { name: K6_PROMETHEUS_RW_SERVER_URL,
      value: "http://<vm-service>.monitoring.svc.cluster.local:8428/api/v1/write" }
  - { name: K6_PROMETHEUS_RW_TREND_STATS, value: "p(95),p(99),avg,min,max" }
```

`script.js` (load profile) is unchanged. The exact VM Service DNS name is pinned in the
implementation plan; recommend a `fullnameOverride` on the VM chart for a clean name
(e.g. `vmsingle-server.monitoring.svc.cluster.local:8428`). The
`experimental-prometheus-rw` label is k6's extension-lifecycle tag, not an instability
warning — it is the recommended self-hosted output.

## install.sh changes

`k8s/infra/install.sh`:

- Delete the quay.io pre-pull block (no quay images anymore).
- Replace the kps `helm upgrade --install kps ...` with:
  - `helm repo add vm https://victoriametrics.github.io/helm-charts/`
  - `helm repo add grafana https://grafana.github.io/helm-charts`
  - `helm upgrade --install vmsingle vm/victoria-metrics-single -n monitoring -f k8s/infra/values/victoria-metrics.yaml`
  - `helm upgrade --install grafana grafana/grafana -n monitoring -f k8s/infra/values/grafana.yaml`
  - `helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics -n monitoring`
- metrics-server, ingress, and everything below are untouched.

## Files changed

| File | Change |
|---|---|
| `k8s/infra/values/victoria-metrics.yaml` | new — 3-job scrape config, retention, RBAC, kubelet `insecureSkipVerify`, resources |
| `k8s/infra/values/grafana.yaml` | new — VM datasource + provisioned dashboards + adminPassword/resources |
| `k8s/infra/values/kube-prometheus-stack.yaml` | delete |
| `k8s/infra/install.sh` | quay pre-pull removed; kps install → 3 light installs |
| `k8s/apps/base/*/servicemonitor.yaml` (×8) | delete + remove from each `kustomization.yaml` |
| `k8s/apps/base/k6-stress/job.yaml` | add remote-write output + env |
| `k8s/CLAUDE.md` | update monitoring section: kps → VM, note ServiceMonitor removal |

## Dashboards (provisioned into Grafana)

- **k6 Prometheus #19665** (official Grafana Labs) — RPS, p95/p99 latency, error rate, VUs.
  Optionally #18030 (native histograms) if `K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true`.
- **Spring Boot / Micrometer** — JVM, HTTP server timings, HikariCP/Atomikos pool.
- **Pod/Node resources** — cAdvisor CPU/mem per pod + node; restarts from ksm.

## Out of scope (YAGNI)

- node-exporter / host-level disk/network metrics (redundant on a single-host kind VM).
- Alertmanager / alerting (local dev, already disabled in kps).
- Reducing the kind cluster to 1 worker — a separate, higher-leverage memory change,
  tracked independently.
- Logs/traces (Loki/Tempo) — metrics only for this work.

## Verification

- `make k8s-bootstrap` completes without the quay.io pre-pull and without kps.
- `kubectl -n monitoring get pods` shows exactly 3 Ready pods (vmsingle, grafana, ksm).
- VM targets page (`:8428/targets`) shows the 8 `spring-actuator` endpoints, kubelet
  cAdvisor, and ksm all `up`.
- `make k8s-stress` runs; Grafana dashboard #19665 shows live RPS/latency/error rate.
- Spring/Micrometer dashboard shows JVM + Hikari pool; pod-resources dashboard shows
  CPU/mem rising during the run.
- Peak `monitoring` namespace memory materially lower than kps (target VM < 400 MB).
