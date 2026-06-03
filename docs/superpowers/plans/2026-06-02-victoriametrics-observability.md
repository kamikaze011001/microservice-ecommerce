# VictoriaMetrics Observability Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace kube-prometheus-stack with VictoriaMetrics single-node + standalone Grafana + kube-state-metrics so the local kind cluster monitors k6 load tests, Spring Boot Micrometer metrics, and pod/node CPU/mem at ~3 pods instead of ~8.

**Architecture:** One VictoriaMetrics single-node binary acts as scraper + TSDB + remote-write receiver. It scrapes the 8 services' `/actuator/prometheus` (via Kubernetes endpoint discovery on the `management` port name), the kubelet cAdvisor endpoint (pod/node CPU/mem), and kube-state-metrics (restarts/OOM). k6 remote-writes its client metrics into VM. Grafana (standalone chart) reads VM as a Prometheus-type datasource and provisions the k6, JVM/Micrometer, and pod-resource dashboards. The Prometheus Operator, node-exporter DaemonSet, Alertmanager, and the quay.io image pre-pull are all removed.

**Tech Stack:** Helm (`vm/victoria-metrics-single` 0.39.0 / appVersion v1.144.0, `grafana/grafana` 10.5.15, `prometheus-community/kube-state-metrics`), kind, kustomize, k6 0.54.0 (`experimental-prometheus-rw` output).

**Notes for the implementer:**
- This is an infra/YAML migration, not application code. There is no unit-test framework; the "test" for each task is an explicit verification command (kustomize build, helm template/lint, kubectl, or the VM `/targets` page). Run them exactly as written.
- The cluster may or may not be up. Tasks 1–7 are pure file edits verifiable offline (kustomize build / helm template). Task 8 is the live integration verification and needs a running cluster (`make k8s-up` / `make k8s-bootstrap`).
- The `management` port **name** is uniform across services; the **number** is not (product 17777, auth 19091). All discovery keys on the name. Never hardcode a management port number in the scrape config.
- Commit after each task. Branch: this work is a new topic — if not already on a dedicated branch, create `feat/observability-victoriametrics` off `main` before the first commit. (Confirm with the user first if the working tree has unrelated uncommitted changes.)

---

## Task 1: VictoriaMetrics single-node values file

**Files:**
- Create: `k8s/infra/values/victoria-metrics.yaml`

- [ ] **Step 1: Write the values file**

```yaml
# VictoriaMetrics single-node — scraper + TSDB + remote-write receiver.
# Replaces Prometheus AND the Prometheus Operator from kube-prometheus-stack.
# Chart: vm/victoria-metrics-single 0.39.0 (appVersion v1.144.0).
rbac:
  create: true          # Role/RoleBinding for kubernetes_sd_configs discovery
serviceAccount:
  create: true

server:
  # Stable, short DNS name → service becomes `vmsingle.monitoring.svc:8428`.
  fullnameOverride: vmsingle

  # Local dev: short retention. k6 runs are minutes; a week of history is plenty.
  retentionPeriod: 7d

  resources:
    requests: { cpu: 100m, memory: 200Mi }
    limits:   { cpu: 500m, memory: 400Mi }

  service:
    type: ClusterIP
    servicePort: 8428

  # Built-in scraper. Replaces the 8 ServiceMonitors deleted in Task 5.
  scrape:
    enabled: true
    config:
      global:
        scrape_interval: 15s
      scrape_configs:
        # 1. Spring Boot Micrometer — discover endpoints in `apps` whose port
        #    is NAMED `management` (number varies per service: 17777, 19091, …).
        - job_name: spring-actuator
          metrics_path: /actuator/prometheus
          kubernetes_sd_configs:
            - role: endpoints
              namespaces:
                names: [apps]
          relabel_configs:
            - source_labels: [__meta_kubernetes_endpoint_port_name]
              action: keep
              regex: management
            - source_labels: [__meta_kubernetes_pod_label_app]
              target_label: app
            - source_labels: [__meta_kubernetes_namespace]
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              target_label: pod

        # 2. Kubelet cAdvisor — per-pod and per-node CPU/mem. No node-exporter.
        - job_name: kubelet-cadvisor
          scheme: https
          metrics_path: /metrics/cadvisor
          tls_config:
            ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
            insecure_skip_verify: true     # kind kubelet serving certs are self-signed
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          kubernetes_sd_configs:
            - role: node
          relabel_configs:
            - action: labelmap
              regex: __meta_kubernetes_node_label_(.+)
            - target_label: __address__
              replacement: kubernetes.default.svc:443
            - source_labels: [__meta_kubernetes_node_name]
              regex: (.+)
              target_label: __metrics_path__
              replacement: /api/v1/nodes/${1}/proxy/metrics/cadvisor

        # 3. kube-state-metrics — pod restarts, OOMKills, object state.
        - job_name: kube-state-metrics
          kubernetes_sd_configs:
            - role: endpoints
              namespaces:
                names: [monitoring]
          relabel_configs:
            - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
              action: keep
              regex: kube-state-metrics
```

- [ ] **Step 2: Lint the chart with these values**

Run:
```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo update vm
helm template vmsingle vm/victoria-metrics-single \
  -n monitoring -f k8s/infra/values/victoria-metrics.yaml > /tmp/vm-render.yaml && echo OK
```
Expected: prints `OK`, no template errors. The rendered output contains a Service named `vmsingle` on port 8428 and a ConfigMap holding the scrape config.

- [ ] **Step 3: Verify the rendered scrape config and service name**

Run:
```bash
grep -E "name: vmsingle$|spring-actuator|kubelet-cadvisor|kube-state-metrics" /tmp/vm-render.yaml
```
Expected: all four strings appear (the service name plus the three job names).

- [ ] **Step 4: Commit**

```bash
git add k8s/infra/values/victoria-metrics.yaml
git commit -m "feat(k8s): add VictoriaMetrics single-node values (scraper + remote-write)"
```

---

## Task 2: Grafana values file (datasource + dashboards)

**Files:**
- Create: `k8s/infra/values/grafana.yaml`

- [ ] **Step 1: Write the values file**

Dashboard IDs (grafana.com): `19665` k6 Prometheus, `4701` JVM (Micrometer), `19004` Spring Boot 3.x Statistics, `15760` Kubernetes / Views / Pods.

```yaml
# Standalone Grafana. Reads VictoriaMetrics as a Prometheus-type datasource
# (MetricsQL is a PromQL superset, so the stock Prometheus datasource works).
# Chart: grafana/grafana 10.5.15.

# LOCAL-DEV ONLY. AWS overlay replaces with admin.existingSecret backed by
# ExternalSecrets + AWS Secrets Manager.
adminPassword: admin

service:
  type: ClusterIP

persistence:
  enabled: false        # dashboards are provisioned from code; no PVC needed locally

resources:
  requests: { cpu: 50m, memory: 128Mi }
  limits:   { cpu: 200m, memory: 256Mi }

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: VictoriaMetrics
        type: prometheus
        access: proxy
        url: http://vmsingle.monitoring.svc.cluster.local:8428
        isDefault: true

dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: default
        orgId: 1
        folder: ""
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

dashboards:
  default:
    k6:
      gnetId: 19665           # k6 Prometheus
      revision: 3
      datasource: VictoriaMetrics
    jvm-micrometer:
      gnetId: 4701            # JVM (Micrometer)
      revision: 10
      datasource: VictoriaMetrics
    spring-boot-3:
      gnetId: 19004           # Spring Boot 3.x Statistics
      revision: 1
      datasource: VictoriaMetrics
    k8s-pods:
      gnetId: 15760           # Kubernetes / Views / Pods
      revision: 38
      datasource: VictoriaMetrics
```

- [ ] **Step 2: Lint the chart with these values**

Run:
```bash
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update grafana
helm template grafana grafana/grafana \
  -n monitoring -f k8s/infra/values/grafana.yaml > /tmp/grafana-render.yaml && echo OK
```
Expected: prints `OK`. Rendered output contains the `VictoriaMetrics` datasource URL and the four dashboard `gnetId` references in a ConfigMap.

- [ ] **Step 3: Verify datasource + dashboards rendered**

Run:
```bash
grep -E "vmsingle.monitoring.svc.cluster.local:8428|19665|4701|19004|15760" /tmp/grafana-render.yaml
```
Expected: the VM URL and all four gnetIds appear.

- [ ] **Step 4: Commit**

```bash
git add k8s/infra/values/grafana.yaml
git commit -m "feat(k8s): add standalone Grafana values (VM datasource + k6/JVM/pod dashboards)"
```

---

## Task 3: Rewire install.sh — drop kps + quay pre-pull, add VM/Grafana/ksm

**Files:**
- Modify: `k8s/infra/install.sh` (the quay pre-pull block ~lines 40–74 and the kps install ~lines 76–81)

- [ ] **Step 1: Add the grafana + vm helm repos**

Find the existing repo block and add two lines next to the `prometheus-community` repo add. Replace:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
```
with:
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
```

- [ ] **Step 2: Delete the quay.io pre-pull block**

Delete the entire block that begins with the comment `# Pre-load kube-prometheus-stack's quay.io images ...` and ends at the `fi` closing the `if command -v kind ...` guard (the block defining `KPS_QUAY_IMAGES` and looping `docker pull` + `kind load`). VM, Grafana, and ksm images come from docker.io / registry.k8s.io, so the quay workaround is obsolete.

- [ ] **Step 3: Replace the kps install with three light installs**

Replace:
```bash
# kube-prometheus-stack
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 58.2.0 \
  -f k8s/infra/values/kube-prometheus-stack.yaml \
  --wait --timeout 10m
```
with:
```bash
# Observability: VictoriaMetrics single-node + Grafana + kube-state-metrics.
# Replaces kube-prometheus-stack — see docs/superpowers/specs/2026-06-02-victoriametrics-observability-design.md
helm upgrade --install vmsingle vm/victoria-metrics-single \
  --namespace monitoring \
  --version 0.39.0 \
  -f k8s/infra/values/victoria-metrics.yaml \
  --wait --timeout 5m

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --version 10.5.15 \
  -f k8s/infra/values/grafana.yaml \
  --wait --timeout 5m

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace monitoring \
  --wait --timeout 3m
```

- [ ] **Step 4: Syntax-check the script**

Run:
```bash
bash -n k8s/infra/install.sh && echo "syntax OK"
grep -c "quay.io" k8s/infra/install.sh
grep -c "kube-prometheus-stack" k8s/infra/install.sh
```
Expected: `syntax OK`; both `grep -c` print `0` (no quay references, no kps references remain).

- [ ] **Step 5: Commit**

```bash
git add k8s/infra/install.sh
git commit -m "feat(k8s): install VM+Grafana+ksm instead of kube-prometheus-stack"
```

---

## Task 4: Delete the kube-prometheus-stack values file

**Files:**
- Delete: `k8s/infra/values/kube-prometheus-stack.yaml`

- [ ] **Step 1: Delete the file**

Run:
```bash
git rm k8s/infra/values/kube-prometheus-stack.yaml
```

- [ ] **Step 2: Verify nothing else references it**

Run:
```bash
grep -rn "kube-prometheus-stack.yaml" k8s/ Makefile scripts/ 2>/dev/null | grep -v "^Binary" || echo "no references"
```
Expected: prints `no references` (Task 3 already removed the install.sh reference).

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(k8s): remove kube-prometheus-stack values file"
```

---

## Task 5: Remove the 8 ServiceMonitors and their kustomization entries

The Prometheus Operator (and its `ServiceMonitor` CRD) is gone, so these CRs would fail to apply. VM's `spring-actuator` scrape job (Task 1) replaces them. The `management` Service port stays untouched — only the ServiceMonitor goes.

**Files (8 services):**
- Delete: `k8s/apps/base/{authorization-server,bff-service,gateway,inventory-service,orchestrator-service,order-service,payment-service,product-service}/servicemonitor.yaml`
- Modify: the matching `kustomization.yaml` in each (remove the `- servicemonitor.yaml` line)

- [ ] **Step 1: Delete the 8 servicemonitor.yaml files**

Run:
```bash
git rm \
  k8s/apps/base/authorization-server/servicemonitor.yaml \
  k8s/apps/base/bff-service/servicemonitor.yaml \
  k8s/apps/base/gateway/servicemonitor.yaml \
  k8s/apps/base/inventory-service/servicemonitor.yaml \
  k8s/apps/base/orchestrator-service/servicemonitor.yaml \
  k8s/apps/base/order-service/servicemonitor.yaml \
  k8s/apps/base/payment-service/servicemonitor.yaml \
  k8s/apps/base/product-service/servicemonitor.yaml
```

- [ ] **Step 2: Remove the `- servicemonitor.yaml` line from each kustomization**

For EACH of the 8 services, edit `k8s/apps/base/<svc>/kustomization.yaml` and delete the single line `  - servicemonitor.yaml` from its `resources:` list. Example for `product-service` — change:
```yaml
resources:
  - deployment.yaml
  - service.yaml
  - servicemonitor.yaml
  - hpa.yaml
```
to:
```yaml
resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml
```
Do the equivalent removal in the other 7 (`authorization-server`, `bff-service`, `gateway`, `inventory-service`, `orchestrator-service`, `order-service`, `payment-service`). Leave every other line as-is.

- [ ] **Step 3: Verify no kustomization still references it and all builds succeed**

Run:
```bash
grep -rn "servicemonitor.yaml" k8s/apps/base/ && echo "STILL REFERENCED — fix above" || echo "clean"
for d in authorization-server bff-service gateway inventory-service orchestrator-service order-service payment-service product-service; do
  kustomize build "k8s/apps/base/$d" >/dev/null && echo "$d build OK" || echo "$d BUILD FAILED"
done
```
Expected: `clean`, then `... build OK` for all 8. (If `kustomize` is absent, use `kubectl kustomize "k8s/apps/base/$d"`.)

- [ ] **Step 4: Confirm no ServiceMonitor kind remains in rendered apps**

Run:
```bash
for d in authorization-server bff-service gateway inventory-service orchestrator-service order-service payment-service product-service; do
  kustomize build "k8s/apps/base/$d" | grep -q "kind: ServiceMonitor" && echo "$d STILL HAS SM"; done; echo "checked"
```
Expected: only `checked` prints (no `STILL HAS SM` lines).

- [ ] **Step 5: Commit**

```bash
git add k8s/apps/base
git commit -m "refactor(k8s): drop ServiceMonitors — VM scrapes management port via endpoint SD"
```

---

## Task 6: Wire k6 remote-write into VictoriaMetrics

**Files:**
- Modify: `k8s/apps/base/k6-stress/job.yaml` (container `args` and `env`)

- [ ] **Step 1: Add the remote-write output flag**

In `k8s/apps/base/k6-stress/job.yaml`, change the container args from:
```yaml
          args: ["run", "/scripts/script.js"]
```
to:
```yaml
          args: ["run", "-o", "experimental-prometheus-rw", "/scripts/script.js"]
```

- [ ] **Step 2: Add the remote-write env vars**

In the same container's `env:` list (which already has `BASE_URL`), append:
```yaml
            # Stream k6 client metrics into VictoriaMetrics for the Grafana
            # k6 dashboard (grafana.com #19665). VM accepts Prometheus
            # remote-write natively at /api/v1/write.
            - { name: K6_PROMETHEUS_RW_SERVER_URL, value: "http://vmsingle.monitoring.svc.cluster.local:8428/api/v1/write" }
            - { name: K6_PROMETHEUS_RW_TREND_STATS, value: "p(95),p(99),avg,min,max" }
```

- [ ] **Step 3: Verify the kustomize build renders the new args/env**

Run:
```bash
kustomize build k8s/apps/base/k6-stress | grep -E "experimental-prometheus-rw|K6_PROMETHEUS_RW_SERVER_URL|api/v1/write"
```
Expected: all three strings appear in the rendered Job.

- [ ] **Step 4: Commit**

```bash
git add k8s/apps/base/k6-stress/job.yaml
git commit -m "feat(k8s): k6 remote-writes metrics to VictoriaMetrics"
```

---

## Task 7: Update k8s/CLAUDE.md monitoring section

**Files:**
- Modify: `k8s/CLAUDE.md` (monitoring / observability section)

- [ ] **Step 1: Locate the monitoring section**

Run:
```bash
grep -n "kube-prometheus\|kps\|Prometheus\|Grafana\|ServiceMonitor\|monitoring" k8s/CLAUDE.md
```
Use the line numbers to find the observability/monitoring section.

- [ ] **Step 2: Replace the kps description**

Update the monitoring section so it states:
- Observability is **VictoriaMetrics single-node + Grafana + kube-state-metrics** in the `monitoring` namespace (NOT kube-prometheus-stack — removed 2026-06-02).
- VM single-node is scraper + TSDB + remote-write receiver in one binary; values in `k8s/infra/values/victoria-metrics.yaml`; service DNS `vmsingle.monitoring.svc.cluster.local:8428`.
- Services are discovered by VM via Kubernetes endpoint SD on the **port name** `management` (number varies per service) — there are **no ServiceMonitors** anymore (the Operator is gone; applying a ServiceMonitor would fail with no CRD).
- Pod/node CPU/mem come from the **kubelet cAdvisor** scrape (no node-exporter); restarts/OOM from kube-state-metrics.
- k6 (`make k8s-stress`) remote-writes to VM; view it on Grafana dashboard #19665.
- Design rationale + the meltdown that motivated the switch: `docs/superpowers/specs/2026-06-02-victoriametrics-observability-design.md`.

Keep the existing prose style/length of the file. Remove any now-false claims about kps, the Operator, node-exporter, or the quay.io pre-pull.

- [ ] **Step 3: Verify no stale kps claims remain**

Run:
```bash
grep -n "kube-prometheus-stack\|node-exporter\|ServiceMonitor\|quay.io" k8s/CLAUDE.md || echo "no stale references"
```
Expected: either `no stale references`, or only lines that explicitly say these were *removed* (historical notes are fine; live instructions to use them are not).

- [ ] **Step 4: Commit**

```bash
git add k8s/CLAUDE.md
git commit -m "docs(k8s): document VictoriaMetrics observability, drop kps references"
```

---

## Task 8: Live integration verification (requires a running cluster)

This is the end-to-end test. It needs the cluster up. If it is not, bring it up first.

**Files:** none (verification only).

- [ ] **Step 1: Bring up / reconcile the cluster**

Run (whichever applies):
```bash
make k8s-up            # if cluster exists
# or, from scratch:
make k8s-bootstrap     # must complete WITHOUT the quay pre-pull and WITHOUT kps
```
Expected: completes with no quay.io pulls and no kps install step.

- [ ] **Step 2: Verify the monitoring namespace has exactly 3 app pods**

Run:
```bash
kubectl -n monitoring get pods
```
Expected: `vmsingle-*`, `grafana-*`, and `kube-state-metrics-*` all `Running`/`Ready`. No `*-prometheus-operator-*`, no `*-node-exporter-*`, no `alertmanager-*`.

- [ ] **Step 3: Verify VM scrape targets are up**

Run:
```bash
kubectl -n monitoring port-forward svc/vmsingle 8428:8428 >/tmp/pf-vm.log 2>&1 &
sleep 3
curl -s 'http://localhost:8428/api/v1/targets' | grep -o '"job":"[^"]*"' | sort | uniq -c
curl -s 'http://localhost:8428/api/v1/query?query=up' | grep -o '"job":"spring-actuator"' | wc -l
kill %1 2>/dev/null || true
```
Expected: the targets list includes `spring-actuator`, `kubelet-cadvisor`, and `kube-state-metrics`; the `up` query shows 8 `spring-actuator` series (one per service). If a service is scaled to 0 or not running, expect correspondingly fewer.

- [ ] **Step 4: Verify a JVM/Hikari metric is actually present**

Run:
```bash
kubectl -n monitoring port-forward svc/vmsingle 8428:8428 >/tmp/pf-vm.log 2>&1 &
sleep 3
curl -s 'http://localhost:8428/api/v1/query?query=jvm_memory_used_bytes' | grep -o '"app":"[^"]*"' | sort -u
curl -s 'http://localhost:8428/api/v1/query?query=hikaricp_connections' | grep -oc '"__name__"'
kill %1 2>/dev/null || true
```
Expected: `jvm_memory_used_bytes` returns series tagged with several `app` values; the Hikari query returns ≥1 series (proves the pool metric the design cares about is captured).

- [ ] **Step 5: Run k6 and confirm metrics land in VM + Grafana**

Run:
```bash
make k8s-stress
make k8s-stress-logs   # watch until the run finishes (ctrl-c to stop tailing)
```
Then query the k6 metric:
```bash
kubectl -n monitoring port-forward svc/vmsingle 8428:8428 >/tmp/pf-vm.log 2>&1 &
sleep 3
curl -s 'http://localhost:8428/api/v1/query?query=k6_http_reqs_total' | grep -o '"status":"success"'
kill %1 2>/dev/null || true
```
Expected: the k6 logs show the `output: Prometheus remote write` line on startup, and `k6_http_reqs_total` returns `"status":"success"` with data (k6 metrics reached VM).

- [ ] **Step 6: Confirm Grafana shows the dashboards**

Run:
```bash
kubectl -n monitoring port-forward svc/grafana 3000:80 >/tmp/pf-graf.log 2>&1 &
sleep 3
curl -s -u admin:admin 'http://localhost:3000/api/search?type=dash-db' | grep -o '"title":"[^"]*"'
kill %1 2>/dev/null || true
```
Expected: the four provisioned dashboards are listed (k6, JVM/Micrometer, Spring Boot 3.x, Kubernetes Pods). Optionally open `http://localhost:3000` (admin/admin) during a k6 run and confirm the k6 dashboard shows live RPS/latency.

- [ ] **Step 7: Record the memory win (optional but recommended)**

Run:
```bash
kubectl -n monitoring top pods
```
Expected: `vmsingle` well under 400Mi — materially lower than the old kps Prometheus footprint.

- [ ] **Step 8: Commit any fixups discovered during verification**

If Steps 1–7 surfaced a needed correction (wrong dashboard revision, scrape relabel typo, etc.), fix the relevant values/manifest file and commit:
```bash
git add -A && git commit -m "fix(k8s): correct <thing> found during VM observability verification"
```

---

## Self-review notes (for the implementer)

- **Spec coverage:** Task 1 → VM + scrape config (scopes: app/server, pod/node). Task 2 → Grafana + dashboards. Task 3/4 → install.sh + kps removal. Task 5 → ServiceMonitor migration. Task 6 → k6 remote-write (scope: k6 client). Task 7 → docs. Task 8 → all verification bullets from the spec.
- **No new node-exporter / Alertmanager** anywhere — consistent with "out of scope".
- **Port-name, not number:** the scrape relabel keeps `__meta_kubernetes_endpoint_port_name == management`; no management port number is hardcoded.
- **Service DNS name `vmsingle`** is used identically in Task 1 (`fullnameOverride: vmsingle`), Task 2 (datasource URL), Task 6 (k6 URL), and Task 8 (port-forward target).
