# Monitoring Dashboards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three broken community Grafana dashboards with three purpose-built VictoriaMetrics-backed dashboards (per-service JVM, Kafka, MySQL), and deploy the kafka-exporter + mysqld-exporter that the Kafka/MySQL dashboards depend on.

**Architecture:** Two new Prometheus exporters (`kafka-exporter`, `mysqld-exporter`) deployed as plain manifests in the `infra` namespace, scraped by the existing VictoriaMetrics single-node via two added `scrape_configs` (mirroring the existing `kube-state-metrics` job). Three hand-written Grafana dashboard JSON files live in `k8s/infra/dashboards/`, delivered to Grafana through an imperatively-created ConfigMap mounted under a new `custom` dashboard provider (so the working k6 gnetId dashboard under the `default` provider is untouched). HTTP latency percentiles are enabled once for all services via the shared `secret/ecommerce` Vault context.

**Tech Stack:** Kubernetes (kind), Helm (grafana chart 10.5.15), VictoriaMetrics single-node, `danielqsj/kafka-exporter`, `prom/mysqld-exporter`, Spring Boot Micrometer, Grafana dashboard JSON (schemaVersion 39).

**Spec:** `docs/superpowers/specs/2026-06-09-monitoring-dashboards-design.md`

---

## Conventions & environment notes (read once)

- **Cluster is already running** (verified). Test each task against the live cluster by applying the single manifest you changed — do **not** re-run `make k8s-bootstrap` per task (it's minutes-long). Full bootstrap is only the final acceptance check.
- **Standard VM query command** (run a throwaway curl pod in `monitoring`, self-deletes):
  ```bash
  kubectl run vmq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n monitoring --attach --rm -q --command -- \
    curl -s 'http://vmsingle:8428/api/v1/query?query=<URL-ENCODED-PROMQL>'
  ```
- **Standard exporter /metrics check** (throwaway pod in `infra`):
  ```bash
  kubectl run cq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n infra --attach --rm -q --command -- \
    curl -s 'http://<exporter-svc>:<port>/metrics'
  ```
- **Sandbox blocks (the human runs these via the `!` prefix, not the agent):** `git push`, PR create/merge, `rm`, **`kubectl exec` that writes to MySQL**, `vault kv patch`, `git branch -D`. The MySQL exporter uses the existing `root` account so **no** MySQL write-exec is needed for it. The only human-run step is the live Vault patch in Task 3 (a fresh bootstrap needs no patch).
- **MySQL topology:** primary `mysql-0` (Service `mysql:3306`), replicas `mysql-replica-0/1` (per-pod DNS `mysql-replica-{0,1}.mysql-replica-headless.infra.svc.cluster.local:3306`). Root password is `root` (Secret `mysql-credentials`, key `MYSQL_ROOT_PASSWORD`).
- **Kafka:** Service `kafka:9092` (named port `client`), single KRaft broker, PLAINTEXT.
- **No unit-test framework applies to YAML/JSON/Helm here.** Each task's "test" is a concrete verification command with expected output. Validate every JSON file with `jq . <file> >/dev/null` (parses = valid) before committing.
- **Commit discipline:** stage only the listed paths (never `git add -A`). End every commit message with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility |
|---|---|
| `k8s/infra/manifests/kafka-exporter.yaml` | kafka-exporter Deployment + Service (`:9308`) |
| `k8s/infra/manifests/mysqld-exporter.yaml` | 3 mysqld-exporter Deployments + Services (`:9104`, one per DB instance) + per-instance `.my.cnf` Secrets |
| `k8s/infra/values/victoria-metrics.yaml` | add `kafka-exporter` + `mysqld-exporter` scrape jobs |
| `k8s/infra/jobs/03-vault-seed/seed.sh` | add histogram property to the `ecommerce` common block |
| `k8s/infra/dashboards/jvm-services.json` | JVM dashboard (`$service`/`$pod` vars, 6+ rows) |
| `k8s/infra/dashboards/kafka.json` | Kafka dashboard (consumer-lag headline) |
| `k8s/infra/dashboards/mysql.json` | MySQL dashboard (replication-lag headline) |
| `k8s/infra/values/grafana.yaml` | remove 3 broken gnetId dashboards; add `custom` provider + `dashboardsConfigMaps` |
| `k8s/infra/install.sh` | apply both exporters; create the dashboards ConfigMap before the grafana install |

---

## Task 1: kafka-exporter (manifest + scrape + wire)

**Files:**
- Create: `k8s/infra/manifests/kafka-exporter.yaml`
- Modify: `k8s/infra/values/victoria-metrics.yaml` (append a scrape job)
- Modify: `k8s/infra/install.sh` (apply the manifest)

- [ ] **Step 1: Write the manifest**

Create `k8s/infra/manifests/kafka-exporter.yaml`:

```yaml
# kafka-exporter — exposes Kafka topic/partition offsets and consumer-group lag
# in Prometheus format on :9308. Connects to the single KRaft broker (kafka:9092,
# PLAINTEXT). The headline metric is kafka_consumergroup_lag (saga consumers
# keeping up). Replication metrics are degenerate at RF=1 (single broker).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-exporter
  namespace: infra
  labels:
    app.kubernetes.io/name: kafka-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: kafka-exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kafka-exporter
    spec:
      # cp-* style env injection is irrelevant here, but keep service-link noise off.
      enableServiceLinks: false
      containers:
        - name: kafka-exporter
          image: danielqsj/kafka-exporter:v1.8.0
          args:
            - --kafka.server=kafka:9092
            - --web.listen-address=:9308
          ports:
            - name: metrics
              containerPort: 9308
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-exporter
  namespace: infra
  labels:
    app.kubernetes.io/name: kafka-exporter
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: kafka-exporter
  ports:
    - name: metrics
      port: 9308
      targetPort: metrics
```

- [ ] **Step 2: Apply and verify the exporter scrapes Kafka**

```bash
kubectl apply -f k8s/infra/manifests/kafka-exporter.yaml
kubectl -n infra rollout status deployment/kafka-exporter --timeout=2m
kubectl run cq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n infra --attach --rm -q --command -- \
  curl -s http://kafka-exporter:9308/metrics | grep -E '^kafka_brokers|^kafka_topic_partitions'
```
Expected: at least `kafka_brokers 1` and one or more `kafka_topic_partitions{...}` lines.

- [ ] **Step 3: Add the VictoriaMetrics scrape job**

In `k8s/infra/values/victoria-metrics.yaml`, under `server.scrape.config.scrape_configs:`, append after the `kube-state-metrics` job (keep the existing two-space list indentation):

```yaml
        # 4. kafka-exporter — topic offsets + consumer-group lag (infra ns).
        - job_name: kafka-exporter
          static_configs:
            - targets: [kafka-exporter.infra.svc.cluster.local:9308]
```

- [ ] **Step 4: Apply the VM values and verify VM stores the metric**

```bash
helm upgrade --install vmsingle vm/victoria-metrics-single \
  --namespace monitoring --version 0.39.0 \
  -f k8s/infra/values/victoria-metrics.yaml --wait --timeout 5m
# scrape_interval is 15s; give it one cycle.
sleep 20
kubectl run vmq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n monitoring --attach --rm -q --command -- \
  curl -s 'http://vmsingle:8428/api/v1/query?query=kafka_brokers'
```
Expected: JSON `"status":"success"` with a non-empty `result` array containing a `kafka_brokers` sample valued `"1"`.

- [ ] **Step 5: Wire into install.sh**

In `k8s/infra/install.sh`, find the stateful-manifests `kubectl apply` block (the one ending `-f "$MANIFESTS/kafka.yaml"`) and add the exporter to it by appending one line:

```bash
  -f "$MANIFESTS/kafka.yaml" \
  -f "$MANIFESTS/kafka-exporter.yaml"
```
Then add a rollout wait next to the other infra waits (after `rollout status statefulset/kafka`):

```bash
kubectl -n infra rollout status deployment/kafka-exporter --timeout=2m
```

- [ ] **Step 6: Commit**

```bash
git add k8s/infra/manifests/kafka-exporter.yaml k8s/infra/values/victoria-metrics.yaml k8s/infra/install.sh
git commit -m "feat(monitoring): kafka-exporter + VM scrape job

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: mysqld-exporter (3 instances: primary + 2 replicas)

**Files:**
- Create: `k8s/infra/manifests/mysqld-exporter.yaml`
- Modify: `k8s/infra/values/victoria-metrics.yaml` (append a scrape job with 3 targets)
- Modify: `k8s/infra/install.sh` (apply the manifest)

**Why 3 exporters:** `mysql_slave_status_seconds_behind_master` is reported by each replica about *itself*; only by scraping each replica do you get its lag. Each exporter authenticates as `root` (acceptable for local dev; the Secret already holds the password) via a `.my.cnf` — `mysqld-exporter` v0.15+ dropped `DATA_SOURCE_NAME` in favour of `--config.my-cnf`.

- [ ] **Step 1: Write the manifest**

Create `k8s/infra/manifests/mysqld-exporter.yaml`. Three near-identical Deployment+Service+Secret triples, one per DB host. The `.my.cnf` `host` differs per instance; everything else is identical.

```yaml
# mysqld-exporter — one process per MySQL instance (primary + 2 replicas) so
# each replica's seconds_behind_master is collected. v0.15+: credentials come
# from a mounted .my.cnf ([client] section), NOT DATA_SOURCE_NAME. Uses root
# (local-dev only). VM scrapes each Service; the scrape job relabels `instance`
# to a friendly name.
#
# ---- PRIMARY ----
apiVersion: v1
kind: Secret
metadata:
  name: mysqld-exporter-primary-cnf
  namespace: infra
type: Opaque
stringData:
  .my.cnf: |
    [client]
    user=root
    password=root
    host=mysql.infra.svc.cluster.local
    port=3306
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysqld-exporter-primary
  namespace: infra
  labels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: primary }
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: primary }
  template:
    metadata:
      labels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: primary }
    spec:
      enableServiceLinks: false
      containers:
        - name: mysqld-exporter
          image: prom/mysqld-exporter:v0.16.0
          args:
            - --config.my-cnf=/cfg/.my.cnf
            - --web.listen-address=:9104
            # replication lag + status come from these collectors:
            - --collect.slave_status
            - --collect.global_status
            - --collect.global_variables
            - --collect.info_schema.innodb_metrics
          ports:
            - { name: metrics, containerPort: 9104 }
          volumeMounts:
            - { name: cfg, mountPath: /cfg, readOnly: true }
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
      volumes:
        - name: cfg
          secret:
            secretName: mysqld-exporter-primary-cnf
---
apiVersion: v1
kind: Service
metadata:
  name: mysqld-exporter-primary
  namespace: infra
  labels: { app.kubernetes.io/name: mysqld-exporter }
spec:
  type: ClusterIP
  selector: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: primary }
  ports:
    - { name: metrics, port: 9104, targetPort: metrics }
---
# ---- REPLICA 0 ----
apiVersion: v1
kind: Secret
metadata:
  name: mysqld-exporter-replica-0-cnf
  namespace: infra
type: Opaque
stringData:
  .my.cnf: |
    [client]
    user=root
    password=root
    host=mysql-replica-0.mysql-replica-headless.infra.svc.cluster.local
    port=3306
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysqld-exporter-replica-0
  namespace: infra
  labels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: replica-0 }
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: replica-0 }
  template:
    metadata:
      labels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: replica-0 }
    spec:
      enableServiceLinks: false
      containers:
        - name: mysqld-exporter
          image: prom/mysqld-exporter:v0.16.0
          args:
            - --config.my-cnf=/cfg/.my.cnf
            - --web.listen-address=:9104
            - --collect.slave_status
            - --collect.global_status
            - --collect.global_variables
            - --collect.info_schema.innodb_metrics
          ports:
            - { name: metrics, containerPort: 9104 }
          volumeMounts:
            - { name: cfg, mountPath: /cfg, readOnly: true }
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
      volumes:
        - name: cfg
          secret:
            secretName: mysqld-exporter-replica-0-cnf
---
apiVersion: v1
kind: Service
metadata:
  name: mysqld-exporter-replica-0
  namespace: infra
  labels: { app.kubernetes.io/name: mysqld-exporter }
spec:
  type: ClusterIP
  selector: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: replica-0 }
  ports:
    - { name: metrics, port: 9104, targetPort: metrics }
---
# ---- REPLICA 1 ----
apiVersion: v1
kind: Secret
metadata:
  name: mysqld-exporter-replica-1-cnf
  namespace: infra
type: Opaque
stringData:
  .my.cnf: |
    [client]
    user=root
    password=root
    host=mysql-replica-1.mysql-replica-headless.infra.svc.cluster.local
    port=3306
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysqld-exporter-replica-1
  namespace: infra
  labels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: replica-1 }
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: replica-1 }
  template:
    metadata:
      labels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: replica-1 }
    spec:
      enableServiceLinks: false
      containers:
        - name: mysqld-exporter
          image: prom/mysqld-exporter:v0.16.0
          args:
            - --config.my-cnf=/cfg/.my.cnf
            - --web.listen-address=:9104
            - --collect.slave_status
            - --collect.global_status
            - --collect.global_variables
            - --collect.info_schema.innodb_metrics
          ports:
            - { name: metrics, containerPort: 9104 }
          volumeMounts:
            - { name: cfg, mountPath: /cfg, readOnly: true }
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
      volumes:
        - name: cfg
          secret:
            secretName: mysqld-exporter-replica-1-cnf
---
apiVersion: v1
kind: Service
metadata:
  name: mysqld-exporter-replica-1
  namespace: infra
  labels: { app.kubernetes.io/name: mysqld-exporter }
spec:
  type: ClusterIP
  selector: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: replica-1 }
  ports:
    - { name: metrics, port: 9104, targetPort: metrics }
```

- [ ] **Step 2: Apply and verify all three connect**

```bash
kubectl apply -f k8s/infra/manifests/mysqld-exporter.yaml
kubectl -n infra rollout status deployment/mysqld-exporter-primary   --timeout=2m
kubectl -n infra rollout status deployment/mysqld-exporter-replica-0 --timeout=2m
kubectl -n infra rollout status deployment/mysqld-exporter-replica-1 --timeout=2m
for inst in primary replica-0 replica-1; do
  echo "== $inst =="
  kubectl run cq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n infra --attach --rm -q --command -- \
    curl -s http://mysqld-exporter-$inst:9104/metrics | grep -E '^mysql_up '
done
```
Expected: `mysql_up 1` for each of the three.

- [ ] **Step 3: Add the VM scrape job (3 targets, friendly `instance` label)**

In `k8s/infra/values/victoria-metrics.yaml`, append after the `kafka-exporter` job:

```yaml
        # 5. mysqld-exporter — one target per DB instance; relabel to a friendly
        #    `instance` (primary / replica-0 / replica-1) for the dashboard var.
        - job_name: mysqld-exporter
          static_configs:
            - targets: [mysqld-exporter-primary.infra.svc.cluster.local:9104]
              labels: { instance: primary }
            - targets: [mysqld-exporter-replica-0.infra.svc.cluster.local:9104]
              labels: { instance: replica-0 }
            - targets: [mysqld-exporter-replica-1.infra.svc.cluster.local:9104]
              labels: { instance: replica-1 }
```

- [ ] **Step 4: Apply VM values and verify lag is collected per replica**

```bash
helm upgrade --install vmsingle vm/victoria-metrics-single \
  --namespace monitoring --version 0.39.0 \
  -f k8s/infra/values/victoria-metrics.yaml --wait --timeout 5m
sleep 20
kubectl run vmq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n monitoring --attach --rm -q --command -- \
  curl -s 'http://vmsingle:8428/api/v1/query?query=mysql_up'
kubectl run vmq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n monitoring --attach --rm -q --command -- \
  curl -s 'http://vmsingle:8428/api/v1/query?query=mysql_slave_status_seconds_behind_master'
```
Expected: first query returns 3 samples with `instance` = primary/replica-0/replica-1 each `"1"`; second returns 2 samples (replicas only) with small lag values.

- [ ] **Step 5: Wire into install.sh**

Append to the same stateful-manifests `kubectl apply` block:

```bash
  -f "$MANIFESTS/kafka-exporter.yaml" \
  -f "$MANIFESTS/mysqld-exporter.yaml"
```
And after the `kafka-exporter` rollout wait add:

```bash
kubectl -n infra rollout status deployment/mysqld-exporter-primary   --timeout=2m
kubectl -n infra rollout status deployment/mysqld-exporter-replica-0 --timeout=2m
kubectl -n infra rollout status deployment/mysqld-exporter-replica-1 --timeout=2m
```
Place these **after** the "MySQL replication ready" echo so the replicas exist before their exporters start.

- [ ] **Step 6: Commit**

```bash
git add k8s/infra/manifests/mysqld-exporter.yaml k8s/infra/values/victoria-metrics.yaml k8s/infra/install.sh
git commit -m "feat(monitoring): mysqld-exporter per DB instance + VM scrape job

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Enable HTTP percentile histograms (shared Vault context)

**Files:**
- Modify: `k8s/infra/jobs/03-vault-seed/seed.sh` (add one key to the `ecommerce` common block)

**Why here:** all services set `spring.cloud.vault.kv.default-context: ecommerce`, so a key in `secret/ecommerce` applies to every service. Spring Cloud Vault properties override `application.yml`. This makes Micrometer publish `http_server_requests_seconds_bucket` (the `le`-bucketed histogram `histogram_quantile()` needs for real p95/p99).

- [ ] **Step 1: Add the property to the common block**

In `k8s/infra/jobs/03-vault-seed/seed.sh`, find the `put_if_missing ecommerce \` block and add this key (match the existing `key=value \` line style inside that block):

```bash
  management.metrics.distribution.percentiles-histogram.http.server.requests=true \
```

- [ ] **Step 2: (Fresh cluster) verify via reseed — OR (running cluster) live-patch**

`put_if_missing` is a **no-op when the path already exists** (documented scar). The seed.sh edit only takes effect on a *fresh* `secret/ecommerce`. For the **currently running** cluster, the human must patch Vault live and restart the services (these two commands; the agent cannot run `vault kv patch`):

```bash
# HUMAN runs (vault kv patch is sandbox-blocked for the agent):
kubectl -n infra exec vault-0 -- vault kv patch secret/ecommerce \
  management.metrics.distribution.percentiles-histogram.http.server.requests=true
# then restart services so they re-read Vault at boot:
kubectl -n apps rollout restart deployment   # all app deployments
```

- [ ] **Step 3: Verify the histogram buckets now exist**

After restart (or fresh bootstrap), confirm one service exposes bucketed series:

```bash
sleep 30
kubectl run vmq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n monitoring --attach --rm -q --command -- \
  curl -s 'http://vmsingle:8428/api/v1/query?query=count(http_server_requests_seconds_bucket)'
```
Expected: `"status":"success"` with a non-empty `result` (a positive count). If the result is empty, the property didn't propagate — confirm the Vault patch landed (`vault kv get secret/ecommerce`) and the pods restarted.

- [ ] **Step 4: Commit**

```bash
git add k8s/infra/jobs/03-vault-seed/seed.sh
git commit -m "feat(monitoring): enable HTTP percentile histograms via shared Vault context

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Dashboard JSON conventions (Tasks 4–6)

All three dashboards share this structure. Build each as a Grafana dashboard JSON (`schemaVersion: 39`), datasource VictoriaMetrics. Because full dashboards are large, each task gives: (a) the templating + skeleton, (b) **one fully-worked example panel** to fix the pattern, and (c) a **panel table** (title · type · PromQL · unit) for the remaining panels. The implementer renders each table row into a panel object matching the example, laying panels out in rows (`gridPos` width 12, height 8, two per row; row headers are `type: "row"` panels).

**Datasource reference:** Grafana resolves the provisioned VictoriaMetrics datasource by type. Use `"datasource": {"type": "prometheus", "uid": "${DS_VICTORIAMETRICS}"}` and include a `__inputs`-free templating list variable `datasource` of type `datasource`, query `prometheus`, named `DS_VICTORIAMETRICS`, current = VictoriaMetrics. (This is the standard portable form; it binds to the single provisioned Prometheus-type datasource.)

**Validation for every dashboard task:** `jq . <file> >/dev/null && echo VALID`. After wiring (Task 7) the panels are verified live; within Tasks 4–6 verify each panel's **query** returns data using the standard VM query command before considering the panel done.

---

## Task 4: JVM dashboard (`jvm-services.json`)

**Files:**
- Create: `k8s/infra/dashboards/jvm-services.json`

- [ ] **Step 1: Verify the underlying queries return data** (do this first so you build against real series)

Run the standard VM query for each (URL-encode):
- `jvm_memory_used_bytes{area="heap"}` → expect samples labeled `app`, `pod`.
- `label_values` proxy: `count by (app) (jvm_memory_used_bytes)` → expect ~9 apps.
- `jvm_gc_memory_promoted_bytes_total` → expect samples (may be 0 early).

Expected: each returns `"status":"success"` with non-empty results. (If `http_server_requests_seconds_bucket` is still empty, Task 3 hasn't propagated — finish Task 3 first; the p95/p99 panel depends on it.)

- [ ] **Step 2: Write the dashboard skeleton + templating**

Create `k8s/infra/dashboards/jvm-services.json` with this head (panels array filled in Step 3):

```json
{
  "title": "JVM (per service)",
  "uid": "jvm-services",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "time": { "from": "now-30m", "to": "now" },
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "DS_VICTORIAMETRICS",
        "type": "datasource",
        "query": "prometheus",
        "current": { "text": "VictoriaMetrics", "value": "VictoriaMetrics" },
        "hide": 0
      },
      {
        "name": "service",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "${DS_VICTORIAMETRICS}" },
        "query": "label_values(jvm_memory_used_bytes, app)",
        "includeAll": true,
        "multi": true,
        "current": { "text": "All", "value": "$__all" },
        "refresh": 2
      },
      {
        "name": "pod",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "${DS_VICTORIAMETRICS}" },
        "query": "label_values(jvm_memory_used_bytes{app=~\"$service\"}, pod)",
        "includeAll": true,
        "multi": true,
        "current": { "text": "All", "value": "$__all" },
        "refresh": 2
      }
    ]
  },
  "panels": []
}
```

- [ ] **Step 3: Add the panels (one example + table)**

**Fully-worked example panel** (row 3b, "Old gen occupancy" timeseries) — every other panel is an object of this shape with its own `title`, `id`, `gridPos`, `expr`, and `unit`:

```json
{
  "id": 31,
  "type": "timeseries",
  "title": "Old gen occupancy",
  "datasource": { "type": "prometheus", "uid": "${DS_VICTORIAMETRICS}" },
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
  "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] },
  "targets": [
    {
      "datasource": { "type": "prometheus", "uid": "${DS_VICTORIAMETRICS}" },
      "expr": "jvm_memory_used_bytes{app=~\"$service\", pod=~\"$pod\", id=~\".*Old.*|.*Tenured.*\"}",
      "legendFormat": "{{app}} / {{pod}}"
    }
  ]
}
```

Build the remaining panels from this table (all `expr` carry the `{app=~"$service", pod=~"$pod"}` selector unless noted; type `timeseries` unless noted; add `type: "row"` header panels for each numbered row):

| Row | Panel | Type | PromQL `expr` | unit |
|---|---|---|---|---|
| 1 Alive | Instances up | stat | `count(up{job="spring-actuator", app=~"$service"})` | none |
| 1 | Uptime | stat | `process_uptime_seconds{app=~"$service", pod=~"$pod"}` | s |
| 1 | Restarts (1h) | stat | `increase(kube_pod_container_status_restarts_total{namespace="apps", pod=~"$pod"}[1h])` | none |
| 1 | Process CPU | gauge | `process_cpu_usage{app=~"$service", pod=~"$pod"}` | percentunit |
| 2 CPU | JVM vs system CPU | timeseries | A: `process_cpu_usage{…}` · B: `system_cpu_usage{…}` | percentunit |
| 2 | Load avg ÷ cores | timeseries | `system_load_average_1m{…} / system_cpu_count{…}` | none |
| 3a Mem | Heap used vs max | timeseries | A: `sum by (pod)(jvm_memory_used_bytes{area="heap", …})` · B: `jvm_memory_max_bytes{area="heap", …}` | bytes |
| 3a | Non-heap / Metaspace | timeseries | `jvm_memory_used_bytes{area="nonheap", …}` | bytes |
| 3b Gen | Eden occupancy | timeseries | `jvm_memory_used_bytes{id=~".*Eden.*", …}` | bytes |
| 3b | Survivor occupancy | timeseries | `jvm_memory_used_bytes{id=~".*Survivor.*", …}` | bytes |
| 3b | Old gen occupancy | timeseries | *(example above)* | bytes |
| 3b | Allocation rate | timeseries | `rate(jvm_gc_memory_allocated_bytes_total{…}[5m])` | Bps |
| 3b | Promotion rate (young→Old) | timeseries | `rate(jvm_gc_memory_promoted_bytes_total{…}[5m])` | Bps |
| 4 GC | GC pause rate by action | timeseries | `rate(jvm_gc_pause_seconds_count{…}[5m])`, legend `{{action}}` | ops |
| 4 | GC avg pause | timeseries | `rate(jvm_gc_pause_seconds_sum{…}[5m]) / rate(jvm_gc_pause_seconds_count{…}[5m])`, legend `{{action}}` | s |
| 4 | GC max pause | timeseries | `jvm_gc_pause_seconds_max{…}`, legend `{{action}}` | s |
| 5 Threads | Live / daemon / peak | timeseries | A: `jvm_threads_live_threads{…}` B: `jvm_threads_daemon_threads{…}` C: `jvm_threads_peak_threads{…}` | short |
| 5 | Thread states | timeseries | `jvm_threads_states_threads{…}`, legend `{{state}}` | short |
| 6 HTTP | Request rate by status | timeseries | `sum by (status)(rate(http_server_requests_seconds_count{app=~"$service"}[5m]))` | reqps |
| 6 | Error ratio (5xx) | timeseries | `sum(rate(http_server_requests_seconds_count{app=~"$service", status=~"5.."}[5m])) / sum(rate(http_server_requests_seconds_count{app=~"$service"}[5m]))` | percentunit |
| 6 | Latency p95 / p99 | timeseries | A: `histogram_quantile(0.95, sum by (le)(rate(http_server_requests_seconds_bucket{app=~"$service"}[5m])))` · B: `0.99` | s |

- [ ] **Step 4: Validate JSON**

```bash
jq . k8s/infra/dashboards/jvm-services.json >/dev/null && echo VALID
```
Expected: `VALID`.

- [ ] **Step 5: Commit**

```bash
git add k8s/infra/dashboards/jvm-services.json
git commit -m "feat(monitoring): JVM per-service dashboard (heap/gen/GC/threads/RED)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Kafka dashboard (`kafka.json`)

**Files:**
- Create: `k8s/infra/dashboards/kafka.json`

- [ ] **Step 1: Verify queries return data**

Standard VM query for `kafka_brokers`, `kafka_consumergroup_lag` (may be empty if no consumer groups have committed yet — drive a little traffic or accept empty until load), `kafka_topic_partition_current_offset`. Expect success; `kafka_brokers` non-empty.

- [ ] **Step 2: Write skeleton + templating**

Create `k8s/infra/dashboards/kafka.json` with the same head shape as Task 4 (title `"Kafka"`, uid `"kafka"`), and one template variable besides `DS_VICTORIAMETRICS`:

```json
{
  "name": "consumergroup",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "${DS_VICTORIAMETRICS}" },
  "query": "label_values(kafka_consumergroup_lag, consumergroup)",
  "includeAll": true,
  "multi": true,
  "current": { "text": "All", "value": "$__all" },
  "refresh": 2
}
```

- [ ] **Step 3: Add panels (table)**

Same panel shape as Task 4's example. `type: "row"` headers per numbered row.

| Row | Panel | Type | PromQL `expr` | unit |
|---|---|---|---|---|
| 1 Cluster | Brokers up | stat | `kafka_brokers` | none |
| 1 | Topics | stat | `count(count by (topic)(kafka_topic_partitions))` | none |
| 1 | Partitions | stat | `sum(kafka_topic_partitions)` | none |
| 2 Lag | Total lag by group/topic | timeseries | `sum by (consumergroup, topic)(kafka_consumergroup_lag{consumergroup=~"$consumergroup"})` | short |
| 2 | Top lagging (table) | table | `topk(20, kafka_consumergroup_lag{consumergroup=~"$consumergroup"})` (instant) | short |
| 2 | Lag over time | timeseries | `sum by (consumergroup)(kafka_consumergroup_lag{consumergroup=~"$consumergroup"})` | short |
| 3 Throughput | Produce rate by topic | timeseries | `sum by (topic)(rate(kafka_topic_partition_current_offset[5m]))` | ops |
| 3 | Consume rate by group | timeseries | `sum by (consumergroup)(rate(kafka_consumergroup_current_offset{consumergroup=~"$consumergroup"}[5m]))` | ops |
| 4 Topic | Partitions per topic | table | `kafka_topic_partitions` (instant) | none |
| 4 | Retained backlog | timeseries | `sum by (topic)(kafka_topic_partition_current_offset - kafka_topic_partition_oldest_offset)` | short |
| 5 Repl (caveat) | Under-replicated | stat | `sum(kafka_topic_partition_under_replicated_partition)` | none |
| 5 | In-sync replicas | timeseries | `kafka_topic_partition_in_sync_replica` | none |

Add a text panel in row 5 noting "RF=1 single broker — replication metrics are degenerate locally; kept to show what to watch in prod."

- [ ] **Step 4: Validate + Step 5: Commit**

```bash
jq . k8s/infra/dashboards/kafka.json >/dev/null && echo VALID
git add k8s/infra/dashboards/kafka.json
git commit -m "feat(monitoring): Kafka dashboard (consumer-lag, throughput, backlog)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: MySQL dashboard (`mysql.json`)

**Files:**
- Create: `k8s/infra/dashboards/mysql.json`

- [ ] **Step 1: Verify queries return data**

Standard VM query for `mysql_up` (3 instances), `mysql_global_status_threads_connected`, `mysql_slave_status_seconds_behind_master` (2 replicas), `mysql_global_status_innodb_buffer_pool_read_requests`. Expect success and the instance counts noted.

- [ ] **Step 2: Write skeleton + templating**

Create `k8s/infra/dashboards/mysql.json` (title `"MySQL"`, uid `"mysql"`) with one variable besides `DS_VICTORIAMETRICS`:

```json
{
  "name": "instance",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "${DS_VICTORIAMETRICS}" },
  "query": "label_values(mysql_up, instance)",
  "includeAll": true,
  "multi": true,
  "current": { "text": "All", "value": "$__all" },
  "refresh": 2
}
```

- [ ] **Step 3: Add panels (table)** — all `expr` carry `{instance=~"$instance"}`:

| Row | Panel | Type | PromQL `expr` | unit |
|---|---|---|---|---|
| 1 Up | mysql_up | stat | `mysql_up{instance=~"$instance"}` | none |
| 1 | Uptime | stat | `mysql_global_status_uptime{instance=~"$instance"}` | s |
| 2 Conn | Threads connected/running | timeseries | A: `mysql_global_status_threads_connected{…}` B: `mysql_global_status_threads_running{…}` | short |
| 2 | Conn saturation | timeseries | `mysql_global_status_max_used_connections{…} / mysql_global_variables_max_connections{…}` | percentunit |
| 3 QPS | Questions/s | timeseries | `rate(mysql_global_status_questions{…}[5m])` | ops |
| 3 | Read/write mix | timeseries | `rate(mysql_global_status_commands_total{command=~"select|insert|update|delete", …}[5m])`, legend `{{command}}` | ops |
| 4 InnoDB | Buffer pool hit ratio | timeseries | `1 - rate(mysql_global_status_innodb_buffer_pool_reads{…}[5m]) / rate(mysql_global_status_innodb_buffer_pool_read_requests{…}[5m])` | percentunit |
| 4 | Buffer pool pages | timeseries | `mysql_global_status_buffer_pool_pages{…}`, legend `{{state}}` | short |
| 5 Locks | Row lock waits/s | timeseries | `rate(mysql_global_status_innodb_row_lock_waits{…}[5m])` | ops |
| 5 | Row lock time | timeseries | `rate(mysql_global_status_innodb_row_lock_time{…}[5m])` | ms |
| 5 | Current lock waits | timeseries | `mysql_global_status_innodb_row_lock_current_waits{…}` | short |
| 6 Repl | Seconds behind master | timeseries | `mysql_slave_status_seconds_behind_master{instance=~"$instance"}` | s |
| 6 | IO/SQL thread running | timeseries | A: `mysql_slave_status_slave_io_running{…}` B: `mysql_slave_status_slave_sql_running{…}` | none |
| 7 Errors | Slow queries/s | timeseries | `rate(mysql_global_status_slow_queries{…}[5m])` | ops |
| 7 | Aborted connects/s | timeseries | `rate(mysql_global_status_aborted_connects{…}[5m])` | ops |

> Note on metric names: confirm exact series names against the live exporter output from Task 2 Step 2 (`curl …/metrics`). `prom/mysqld-exporter` v0.16 uses `mysql_global_status_commands_total{command=...}` for per-command counts and `mysql_global_status_buffer_pool_pages{state=...}`; if a name differs in the live output, use the live name.

- [ ] **Step 4: Validate + Step 5: Commit**

```bash
jq . k8s/infra/dashboards/mysql.json >/dev/null && echo VALID
git add k8s/infra/dashboards/mysql.json
git commit -m "feat(monitoring): MySQL dashboard (conn/QPS/innodb/locks/replication-lag)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Grafana provisioning (remove broken dashboards, mount custom dashboards) + end-to-end verify

**Files:**
- Modify: `k8s/infra/values/grafana.yaml`
- Modify: `k8s/infra/install.sh`

**Provider-collision resolution (spec §6.4 footgun):** the grafana chart mounts `dashboardsConfigMaps.<provider>` at the *same* path as `dashboards.<provider>` (`/var/lib/grafana/dashboards/<provider>`). Two volumes can't share one mount path, so put our ConfigMap under a **new `custom` provider** with its own folder, leaving the working k6 gnetId dashboard under `default`.

- [ ] **Step 1: Edit grafana.yaml — remove broken dashboards, add custom provider + configmap mount**

In `k8s/infra/values/grafana.yaml`:

(a) In `dashboardProviders.dashboardproviders.yaml.providers`, add a second provider after the `default` one:

```yaml
      - name: custom
        orgId: 1
        folder: "Custom"
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/custom
```

(b) In the `dashboards:` block, **delete** the `jvm-micrometer`, `spring-boot-3`, and `k8s-pods` entries (keep `k6`). Result:

```yaml
dashboards:
  default:
    k6:
      gnetId: 19665
      revision: 3
      datasource: VictoriaMetrics
```

(c) Add a top-level `dashboardsConfigMaps` key (references the ConfigMap created in Step 2):

```yaml
dashboardsConfigMaps:
  custom: grafana-custom-dashboards
```

- [ ] **Step 2: Edit install.sh — create the ConfigMap before the grafana install**

In `k8s/infra/install.sh`, **immediately before** the `helm upgrade --install grafana ...` line, insert:

```bash
# Custom dashboards (JVM/Kafka/MySQL) → ConfigMap mounted by Grafana's `custom`
# provider. Created imperatively from the JSON files (kubectl's embedded
# kustomize forbids out-of-tree file refs; same pattern as the seed Jobs).
# Must exist before the grafana pod starts (the chart mounts it as a volume).
kubectl create configmap grafana-custom-dashboards \
  --namespace monitoring \
  --from-file=k8s/infra/dashboards/ \
  --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 3: Apply and verify all three dashboards register with data**

```bash
kubectl create configmap grafana-custom-dashboards -n monitoring \
  --from-file=k8s/infra/dashboards/ --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --version 10.5.15 \
  -f k8s/infra/values/grafana.yaml --wait --timeout 5m
kubectl -n monitoring rollout status deployment/grafana --timeout=3m
# Grafana's provisioner polls the folder; give it a moment, then list dashboards:
sleep 15
kubectl run gq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n monitoring --attach --rm -q --command -- \
  curl -s -u admin:admin 'http://grafana/api/search?query=' | grep -oE '"title":"[^"]+"'
```
Expected: output includes `"title":"JVM (per service)"`, `"title":"Kafka"`, `"title":"MySQL"`, and `"title":"k6 ..."`; the three broken titles are gone.

- [ ] **Step 4: Spot-check a panel renders data through Grafana's datasource proxy**

```bash
kubectl run gq-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n monitoring --attach --rm -q --command -- \
  curl -s -u admin:admin -G 'http://grafana/api/datasources/proxy/uid/'"$(
    kubectl run gq2-$RANDOM --restart=Never --image=curlimages/curl:8.10.1 -n monitoring --attach --rm -q --command -- \
    curl -s -u admin:admin 'http://grafana/api/datasources' | grep -oE '"uid":"[^"]+"' | head -1 | cut -d'"' -f4
  )"'/api/v1/query' --data-urlencode 'query=mysql_up'
```
Expected: `"status":"success"` with `mysql_up` samples — confirming Grafana → VictoriaMetrics works for the new dashboards' datasource. (If this nested form is awkward in your shell, equivalently open `http://grafana.microecom.local` in a browser and confirm the three dashboards render.)

- [ ] **Step 5: Commit**

```bash
git add k8s/infra/values/grafana.yaml k8s/infra/install.sh
git commit -m "feat(monitoring): provision custom dashboards, drop 3 broken gnetId boards

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final acceptance (after all tasks)

- [ ] `kubectl -n monitoring get cm grafana-custom-dashboards` shows the 3 JSON keys.
- [ ] Grafana `/api/search` lists JVM/Kafka/MySQL + k6; the 3 broken titles are absent.
- [ ] JVM dashboard: `$service`/`$pod` dropdowns populate; heap, generational (Eden/Survivor/Old + alloc/promotion), GC split, threads, and RED rows show data; p95/p99 panel non-empty (Task 3 propagated).
- [ ] Kafka dashboard: brokers/throughput populate; consumer-lag reacts to a `make k8s-storefront-smoke` run.
- [ ] MySQL dashboard: connections, QPS, buffer-pool, locks populate for all 3 instances; `seconds_behind_master` shows for both replicas.
- [ ] Optional clean-room: `make k8s-down && make k8s-bootstrap` brings up exporters + dashboards with no manual step (except the histogram property, which a fresh bootstrap seeds automatically via Task 3).
```
