# Monitoring Dashboards — Design

**Status:** approved (2026-06-09)
**Goal:** Replace the three broken community Grafana dashboards with three purpose-built, learning-oriented dashboards backed by VictoriaMetrics: per-service JVM health, Kafka, and MySQL. Add the two exporters Kafka/MySQL need to expose real internals.

Companions: [`../../load-test-model-and-capacity.md`](../../load-test-model-and-capacity.md), [`../../stress-test-monitoring.md`](../../stress-test-monitoring.md), [`2026-06-02-victoriametrics-observability-design.md`](2026-06-02-victoriametrics-observability-design.md).

---

## 1. Problem

Grafana provisions four community dashboards by `gnetId` (`k8s/infra/values/grafana.yaml`). Only **k6 (19665)** renders. The other three — **JVM Micrometer (4701)**, **Spring Boot 3.x (19004)**, **k8s Pods (15760)** — show empty/broken panels.

**Root cause:** community dashboards hardcode label/job conventions (`job=`, `instance=`, `application=` template variables). This cluster's VictoriaMetrics scraper relabels every Spring target to `app` / `namespace` / `pod` under job `spring-actuator` (see `victoria-metrics.yaml`), so the imported dashboards' PromQL matches no series. They are unfixable without rewriting their queries — at which point a purpose-built dashboard is cleaner.

**Secondary gap:** Kafka and MySQL expose **no** Prometheus metrics today (no JMX/kafka-exporter on the broker, no mysqld-exporter on the databases). VictoriaMetrics only scrapes Micrometer (`/actuator/prometheus`), kubelet cAdvisor, and kube-state-metrics. So "monitor Kafka/MySQL" is impossible beyond container CPU/mem until exporters exist.

## 2. Decisions (locked)

| Decision | Choice |
|---|---|
| Kafka/MySQL internals | **Add both exporters** — `kafka-exporter` + `mysqld-exporter` |
| JVM dashboard layout | **One dashboard** with `$service` + `$pod` template variables (dropdown) |
| Generational GC view | **Included** — Eden/Survivor/Old occupancy + allocation & promotion rates + minor/major GC split |
| HTTP latency percentiles | **Enable** Spring percentile histograms (real p95/p99) |
| Dashboard delivery | **JSON files** in `k8s/infra/dashboards/`, loaded via a ConfigMap referenced by `dashboardsConfigMaps` |
| k6 dashboard (19665) | **Keep** as-is (gnetId) |

### Compatibility verification (done)

VictoriaMetrics single-node is a Prometheus-compatible scraper; its `scrape_configs` are Prometheus config and MetricsQL is a PromQL superset. **Verified live** (2026-06-09): VM is actively scraping and storing `kube-state-metrics` — a plain Prometheus exporter, the same species as kafka-exporter/mysqld-exporter — alongside `kubelet-cadvisor` and `spring-actuator`. Both new exporters expose the identical Prometheus text-exposition format, so adding them mirrors the existing KSM scrape job. No VM-specific incompatibility exists.

## 3. Dashboard 1 — JVM (per service)

**File:** `k8s/infra/dashboards/jvm-services.json`. **Datasource:** VictoriaMetrics.

**Template variables:**
- `$service` = `label_values(jvm_memory_used_bytes, app)` — multi-select, includes "All".
- `$pod` = `label_values(jvm_memory_used_bytes{app=~"$service"}, pod)` — dependent, multi-select, "All". (Services scale to 3 replicas under HPA; per-pod view is required.)

All panels filter `{app=~"$service", pod=~"$pod"}`. Metric names below are GC-agnostic where pool-dependent (regex on the `id` label) because a CPU-limited pod may run SerialGC instead of G1.

| Row | Panels | Health question answered |
|---|---|---|
| **1. Alive & stable** | instances up (`count(up{job="spring-actuator"})` filtered), `process_uptime_seconds`, container restarts 1h (`kube_pod_container_status_restarts_total`), `process_cpu_usage` | Running? crashed/restarted? pegged? |
| **2. CPU & load** | `process_cpu_usage` (JVM share) vs `system_cpu_usage`; `system_load_average_1m` ÷ `system_cpu_count` | CPU-bound? (the bcrypt-login ceiling) |
| **3a. Heap & non-heap** | `jvm_memory_used_bytes{area="heap"}` vs `jvm_memory_max_bytes`; committed; non-heap / Metaspace | Near OOM? metaspace leak? |
| **3b. Generational heap** | Eden `jvm_memory_used_bytes{id=~".*Eden.*"}`; Survivor `{id=~".*Survivor.*"}`; Old `{id=~".*Old.*\|.*Tenured.*"}`; **allocation rate** `rate(jvm_gc_memory_allocated_bytes_total[5m])`; **promotion rate** `rate(jvm_gc_memory_promoted_bytes_total[5m])` | Eden fill (minor-GC frequency), tenuring into Old, leak (Old never drops after major GC) |
| **4. Garbage collection** | `jvm_gc_pause_seconds_*` grouped by `action` tag ("end of minor GC" vs "end of major GC"): pause rate, avg, max | Is GC stealing wall-clock; minor vs major split |
| **5. Threads** | live / daemon / peak; `jvm_threads_states_threads{state=}` | Thread leak, pool exhaustion, blocked/deadlock signal |
| **6. HTTP server (RED)** | request rate by status class `rate(http_server_requests_seconds_count[5m])`; error ratio (5xx/total); latency p95/p99 via `histogram_quantile(…, http_server_requests_seconds_bucket)` | Throughput, errors, tail latency — user-facing SLI |

**Notes / honest constraints:**
- Under G1, Eden/Survivor pools report `max = -1` (elastic regions); plot occupancy against **total heap max**, not per-pool max.
- **Eden→Survivor copy volume has no Micrometer counter** — it is read indirectly from the Eden sawtooth + Survivor occupancy + minor-GC frequency. The two real flow counters are `jvm_gc_memory_allocated_bytes_total` (into young) and `jvm_gc_memory_promoted_bytes_total` (young→Old).
- **No connection-pool row.** These services use Atomikos XA pools, which Micrometer's HikariCP binder does not instrument — a pool row would be dead panels. Pool pressure surfaces in *thread states* (JVM) and *connections* (MySQL dashboard) instead. Omission is deliberate.
- Row 6 percentiles require the histogram config in §6.

## 4. Dashboard 2 — Kafka

**File:** `k8s/infra/dashboards/kafka.json`. **Source:** `kafka-exporter` (`danielqsj/kafka-exporter`) on `:9308`, connecting to `kafka:9092` (PLAINTEXT/KRaft).

**Honest constraint:** single KRaft broker ⇒ replication factor 1 ⇒ under-replicated/ISR/offline-partition panels are structurally degenerate (always "healthy"). The meaningful SUT-health signal here is **consumer lag** — the saga depends on the orchestrator/order consumers keeping up with the Mongo-CDC topics.

| Row | Panels | Health question |
|---|---|---|
| **1. Cluster** | brokers up (`kafka_brokers`), topic count, partition count | Broker reachable? |
| **2. Consumer lag** *(headline)* | `kafka_consumergroup_lag_sum` by group/topic; top-N lag table; lag over time; `$consumergroup` var | Consumers keeping up — *stalled-saga early warning* |
| **3. Throughput** | produce/s `rate(kafka_topic_partition_current_offset[5m])`; consume/s from consumer offset rate | Message flow in vs out |
| **4. Topic detail** | partitions per topic; oldest vs current offset (retained backlog) | Backlog & retention |
| **5. Replication** *(caveat)* | under-replicated partitions, ISR — flat at RF=1; kept to teach what to watch in prod | (degenerate locally) |

**Out of scope:** broker-internal JVM/JMX metrics (request latency, controller state) need a JMX exporter on the broker — flagged as a future add, not included.

## 5. Dashboard 3 — MySQL

**File:** `k8s/infra/dashboards/mysql.json`. **Source:** `mysqld-exporter` (`prom/mysqld-exporter`) on `:9104`, one instance per database pod (**primary `mysql-0` + replicas `mysql-replica-0/1`** — verified: 1×`mysql` StatefulSet + 2×`mysql-replica` StatefulSet, GTID replication). Authenticates with a monitoring user (`PROCESS, REPLICATION CLIENT, SELECT`; root acceptable locally) via a DSN provided per the exporter's version (see §6 footgun).

**Template variable:** `$instance` (primary / replica-0 / replica-1).

| Row | Panels | Ties to a real incident in this repo |
|---|---|---|
| **1. Up & uptime** | `mysql_up`, uptime per instance | basic liveness |
| **2. Connections** | `threads_connected`, `threads_running`, `max_used_connections` vs `max_connections` | the **Atomikos pool-exhaustion** incident |
| **3. QPS / mix** | `rate(mysql_global_status_questions)`, com_select/insert/update/delete rates | read/write profile under k6 load |
| **4. InnoDB buffer pool** | hit ratio `1 − reads/read_requests`; free/dirty pages | working set cached vs hitting disk |
| **5. Lock contention** | `innodb_row_lock_waits` rate, `innodb_row_lock_time`, current waits | the **XA self-deadlock / lock-wait-timeout** SCAR |
| **6. Replication lag** *(headline)* | `mysql_slave_status_seconds_behind_master`; IO/SQL thread running, per replica | the **read-after-write hazards** (inventory oversell, payment lifecycle reading a lagging slave) |
| **7. Errors** | slow-query rate, aborted connects/clients | degradation signals |

## 6. Wiring

### 6.1 Exporters (new manifests, `k8s/infra/manifests/`)
- `kafka-exporter.yaml` — Deployment + Service (`kafka-exporter.infra.svc:9308`), args `--kafka.server=kafka:9092`.
- `mysqld-exporter.yaml` — Deployment(s) + Service(s) (`mysqld-exporter*.infra.svc:9104`) + a DSN Secret. One exporter process per MySQL instance (primary + 2 replicas) so `seconds_behind_master` is collected per replica.
- Both applied by `install.sh` (after the stateful services they target). Teardown is automatic — `kind delete cluster` wipes the namespace, so no `k8s-down` change is needed (per k8s/CLAUDE.md teardown note).

### 6.2 Scrape config (`k8s/infra/values/victoria-metrics.yaml`)
Add scrape jobs targeting the exporter Services (static targets or endpoint SD in the `infra` namespace), mirroring the existing `kube-state-metrics` job shape. Two jobs: `kafka-exporter`, `mysqld-exporter`.

### 6.3 HTTP percentile histograms
Enable `management.metrics.distribution.percentiles-histogram.http.server.requests=true` so `http_server_requests_seconds_bucket` is exported (required for real p95/p99 in JVM row 6). Implementation chooses between a shared config module applied once vs per-service `application.yml`/Vault — to be resolved in the plan by checking for an existing shared management-config seam. **Footgun to verify:** confirm the bucket series appear on `/actuator/prometheus` after the change before building the percentile panels.

### 6.4 Dashboard delivery (`k8s/infra/values/grafana.yaml`)
- **Remove** the three broken `gnetId` entries (`jvm-micrometer`, `spring-boot-3`, `k8s-pods`). **Keep** `k6` (19665).
- Add `dashboardsConfigMaps: { default: grafana-custom-dashboards }` so the chart mounts an external ConfigMap into the existing provider folder.
- `install.sh` creates that ConfigMap **imperatively** from the JSON files:
  `kubectl create configmap grafana-custom-dashboards -n monitoring --from-file=k8s/infra/dashboards/ --dry-run=client -o yaml | kubectl apply -f -`
  (imperative create dodges kustomize's root-only path restriction — the same pattern used for the seed Jobs; see k8s/CLAUDE.md).
- **Footgun to verify:** confirm `dashboards.default` (k6 gnetId) and `dashboardsConfigMaps.default` coexist under one provider folder; if the chart rejects the overlap, fold k6 into the ConfigMap too.

### 6.5 mysqld-exporter version footgun
`mysqld-exporter` ≥ v0.15 dropped the `DATA_SOURCE_NAME` env in favour of `--config.my-cnf` (or `MYSQLD_EXPORTER_PASSWORD` + `--mysqld.username`). Pin a specific image tag and use the credential method matching that tag; do not assume `DATA_SOURCE_NAME`.

## 7. Out of scope
- Kafka broker JMX metrics (request latency, controller) — future JMX-exporter add.
- Alerting / alert rules — dashboards only.
- AWS overlay changes — local-dev provisioning only.
- Refactoring existing logging or the working k6 dashboard.

## 8. Acceptance
- The three broken gnetId dashboards are gone; three new dashboards render with live data against VictoriaMetrics.
- JVM dashboard: `$service`/`$pod` dropdowns work; all six rows populate (generational rates non-zero under load; p95/p99 panels show data after the histogram change).
- Kafka dashboard: consumer-lag and throughput panels populate; lag reacts to a k6 run.
- MySQL dashboard: connections, QPS, buffer-pool, lock, and `seconds_behind_master` panels populate for primary + both replicas.
- `make k8s-bootstrap` (or the relevant install step) brings up both exporters and the dashboards with no manual step.
