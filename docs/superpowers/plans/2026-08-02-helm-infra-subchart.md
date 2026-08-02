# Helm Infra Subchart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 229-line `k8s/infra/install.sh` sequencer with a Helm umbrella chart whose `infra` subchart brings up the same 14 manifests plus 4 upstream charts, with every ordering constraint moved into the workloads that need it.

**Architecture:** `deploy/charts/microecom/` is an umbrella chart that owns namespaces and shared `global.*` values. `charts/infra/` holds the templated manifests and declares `vault`, `victoria-metrics-single`, `grafana` and `kube-state-metrics` as `condition:`-gated dependencies. Ordering leaves bash and enters the cluster: `wait-for-kafka` / `ensure-compacted` / `wait-for-schema-registry` initContainers, one `post-install,post-upgrade` hook Job for MySQL replication, `lookup` for the mongodb keyfile, `.Files.Glob` for the Grafana dashboards, and Helm's own install order for the gp3 StorageClass. The old path stays on disk and keeps working the entire time.

**Tech Stack:** Helm v4.2.0 (chart `apiVersion: v2`), Kubernetes 1.30 on minikube, bash for the test harness and `platform.sh`.

## Global Constraints

- **Do not modify `k8s/infra/install.sh` or anything under `k8s/infra/manifests/`.** The old path must keep working for the whole phase (spec: "Verification 7"). New files only. Where content is shared (the 3 dashboard JSONs), **copy**, do not move.
- **Storage sizes are `mysql: 4Gi`, `mysqlReplica: 4Gi`, `mongodb: 4Gi`, `kafka: 10Gi`, `minio: 10Gi`.** The design spec's values schema says 5Gi for `mysql` and `mysqlReplica`; that is inherited from the parent spec and is **wrong** — the live manifests use 4Gi. Using 5Gi would silently resize StatefulSet volumes (an immutable field) during a refactor. Use 4Gi.
- **`mysqlReplica.replicas: 2`.**
- Pinned images, copied verbatim from the manifests: `mysql:8.0.40`, `mongo:7.0`, `redis:7.4-alpine`, `apache/kafka:3.9.1`, `confluentinc/cp-schema-registry:7.7.1`, `confluentinc/cp-kafka-connect:7.6.1`, `danielqsj/kafka-exporter:v1.8.0`, `prom/mysqld-exporter:v0.16.0`, `minio/minio`, `minio/mc`.
- Pinned chart versions: `vault` 0.27.0 (hashicorp), `victoria-metrics-single` 0.39.0 (vm), `grafana` 10.5.15 (grafana), `ingress-nginx` 4.10.0, `metrics-server` unpinned (upstream kubernetes-sigs). `kube-state-metrics` is installed **unpinned** today — Task 1 reads the resolved version and pins that exact value; do not accept whatever `helm repo update` currently offers.
- **Service DNS names are a contract, not a label.** `mysql`, `mysql-replica`, `mysql-replica-headless`, `mongodb`, `redis-master`, `minio`, `kafka`, `schema-registry`, `kafka-connect`, `vault`, `vmsingle`, `grafana` are hardcoded in `k8s/infra/jobs/03-vault-seed/seed.sh`, in `k8s/infra/values/victoria-metrics.yaml`'s scrape config, and in app config. Rendered names must be **byte-identical** to today. Never use `{{ .Release.Name }}-` prefixes on these objects.
- **The upstream dependencies need `fullnameOverride`, and the aliased ones also need `nameOverride`.** Today each is its own release, so `vault` names its Service `vault`. Under one umbrella release named `microecom`, the same chart names it `microecom-vault` — and every app deployment hardcodes `vault.infra.svc.cluster.local:8200`. `alias:` compounds this: it replaces `.Chart.Name`, so aliasing `kube-state-metrics` to `kubeStateMetrics` would set `app.kubernetes.io/name: kubeStateMetrics`, and VM's scrape job keeps targets by `regex: kube-state-metrics` — the metric would vanish silently. Required pins: `vault` → `fullnameOverride: vault`; `grafana` → `fullnameOverride: grafana`; `kubeStateMetrics` → both `fullnameOverride` and `nameOverride: kube-state-metrics`. `victoriaMetrics` already carries `fullnameOverride: vmsingle` in its existing values file — keep it.
- Namespaces: `infra`, `apps`, `monitoring`, `bootstrap`. Every template in `charts/infra` sets `metadata.namespace` explicitly from `.Values.global.namespaces.*` — never rely on the release namespace.
- `enableServiceLinks: false` on every Confluent `cp-*` pod spec (schema-registry, kafka-connect). Without it the image exits 1 before the JVM starts. See `k8s/CLAUDE.md`.
- Kafka internal topics that must exist **and** be `cleanup.policy=compact`: `_schemas` (schema-registry), `connect-configs`, `connect-offsets`, `connect-status` (kafka-connect).
- `--wait` timeouts must be **≥ 15m**: the Confluent images are ~1.8 GB and a cold pull alone takes ~5.5m.
- Commit `Chart.lock`; **do not** commit `charts/infra/charts/*.tgz` (add to `.gitignore`).
- `git push` is blocked from the agent shell by a pre-push hook. Never bypass it — hand pushes to the user with the `! ` prefix.

---

## File Structure

| File | Responsibility |
|---|---|
| `deploy/charts/microecom/Chart.yaml` | Umbrella metadata; declares `infra` as a local dependency |
| `deploy/charts/microecom/values.yaml` | `global.*` + `infra.*` defaults (the minikube base case) |
| `deploy/charts/microecom/.helmignore` | Excludes `tests/` from the packaged chart |
| `deploy/charts/microecom/templates/namespaces.yaml` | `apps`, `monitoring`, `bootstrap` Namespace objects |
| `deploy/charts/microecom/envs/local-k8s.yaml` | Minikube overrides (near-empty) |
| `deploy/charts/microecom/envs/aws.yaml` | EKS overrides; written now, first exercised in Phase 7 |
| `deploy/charts/microecom/tests/render-test.sh` | Assertion harness over `helm template` — the red/green cycle for every task |
| `deploy/charts/microecom/charts/infra/Chart.yaml` | 4 upstream dependencies, each `condition:`-gated |
| `deploy/charts/microecom/charts/infra/values.yaml` | Subchart defaults; upstream chart values live here |
| `deploy/charts/microecom/charts/infra/dashboards/*.json` | 3 Grafana dashboards, copied from `k8s/infra/dashboards/` |
| `deploy/charts/microecom/charts/infra/templates/_helpers.tpl` | `microecom.fqdn` — the single cross-service addressing helper |
| `.../templates/mysql.yaml` | `mysql-credentials` Secret, `mysql` Service + StatefulSet |
| `.../templates/mysql-replica.yaml` | `mysql-replica` + `mysql-replica-headless` Services, replica StatefulSet |
| `.../templates/mysqld-exporter.yaml` | One Secret+Deployment+Service per instance, generated by `range` |
| `.../templates/mongodb.yaml` | `mongodb-keyfile` Secret (via `lookup`), Service, StatefulSet |
| `.../templates/redis.yaml` | `redis-master` Service + `redis` Deployment |
| `.../templates/minio.yaml` | Service + StatefulSet + `minio-ingress` |
| `.../templates/kafka.yaml` | Service + StatefulSet |
| `.../templates/kafka-exporter.yaml` | Deployment + Service, with `wait-for-kafka` |
| `.../templates/schema-registry.yaml` | Deployment + Service, with `wait-for-kafka` + `ensure-compacted` |
| `.../templates/kafka-connect.yaml` | Deployment + Service, with 3 waits + existing `install-plugins` |
| `.../templates/dashboards-cm.yaml` | `grafana-custom-dashboards` ConfigMap via `.Files.Glob` |
| `.../templates/storageclass-gp3.yaml` | AWS-gated StorageClass |
| `.../templates/external-secrets.yaml` | AWS-gated ServiceAccount + SecretStore |
| `.../templates/hooks/mysql-replication-job.yaml` | `post-install,post-upgrade` replication Job |
| `deploy/scripts/platform.sh` | Installs `ingress-nginx` + `metrics-server`, runs `helm dependency build` |
| `Makefile` | New `k8s-infra-helm` + `k8s-platform` targets |
| `deploy/README.md` | Documents the chart, the `--dry-run` keyfile hazard, the dependency-build prerequisite |

---

### Task 1: Chart scaffold, dependency gating proof, and the render-test harness

The chart's whole shape rests on two unverified assumptions: that `condition:` on a subchart dependency resolves against the umbrella's `infra:` block, and that the three monitoring charts can be redirected out of the release namespace. Prove both before converting a single manifest. This task also builds the harness every later task tests against.

**Files:**
- Create: `deploy/charts/microecom/Chart.yaml`
- Create: `deploy/charts/microecom/values.yaml`
- Create: `deploy/charts/microecom/.helmignore`
- Create: `deploy/charts/microecom/templates/namespaces.yaml`
- Create: `deploy/charts/microecom/envs/local-k8s.yaml`
- Create: `deploy/charts/microecom/charts/infra/Chart.yaml`
- Create: `deploy/charts/microecom/charts/infra/values.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `.Values.global.namespaces.{infra,apps,monitoring,bootstrap}` (strings), `.Values.global.image.{registry,tag,pullPolicy}`, `.Values.global.ingress.{className,hosts.{storefront,api,media}}`, `.Values.infra.<component>.enabled` (bool) for each of `mysql mysqlReplica mongodb redis kafka minio schemaRegistry kafkaConnect kafkaExporter mysqldExporter storageClassGp3 externalSecrets vault victoriaMetrics grafana kubeStateMetrics`, plus `.Values.infra.mysql.storage`, `.Values.infra.mysqlReplica.{replicas,storage}`, `.Values.infra.mongodb.storage`, `.Values.infra.kafka.storage`, `.Values.infra.minio.storage`. The test harness exposes shell functions `render`, `assert_has`, `assert_lacks`, `assert_ok`.

- [ ] **Step 1: Read the currently-pinned kube-state-metrics version**

The chart is installed unpinned today, so the version to pin is whatever is live — not whatever the repo now resolves to.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community
# If a cluster with the release is reachable, this is authoritative:
helm list -n monitoring -o json | python3 -c "import sys,json;print([r['chart'] for r in json.load(sys.stdin) if 'kube-state-metrics' in r['chart']])"
```

If no cluster is reachable, fall back to the newest 5.x release, which is what `install.sh` would have resolved:

```bash
helm search repo prometheus-community/kube-state-metrics --versions | head -5
```

Record the chosen version. Every later reference to `<KSM_VERSION>` in this task means that exact string.

- [ ] **Step 2: Write the umbrella `Chart.yaml`**

`deploy/charts/microecom/Chart.yaml`:

```yaml
apiVersion: v2
name: microecom
description: Umbrella chart for the microservice-ecommerce platform (infra + apps)
type: application
version: 0.1.0
appVersion: "0.1.0"

dependencies:
  - name: infra
    version: 0.1.0
    repository: ""          # local subchart in charts/infra
    condition: infra.enabled
```

- [ ] **Step 3: Write the subchart `Chart.yaml` with the four gated dependencies**

`deploy/charts/microecom/charts/infra/Chart.yaml` — replace `<KSM_VERSION>` with the string recorded in Step 1:

```yaml
apiVersion: v2
name: infra
description: Stateful services, observability and secret backends for microecom
type: application
version: 0.1.0
appVersion: "0.1.0"

dependencies:
  - name: vault
    version: 0.27.0
    repository: https://helm.releases.hashicorp.com
    condition: vault.enabled
  - name: victoria-metrics-single
    version: 0.39.0
    repository: https://victoriametrics.github.io/helm-charts/
    alias: victoriaMetrics
    condition: victoriaMetrics.enabled
  - name: grafana
    version: 10.5.15
    repository: https://grafana.github.io/helm-charts
    condition: grafana.enabled
  - name: kube-state-metrics
    version: <KSM_VERSION>
    repository: https://prometheus-community.github.io/helm-charts
    alias: kubeStateMetrics
    condition: kubeStateMetrics.enabled
```

- [ ] **Step 4: Write the umbrella `values.yaml`**

`deploy/charts/microecom/values.yaml`. Note `mysql`/`mysqlReplica` storage is **4Gi**, correcting the spec.

```yaml
# Base values = the minikube (local-k8s) case. envs/aws.yaml overrides for EKS.
global:
  namespaces:
    infra: infra
    apps: apps
    monitoring: monitoring
    bootstrap: bootstrap
  image:
    registry: localhost:5000
    tag: dev
    pullPolicy: Always
  secret:
    backend: vault          # vault | externalSecrets
  ingress:
    className: nginx
    hosts:
      storefront: microecom.local
      api: api.microecom.local
      media: media.microecom.local

infra:
  enabled: true

  mysql:          { enabled: true, storage: 4Gi }
  mysqlReplica:   { enabled: true, replicas: 2, storage: 4Gi }
  mongodb:        { enabled: true, storage: 4Gi }
  redis:          { enabled: true }
  kafka:          { enabled: true, storage: 10Gi }
  minio:          { enabled: true, storage: 10Gi }
  schemaRegistry: { enabled: true }
  kafkaConnect:   { enabled: true }
  kafkaExporter:  { enabled: true }
  mysqldExporter: { enabled: true }

  # EKS only — Phase 7 exercises these.
  storageClassGp3: { enabled: false }
  externalSecrets: { enabled: false, roleArn: "", region: ap-southeast-1 }

  # Upstream chart dependencies. `enabled` is the Helm condition gate and is
  # ignored by the charts themselves; every other key under these is the
  # upstream chart's own values namespace.
  vault:            { enabled: true }
  victoriaMetrics:  { enabled: true }
  grafana:          { enabled: true }
  kubeStateMetrics: { enabled: true }

apps: {}   # stub — Phase 3 populates this
```

- [ ] **Step 5: Write the subchart `values.yaml` carrying the upstream chart values**

`deploy/charts/microecom/charts/infra/values.yaml`. Copy the bodies of `k8s/infra/values/vault.yaml`, `k8s/infra/values/grafana.yaml` and `k8s/infra/values/victoria-metrics.yaml` **verbatim, comments included**, nested under the matching key. The three monitoring charts get `namespaceOverride` so they land in `monitoring` rather than the release namespace.

```yaml
# Subchart defaults. These are the fallbacks; the umbrella's `infra:` block wins.
#
# fullnameOverride on every dependency: today each of these is its own release
# (`helm install vault …`), so the chart names its Service `vault`. Folded into a
# release named `microecom` the same chart would produce `microecom-vault`, and
# every app hardcodes vault.infra.svc.cluster.local:8200. These pins keep the
# rendered names byte-identical to today.
vault:
  enabled: true
  fullnameOverride: vault
  # <-- paste the full body of k8s/infra/values/vault.yaml here, unchanged -->

victoriaMetrics:
  enabled: true
  namespaceOverride: monitoring
  # <-- paste the full body of k8s/infra/values/victoria-metrics.yaml here.
  #     It already sets `fullnameOverride: vmsingle` (grafana's datasource points
  #     at vmsingle.monitoring.svc.cluster.local:8428) — keep it. -->

grafana:
  enabled: true
  namespaceOverride: monitoring
  fullnameOverride: grafana
  # <-- paste the full body of k8s/infra/values/grafana.yaml here -->

kubeStateMetrics:
  enabled: true
  namespaceOverride: monitoring
  fullnameOverride: kube-state-metrics
  # nameOverride too, not just fullnameOverride: `alias: kubeStateMetrics`
  # replaces .Chart.Name, which feeds `app.kubernetes.io/name`. VM's scrape job
  # keeps targets by `regex: kube-state-metrics` on that exact label
  # (k8s/infra/values/victoria-metrics.yaml, job_name: kube-state-metrics), so
  # without this the metrics disappear with no error anywhere.
  nameOverride: kube-state-metrics
```

`grafana.dashboardsConfigMaps.custom: grafana-custom-dashboards` must survive the copy — Task 7 renders that ConfigMap.

- [ ] **Step 6: Write the namespaces template**

`deploy/charts/microecom/templates/namespaces.yaml`. **`infra` is deliberately absent** — the release is installed into `infra` with `--create-namespace`, and a template that also declares it fails with an ownership conflict.

```yaml
{{- range $key, $name := .Values.global.namespaces }}
{{- if ne $key "infra" }}
---
apiVersion: v1
kind: Namespace
metadata:
  name: {{ $name }}
  labels:
    app.kubernetes.io/managed-by: {{ $.Release.Service }}
    app.kubernetes.io/part-of: microecom
{{- end }}
{{- end }}
```

- [ ] **Step 7: Write `.helmignore` and `envs/local-k8s.yaml`**

`deploy/charts/microecom/.helmignore`:

```
.git/
tests/
*.tgz
```

`deploy/charts/microecom/envs/local-k8s.yaml`:

```yaml
# minikube is the base case — values.yaml already encodes it. This file exists so
# every environment is selected the same way: -f envs/<env>.yaml
global:
  image:
    registry: localhost:5000
    tag: dev
```

- [ ] **Step 8: Ignore the vendored dependency tarballs**

Append to `.gitignore`:

```
# Helm vendored subchart tarballs — rebuilt from Chart.lock by `helm dependency build`
deploy/charts/microecom/charts/infra/charts/
```

- [ ] **Step 9: Write the render-test harness**

`deploy/charts/microecom/tests/render-test.sh`:

```bash
#!/usr/bin/env bash
# Assertion harness over `helm template`. No cluster required.
#
#   ./deploy/charts/microecom/tests/render-test.sh
#
# Each task appends a section. A section renders the chart with some values and
# asserts on the YAML text. `helm template` never evaluates `lookup`, so tests
# that depend on live cluster state belong in the E2E task, not here.
set -uo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0

render() {
  helm template microecom "$CHART_DIR" --namespace infra "$@" 2>&1
}

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# assert_has <description> <extended-regex> <text>
assert_has() {
  if printf '%s\n' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1"; fi
}

# assert_lacks <description> <extended-regex> <text>
assert_lacks() {
  if printf '%s\n' "$3" | grep -qE -- "$2"; then bad "$1"; else ok "$1"; fi
}

# assert_ok <description> <text>  — text is a render result; fail if it looks like an error
assert_ok() {
  if printf '%s\n' "$2" | grep -qiE '^Error:|template:.*(error|not defined)'; then
    bad "$1"
    printf '%s\n' "$2" | head -20 | sed 's/^/       /'
  else
    ok "$1"
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── Task 1: scaffold and gating ─────────────────────────────────────────────
section "scaffold and dependency gating"

out="$(render)"
assert_ok    "default values render"                            "$out"
assert_has   "apps namespace is created"                        'kind: Namespace' "$out"
assert_has   "apps namespace name"                              'name: apps' "$out"
assert_has   "monitoring namespace name"                        'name: monitoring' "$out"
assert_has   "bootstrap namespace name"                         'name: bootstrap' "$out"
assert_lacks "infra namespace is NOT templated (--create-namespace owns it)" \
                                                                '^  name: infra$' "$out"
assert_has   "vault Service keeps its name (apps hardcode vault.infra.svc)" '^  name: vault$' "$out"
assert_lacks "no release-name prefix leaked onto vault"         'name: microecom-vault' "$out"
assert_has   "grafana keeps its name"                           '^  name: grafana$' "$out"
assert_has   "vmsingle keeps its name (grafana datasource)"     'name: vmsingle' "$out"
assert_has   "kube-state-metrics keeps its scrape label"        'app\.kubernetes\.io/name: kube-state-metrics' "$out"
assert_lacks "alias did not leak into the KSM name label"       'kubeStateMetrics' "$out"

out="$(render --set infra.vault.enabled=false)"
assert_ok    "vault disabled renders"                           "$out"
assert_lacks "infra.vault.enabled=false gates the vault dependency" \
                                                                'app.kubernetes.io/name: vault' "$out"

out="$(render --set infra.grafana.enabled=false --set infra.victoriaMetrics.enabled=false --set infra.kubeStateMetrics.enabled=false)"
assert_ok    "monitoring charts disabled renders"               "$out"
# Assert on images, not names: VM's scrape config contains the literal strings
# `kube-state-metrics` (job_name and relabel regex), so a name-based assertion
# would fail whenever VM is enabled.
assert_lacks "grafana gated off"                                'image: .*grafana/grafana' "$out"
assert_lacks "kube-state-metrics gated off"                     'kube-state-metrics/kube-state-metrics' "$out"

out="$(render)"
assert_has   "grafana lands in the monitoring namespace"        'namespace: monitoring' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 10: Make it executable and run it — expect failure**

```bash
chmod +x deploy/charts/microecom/tests/render-test.sh
./deploy/charts/microecom/tests/render-test.sh
```

Expected: `Error: found in Chart.yaml, but missing in charts/ directory: vault, victoria-metrics-single, grafana, kube-state-metrics` — the dependencies are declared but not vendored.

- [ ] **Step 11: Vendor the dependencies**

`helm dependency update` does **not** recurse into subcharts. Run it against `charts/infra` directly.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
helm dependency update deploy/charts/microecom/charts/infra
ls deploy/charts/microecom/charts/infra/charts/
```

Expected: four `.tgz` files and a new `Chart.lock`.

- [ ] **Step 12: Run the harness — expect pass**

```bash
./deploy/charts/microecom/tests/render-test.sh
```

Expected: `18 passed, 0 failed`.

**If the gating assertions fail** (`infra.vault.enabled=false` did not gate the dependency), the `condition:` scope assumption in the spec is wrong. The documented fallback: move the four dependency declarations into the **umbrella** `Chart.yaml` with `condition: infra.vault.enabled` etc., and move their values from `charts/infra/values.yaml` to the umbrella's top level (`vault:`, `grafana:`, … as siblings of `infra:`). Report this before continuing — it changes where every later task puts upstream values.

**If the namespace assertion fails** (grafana rendered into `infra`), that chart does not honour `namespaceOverride`. Fallback: leave that one chart out of the dependency list and install it as a separate release in `platform.sh` (Task 8), the same treatment `ingress-nginx` and `metrics-server` already get. Report which chart.

- [ ] **Step 13: Commit**

```bash
git add deploy/charts/microecom .gitignore
git commit -m "feat(deploy): scaffold microecom umbrella chart with gated infra dependencies

Proves the two unknowns the chart's shape rests on: subchart condition:
resolves against the umbrella's infra: block, and the monitoring charts honour
namespaceOverride. Adds tests/render-test.sh as the red/green cycle for the
manifest conversion.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Helpers and the MySQL family

Four manifests (`mysql.yaml`, `mysql-replica-service.yaml`, `mysql-replica.yaml`, `mysqld-exporter.yaml`, 504 lines) become three templates. `mysqld-exporter` is the interesting one: 227 lines of three near-identical blocks collapse into one `range`.

**Files:**
- Create: `deploy/charts/microecom/charts/infra/templates/_helpers.tpl`
- Create: `deploy/charts/microecom/charts/infra/templates/mysql.yaml`
- Create: `deploy/charts/microecom/charts/infra/templates/mysql-replica.yaml`
- Create: `deploy/charts/microecom/charts/infra/templates/mysqld-exporter.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh` (append a section)
- Read-only source: `k8s/infra/manifests/{mysql,mysql-replica,mysql-replica-service,mysqld-exporter}.yaml`

**Interfaces:**
- Consumes: `.Values.global.namespaces.infra`, `.Values.infra.mysql.{enabled,storage}`, `.Values.infra.mysqlReplica.{enabled,replicas,storage}`, `.Values.infra.mysqldExporter.enabled` (Task 1).
- Produces: the named template `microecom.fqdn`, taking `(dict "name" <string> "namespace" <string>)` and returning `<name>.<namespace>.svc.cluster.local`. Every later task calls it for cross-service addressing. Also produces the Secret `mysql-credentials` in the `infra` namespace with keys `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_REPL_USER`, `MYSQL_REPL_PASSWORD` — Task 6's hook Job consumes it via `envFrom`.

- [ ] **Step 1: Append the failing tests**

Append to `deploy/charts/microecom/tests/render-test.sh`, immediately before the final `printf '\n%d passed…` line:

```bash
# ── Task 2: MySQL family ────────────────────────────────────────────────────
section "mysql family"

out="$(render)"
assert_has   "mysql StatefulSet name is exactly 'mysql'"        '^  name: mysql$' "$out"
assert_has   "mysql-replica-headless Service exists"            'name: mysql-replica-headless' "$out"
assert_has   "mysql-replica Service exists"                     '^  name: mysql-replica$' "$out"
assert_has   "mysql storage is 4Gi"                             'storage: 4Gi' "$out"
assert_has   "mysql-credentials carries the repl user"          'MYSQL_REPL_USER' "$out"
assert_has   "primary exporter targets the mysql FQDN"          'host=mysql\.infra\.svc\.cluster\.local' "$out"
assert_has   "replica-0 exporter targets pod-0 via headless"    'host=mysql-replica-0\.mysql-replica-headless\.infra\.svc\.cluster\.local' "$out"
assert_has   "replica-1 exporter targets pod-1 via headless"    'host=mysql-replica-1\.mysql-replica-headless\.infra\.svc\.cluster\.local' "$out"

out="$(render --set infra.mysqlReplica.replicas=3)"
assert_has   "replicas=3 generates a third exporter"            'name: mysqld-exporter-replica-2' "$out"

out="$(render --set infra.mysql.enabled=false --set infra.mysqlReplica.enabled=false --set infra.mysqldExporter.enabled=false)"
# NOT `kind: StatefulSet` — mongodb, kafka and minio are StatefulSets too and are
# still enabled here, so that assertion would fail for the wrong reason.
assert_lacks "mysql gated off"                                  'image: mysql:8\.0\.40' "$out"
assert_lacks "mysqld-exporter gated off"                        'mysqld-exporter' "$out"

out="$(render --set global.namespaces.infra=data)"
assert_has   "namespace is a values change, not a literal"      'host=mysql\.data\.svc\.cluster\.local' "$out"
```

- [ ] **Step 2: Run — expect failure**

```bash
./deploy/charts/microecom/tests/render-test.sh
```

Expected: the 9 new positive assertions FAIL (no MySQL templates yet); the two `assert_lacks` pass vacuously.

- [ ] **Step 3: Write `_helpers.tpl`**

```
{{/*
Fully-qualified in-cluster Service DNS name.

  {{ include "microecom.fqdn" (dict "name" "kafka" "namespace" $ns) }}
  → kafka.infra.svc.cluster.local

Every cross-service address goes through here so renaming a namespace is a
values change, not a search-and-replace across 14 files.
*/}}
{{- define "microecom.fqdn" -}}
{{- printf "%s.%s.svc.cluster.local" .name .namespace -}}
{{- end -}}
```

**One helper, deliberately.** The spec's chart layout also lists "labels" and "image refs" helpers; neither has a caller in Phase 2. Labels double as immutable Deployment/StatefulSet **selectors**, so the conversion recipe copies them verbatim rather than regenerating them — a helper that must reproduce each manifest's existing labels exactly is a rename risk with no upside. Image refs are for the `global.image.registry`-based app images, which arrive in Phase 3; every infra image is an upstream pinned tag. Add those helpers when something calls them.

- [ ] **Step 4: Convert `mysql.yaml`, `mysql-replica.yaml` and `mysql-replica-service.yaml`**

Apply this recipe to each source manifest. It is the same recipe for every mechanical conversion in Tasks 2–5:

1. Copy the source file — **including every comment**; the comments encode the scars and are the reason the manifests are readable.
2. Wrap the whole file in the enabled gate:
   `{{- if .Values.infra.<component>.enabled }}` … `{{- end }}`
3. Add `{{- $ns := .Values.global.namespaces.infra -}}` at the top and replace every `namespace: infra` with `namespace: {{ $ns }}`.
4. Replace every hardcoded `<svc>.infra.svc.cluster.local` with
   `{{ include "microecom.fqdn" (dict "name" "<svc>" "namespace" $ns) }}`.
5. Replace PVC `storage:` values with `{{ .Values.infra.<component>.storage }}`.
6. Replace the replica StatefulSet's `replicas:` with `{{ .Values.infra.mysqlReplica.replicas }}`.
7. **Leave every other literal alone** — image tags, ports, probe timings, resource limits, `metadata.name`. Names are the DNS contract; changing one breaks the Vault seed.

`mysql-replica-service.yaml` (17 lines) merges into `mysql-replica.yaml`; that is the only file boundary that changes.

- [ ] **Step 5: Write `mysqld-exporter.yaml` as a loop**

The three blocks differ only in a name and a host. Build the instance list, then render once per instance:

```yaml
{{- if .Values.infra.mysqldExporter.enabled }}
{{- $ns := .Values.global.namespaces.infra -}}
{{/*
mysqld-exporter — one process per MySQL instance (primary + N replicas) so each
replica's seconds_behind_master is collected. v0.15+: credentials come from a
mounted .my.cnf ([client] section), NOT DATA_SOURCE_NAME. Uses root (local-dev
only). VM scrapes each Service; the scrape job relabels `instance` to a friendly
name.
*/}}
{{- $instances := list -}}
{{- if .Values.infra.mysql.enabled -}}
  {{- $instances = append $instances (dict
        "name" "primary"
        "host" (include "microecom.fqdn" (dict "name" "mysql" "namespace" $ns))) -}}
{{- end -}}
{{- if .Values.infra.mysqlReplica.enabled -}}
  {{- range $i := until (int .Values.infra.mysqlReplica.replicas) -}}
    {{- $instances = append $instances (dict
          "name" (printf "replica-%d" $i)
          "host" (printf "mysql-replica-%d.%s" $i
                   (include "microecom.fqdn" (dict "name" "mysql-replica-headless" "namespace" $ns)))) -}}
  {{- end -}}
{{- end -}}
{{- range $inst := $instances }}
---
apiVersion: v1
kind: Secret
metadata:
  name: mysqld-exporter-{{ $inst.name }}-cnf
  namespace: {{ $ns }}
type: Opaque
stringData:
  .my.cnf: |
    [client]
    user=root
    password=root
    host={{ $inst.host }}
    port=3306
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysqld-exporter-{{ $inst.name }}
  namespace: {{ $ns }}
  labels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: {{ $inst.name }} }
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: {{ $inst.name }} }
  template:
    metadata:
      labels: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: {{ $inst.name }} }
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
          readinessProbe:
            httpGet: { path: /metrics, port: metrics }
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 3
          livenessProbe:
            httpGet: { path: /metrics, port: metrics }
            initialDelaySeconds: 15
            periodSeconds: 15
            timeoutSeconds: 5
          volumeMounts:
            - { name: cfg, mountPath: /cfg, readOnly: true }
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
      volumes:
        - name: cfg
          secret:
            secretName: mysqld-exporter-{{ $inst.name }}-cnf
---
apiVersion: v1
kind: Service
metadata:
  name: mysqld-exporter-{{ $inst.name }}
  namespace: {{ $ns }}
  labels: { app.kubernetes.io/name: mysqld-exporter }
spec:
  type: ClusterIP
  selector: { app.kubernetes.io/name: mysqld-exporter, mysql-instance: {{ $inst.name }} }
  ports:
    - { name: metrics, port: 9104, targetPort: metrics }
{{- end }}
{{- end }}
```

- [ ] **Step 6: Run the harness — expect pass**

```bash
./deploy/charts/microecom/tests/render-test.sh
```

Expected: all Task 1 + Task 2 assertions pass.

- [ ] **Step 7: Diff the render against the source manifests**

The tests check names and addresses; this catches everything else. Render only the MySQL objects and compare field-by-field with the originals.

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  --show-only charts/infra/templates/mysql.yaml \
  --show-only charts/infra/templates/mysql-replica.yaml \
  --show-only charts/infra/templates/mysqld-exporter.yaml \
  > /tmp/rendered-mysql.yaml
grep -cE '^(---|kind:)' /tmp/rendered-mysql.yaml
```

Expected: the same object count as the sources — 2 Services + 2 StatefulSets + 1 credentials Secret + 3×(Secret+Deployment+Service) = **14 objects**. Read `/tmp/rendered-mysql.yaml` and confirm images, ports, probes and resource blocks match the originals exactly.

- [ ] **Step 8: Commit**

```bash
git add deploy/charts/microecom
git commit -m "feat(deploy): template the MySQL family into charts/infra

mysqld-exporter's three near-identical 75-line blocks collapse into one range
over primary + N replicas, so mysqlReplica.replicas now actually drives the
exporter count.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: MongoDB, Redis and MinIO

Mechanical conversion for Redis and MinIO; MongoDB carries the `lookup` keyfile, which is the second of the two behaviour changes in this phase.

**Files:**
- Create: `deploy/charts/microecom/charts/infra/templates/mongodb.yaml`
- Create: `deploy/charts/microecom/charts/infra/templates/redis.yaml`
- Create: `deploy/charts/microecom/charts/infra/templates/minio.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh` (append a section)
- Read-only source: `k8s/infra/manifests/{mongodb,redis,minio,minio-ingress}.yaml`

**Interfaces:**
- Consumes: `microecom.fqdn` (Task 2), `.Values.global.namespaces.infra`, `.Values.global.ingress.{className,hosts.media}`, `.Values.infra.{mongodb,redis,minio}.*` (Task 1).
- Produces: Services `mongodb`, `redis-master` (port 6379), `minio` (port 9000) in the `infra` namespace, and the Secret `mongodb-keyfile` with key `keyfile`.

- [ ] **Step 1: Append the failing tests**

```bash
# ── Task 3: mongodb, redis, minio ───────────────────────────────────────────
section "mongodb / redis / minio"

out="$(render)"
assert_has   "redis Service is named redis-master (vault-seed contract)" 'name: redis-master' "$out"
assert_has   "mongodb Service exists"                           '^  name: mongodb$' "$out"
assert_has   "minio Service exists"                             '^  name: minio$' "$out"
assert_has   "mongodb-keyfile Secret is rendered"               'name: mongodb-keyfile' "$out"
assert_has   "keyfile carries resource-policy keep"             'helm\.sh/resource-policy: keep' "$out"
assert_has   "minio ingress uses the media host from values"    'host: media\.microecom\.local' "$out"
assert_has   "minio ingress uses the ingress class from values" 'ingressClassName: nginx' "$out"
assert_has   "minio storage is 10Gi"                            'storage: 10Gi' "$out"

out="$(render --set global.ingress.hosts.media=media.example.com --set global.ingress.className=alb)"
assert_has   "media host is a values change"                    'host: media\.example\.com' "$out"
assert_has   "ingress class is a values change"                 'ingressClassName: alb' "$out"

out="$(render --set infra.redis.enabled=false)"
assert_lacks "redis gated off"                                  'redis-master' "$out"

out="$(render --set infra.minio.enabled=false)"
assert_lacks "minio gated off (ingress goes with it)"           'media\.microecom\.local' "$out"
```

- [ ] **Step 2: Run — expect failure**

Expected: the 8 positive assertions FAIL.

- [ ] **Step 3: Convert `redis.yaml` and `minio.yaml`**

Apply the Task 2 Step 4 recipe. `minio-ingress.yaml` (42 lines) merges into `minio.yaml` under the same `{{- if .Values.infra.minio.enabled }}` gate — an ingress to a service that does not exist is dead weight. Its host becomes `{{ .Values.global.ingress.hosts.media }}` and its class `{{ .Values.global.ingress.className }}`.

Keep `redis-master` as the Service name. The comment in the source explains why; carry the comment.

- [ ] **Step 4: Write `mongodb.yaml` with the `lookup` keyfile**

Convert the source with the same recipe, then replace the keyfile Secret. The source manifest's header comment says the keyfile "is created idempotently by install.sh" — in the chart that is no longer true, so write the corrected comment shown below. **Do not edit `k8s/infra/manifests/mongodb.yaml`**; there the comment is still accurate.

The design spec sketched this with `ternary`, which does not work — Sprig's `ternary` requires a `bool` condition and `lookup` returns a map or nil, so it errors at render. Use explicit `if`:

```
{{- if .Values.infra.mongodb.enabled }}
{{- $ns := .Values.global.namespaces.infra -}}
{{/*
MongoDB needs an internal keyFile (auth + replica set together). Rotating it
breaks an already-initialized replica set, so the value is read back from the
live cluster and only generated when genuinely absent.

Two hazards, both real:
  - `lookup` returns empty during `helm template` and `helm --dry-run`. A dry
    run therefore renders a FRESH keyfile. Rendering to read is harmless; piping
    that output into `kubectl apply` rotates the keyfile and breaks the replica
    set. Never `helm template ... | kubectl apply -f -` against a live cluster.
  - `helm.sh/resource-policy: keep` stops `helm uninstall` from taking the
    keyfile with it and stranding the replica set's data volume.
*/}}
{{- $existing := lookup "v1" "Secret" $ns "mongodb-keyfile" -}}
{{- $keyfile := "" -}}
{{- if $existing -}}
  {{- $keyfile = index $existing.data "keyfile" | default "" -}}
{{- end -}}
{{- if not $keyfile -}}
  {{- $keyfile = randAlphaNum 756 | b64enc -}}
{{- end }}
---
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-keyfile
  namespace: {{ $ns }}
  annotations:
    helm.sh/resource-policy: keep
type: Opaque
data:
  keyfile: {{ $keyfile | quote }}
```

`$existing.data` values arrive base64-encoded from the API, and `randAlphaNum 756 | b64enc` produces the same encoding, so both branches feed `data:` (not `stringData:`) correctly.

The rest of the file — the `prepare-keyfile` initContainer, the `bootstrap` sidecar, the chown initContainer, the StatefulSet — converts mechanically. The `keyfile-secret` volume still references `secretName: mongodb-keyfile`.

- [ ] **Step 5: Run the harness — expect pass**

```bash
./deploy/charts/microecom/tests/render-test.sh
```

- [ ] **Step 6: Verify the keyfile is exactly 756 base64-decoded characters**

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  --show-only charts/infra/templates/mongodb.yaml \
  | grep -A1 'keyfile:' | head -2
```

Read the value, base64-decode it, and confirm the length is 756. MongoDB rejects keyfiles outside 6–1024 characters.

- [ ] **Step 7: Commit**

```bash
git add deploy/charts/microecom
git commit -m "feat(deploy): template mongodb, redis and minio

The mongodb keyfile moves from install.sh's create-if-missing kubectl guard to
a lookup + resource-policy:keep template. Corrects the design spec's ternary
sketch, which errors: Sprig ternary needs a bool and lookup returns a map.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Kafka and kafka-exporter

The first of the three ordering rewrites. `kafka-exporter` hard-exits when no broker answers; today `install.sh` applies it after Kafka's rollout and then `rollout restart`s it. An initContainer replaces both and additionally survives a Kafka restart at 3am, which the script never did.

**Files:**
- Create: `deploy/charts/microecom/charts/infra/templates/kafka.yaml`
- Create: `deploy/charts/microecom/charts/infra/templates/kafka-exporter.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh` (append a section)
- Read-only source: `k8s/infra/manifests/{kafka,kafka-exporter}.yaml`

**Interfaces:**
- Consumes: `microecom.fqdn` (Task 2), `.Values.infra.kafka.{enabled,storage}`, `.Values.infra.kafkaExporter.enabled`.
- Produces: Service `kafka` in `infra` with port `9092` named `client`. Tasks 5 and 6 address it as `kafka.<ns>.svc.cluster.local:9092`.

- [ ] **Step 1: Append the failing tests**

```bash
# ── Task 4: kafka + exporter ────────────────────────────────────────────────
section "kafka"

out="$(render)"
assert_has   "kafka Service exists"                             '^  name: kafka$' "$out"
assert_has   "kafka client port"                                'name: client' "$out"
assert_has   "kafka storage is 10Gi"                            'storage: 10Gi' "$out"
assert_has   "kafka-exporter has a wait-for-kafka initContainer" 'name: wait-for-kafka' "$out"
assert_has   "wait-for-kafka reuses the kafka image"            'image: apache/kafka:3\.9\.1' "$out"
assert_has   "wait targets the kafka FQDN"                      'kafka\.infra\.svc\.cluster\.local:9092' "$out"

out="$(render --set infra.kafka.enabled=false --set infra.kafkaExporter.enabled=false)"
# NOT `apache/kafka` — schema-registry and kafka-connect are still enabled here
# and their wait/compact initContainers reuse that image (Task 5).
assert_lacks "kafka StatefulSet gated off"                      '^  name: kafka$' "$out"
assert_lacks "kafka-exporter gated off"                         'danielqsj/kafka-exporter' "$out"
```

- [ ] **Step 2: Run — expect failure**

- [ ] **Step 3: Convert `kafka.yaml`**

Mechanical, per the Task 2 Step 4 recipe. Keep the chown initContainer (minikube hostPath ignores `fsGroup`) and the hardcoded `CLUSTER_ID` + `--ignore-formatted` — both carry comments explaining why; carry them.

- [ ] **Step 4: Write `kafka-exporter.yaml` with `wait-for-kafka`**

```yaml
{{- if .Values.infra.kafkaExporter.enabled }}
{{- $ns := .Values.global.namespaces.infra -}}
{{- $kafka := printf "%s:9092" (include "microecom.fqdn" (dict "name" "kafka" "namespace" $ns)) -}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-exporter
  namespace: {{ $ns }}
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
      # kafka-exporter hard-exits when no broker answers. install.sh worked
      # around that by applying it after Kafka's rollout and then restarting it.
      # Blocking here instead means the exporter also recovers on its own when
      # Kafka restarts later — which the script never handled.
      #
      # Reuses apache/kafka:3.9.1: already pulled on every node that runs Kafka,
      # already carries the CLI. No new image, no new pull.
      initContainers:
        - name: wait-for-kafka
          image: apache/kafka:3.9.1
          command:
            - sh
            - -c
            - |
              until /opt/kafka/bin/kafka-broker-api-versions.sh \
                    --bootstrap-server {{ $kafka }} >/dev/null 2>&1; do
                echo "waiting for kafka at {{ $kafka }}"
                sleep 3
              done
              echo "kafka is up"
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 256Mi }
      containers:
{{- end }}
```

Copy the `containers:` block, ports, probes, resources and Service from `k8s/infra/manifests/kafka-exporter.yaml` verbatim below that, substituting `namespace: {{ $ns }}` and pointing the exporter's own `--kafka.server` at `{{ $kafka }}`.

- [ ] **Step 5: Run the harness — expect pass**

- [ ] **Step 6: Commit**

```bash
git add deploy/charts/microecom
git commit -m "feat(deploy): template kafka and move exporter ordering into an initContainer

Replaces install.sh's apply-after-rollout + rollout-restart dance. The exporter
now also recovers when kafka restarts later, which the script never covered.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Schema Registry and Kafka Connect

The second ordering rewrite, and the largest behaviour change. `install.sh` compacts all four internal topics from one loop before either service starts. Here each service repairs exactly the topics it needs, from inside its own pod.

**Files:**
- Create: `deploy/charts/microecom/charts/infra/templates/schema-registry.yaml`
- Create: `deploy/charts/microecom/charts/infra/templates/kafka-connect.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh` (append a section)
- Read-only source: `k8s/infra/manifests/{schema-registry,kafka-connect}.yaml`

**Interfaces:**
- Consumes: `microecom.fqdn` (Task 2), Service `kafka` (Task 4), `.Values.infra.{schemaRegistry,kafkaConnect}.enabled`.
- Produces: Services `schema-registry` (port 8081) and `kafka-connect` (port 8083) in `infra`.

- [ ] **Step 1: Append the failing tests**

```bash
# ── Task 5: schema-registry + kafka-connect ─────────────────────────────────
section "schema-registry / kafka-connect"

out="$(render)"
assert_has   "schema-registry Service exists"                   '^  name: schema-registry$' "$out"
assert_has   "kafka-connect Service exists"                     '^  name: kafka-connect$' "$out"
assert_has   "schema-registry compacts _schemas"                'TOPICS.*_schemas' "$out"
assert_has   "kafka-connect compacts connect-configs"           'connect-configs connect-offsets connect-status' "$out"
assert_has   "both have an ensure-compacted initContainer"      'name: ensure-compacted' "$out"
assert_has   "kafka-connect waits for schema-registry"          'name: wait-for-schema-registry' "$out"
assert_has   "kafka-connect keeps its install-plugins step"     'name: install-plugins' "$out"
assert_has   "cleanup.policy=compact is applied"                'cleanup\.policy=compact' "$out"
assert_has   "confluent pods disable service links"             'enableServiceLinks: false' "$out"

out="$(render --set infra.schemaRegistry.enabled=false --set infra.kafkaConnect.enabled=false)"
assert_lacks "confluent workloads gated off"                    'confluentinc/cp-' "$out"
```

- [ ] **Step 2: Run — expect failure**

- [ ] **Step 3: Write the two shared initContainers into `schema-registry.yaml`**

`$TOPICS` differs per service; everything else is identical.

```yaml
{{- if .Values.infra.schemaRegistry.enabled }}
{{- $ns := .Values.global.namespaces.infra -}}
{{- $kafka := printf "%s:9092" (include "microecom.fqdn" (dict "name" "kafka" "namespace" $ns)) -}}
```

and inside the pod spec, above `containers:`:

```yaml
      enableServiceLinks: false
      # Kafka auto-creates internal topics with cleanup.policy=delete, and both
      # Schema Registry and Connect refuse to start on a non-compacted topic.
      # install.sh fixed all four topics from one loop before either service
      # started; here each service repairs exactly the topics it owns, from
      # inside its own pod, so it also self-heals after a Kafka rebuild.
      initContainers:
        - name: wait-for-kafka
          image: apache/kafka:3.9.1
          command:
            - sh
            - -c
            - |
              until /opt/kafka/bin/kafka-broker-api-versions.sh \
                    --bootstrap-server {{ $kafka }} >/dev/null 2>&1; do
                echo "waiting for kafka at {{ $kafka }}"
                sleep 3
              done
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 256Mi }
        - name: ensure-compacted
          image: apache/kafka:3.9.1
          env:
            - name: TOPICS
              value: "_schemas"
          command:
            - sh
            - -c
            - |
              set -e
              for t in $TOPICS; do
                /opt/kafka/bin/kafka-topics.sh --bootstrap-server {{ $kafka }} \
                  --create --if-not-exists --topic "$t" \
                  --partitions 1 --replication-factor 1
                /opt/kafka/bin/kafka-configs.sh --bootstrap-server {{ $kafka }} \
                  --alter --entity-type topics --entity-name "$t" \
                  --add-config cleanup.policy=compact
              done
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 256Mi }
      containers:
```

Copy the rest of `k8s/infra/manifests/schema-registry.yaml` verbatim, substituting `namespace: {{ $ns }}` and setting
`SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS: "PLAINTEXT://{{ $kafka }}"`.

- [ ] **Step 4: Write `kafka-connect.yaml` with three waits**

Same two initContainers, with `TOPICS` set to `"connect-configs connect-offsets connect-status"`, then a third, then the existing `install-plugins`. initContainers run sequentially, so these prepend:

```yaml
        - name: wait-for-schema-registry
          image: confluentinc/cp-kafka-connect:7.6.1
          command:
            - sh
            - -c
            - |
              until curl -fsS http://{{ $sr }}:8081/subjects >/dev/null 2>&1; do
                echo "waiting for schema-registry at {{ $sr }}:8081"
                sleep 3
              done
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 256Mi }
```

with `{{- $sr := include "microecom.fqdn" (dict "name" "schema-registry" "namespace" $ns) -}}` at the top. It reuses the main container's image, so no extra pull. Set `CONNECT_BOOTSTRAP_SERVERS: "{{ $kafka }}"`.

- [ ] **Step 5: Run the harness — expect pass**

- [ ] **Step 6: Confirm the initContainer order on kafka-connect**

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  --show-only charts/infra/templates/kafka-connect.yaml \
  | grep -nE '^\s+- name: (wait-for-kafka|ensure-compacted|wait-for-schema-registry|install-plugins)'
```

Expected: exactly those four, in that order.

- [ ] **Step 7: Commit**

```bash
git add deploy/charts/microecom
git commit -m "feat(deploy): template the confluent workloads with self-healing topic repair

Each service now creates and compacts exactly the internal topics it needs from
its own initContainers, replacing install.sh's single pre-flight loop.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: MySQL replication hook Job

The one step that stays imperative. The conversion is a real simplification: today it runs `kubectl exec mysql-0`, needing kubectl in the caller's path and cluster credentials. As a Job it is a plain `mysql` client dialling Service FQDNs — no Kubernetes API access, no ServiceAccount, no RBAC. It also stops hardcoding `repl_user` / `replica_ecommerce`, reading them from the `mysql-credentials` Secret instead.

**Files:**
- Create: `deploy/charts/microecom/charts/infra/templates/hooks/mysql-replication-job.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh` (append a section)
- Read-only source: `k8s/infra/install.sh:135-182`

**Interfaces:**
- Consumes: `microecom.fqdn` (Task 2), Secret `mysql-credentials` and Service `mysql-replica-headless` (Task 2), `.Values.infra.mysqlReplica.{enabled,replicas}`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Append the failing tests**

```bash
# ── Task 6: replication hook ────────────────────────────────────────────────
section "mysql replication hook"

out="$(render)"
assert_has   "replication Job is a post-install/post-upgrade hook" 'helm\.sh/hook: post-install,post-upgrade' "$out"
assert_has   "hook weight is 5"                                 'helm\.sh/hook-weight: "5"' "$out"
assert_has   "hook deletes before re-creation"                  'hook-delete-policy: before-hook-creation' "$out"
assert_has   "job uses the pinned mysql image"                  'image: mysql:8\.0\.40' "$out"
assert_has   "credentials come from the Secret, not literals"   'secretRef' "$out"
assert_lacks "no hardcoded replication password"                'replica_ecommerce' "$out"
assert_has   "job enumerates replica-0"                         'mysql-replica-0\.mysql-replica-headless' "$out"
assert_has   "job enumerates replica-1"                         'mysql-replica-1\.mysql-replica-headless' "$out"
assert_has   "idempotence check on replication_connection_status" 'replication_connection_status' "$out"

out="$(render --set infra.mysqlReplica.enabled=false)"
assert_lacks "hook gated off with the replicas"                 'mysql-replication' "$out"
```

- [ ] **Step 2: Run — expect failure**

- [ ] **Step 3: Write the hook Job**

```yaml
{{- if and .Values.infra.mysql.enabled .Values.infra.mysqlReplica.enabled }}
{{- $ns := .Values.global.namespaces.infra -}}
{{- $primary := include "microecom.fqdn" (dict "name" "mysql" "namespace" $ns) -}}
{{- $headless := include "microecom.fqdn" (dict "name" "mysql-replica-headless" "namespace" $ns) -}}
---
# MySQL replication: 1 primary + N replicas (GTID auto-position).
#
# Mirrors docker/scripts/init-mysql.sh and k8s/infra/install.sh:135-182,
# idempotent. The repl user is created on the primary AFTER init (so it
# replicates); replicas use SOURCE_AUTO_POSITION=1 to pull the full binlog from
# empty (no clone needed).
#
# Helm's sequence is: pre-install hooks -> create resources -> wait for
# readiness (ONLY with --wait) -> post-install hooks. `--wait` is therefore
# load-bearing, not cosmetic. The job polls for reachability anyway so it
# survives being run without it.
#
# Unlike the script this replaces, it touches no Kubernetes API: it is a plain
# mysql client dialling Service DNS, so it needs no ServiceAccount and no RBAC.
apiVersion: batch/v1
kind: Job
metadata:
  name: mysql-replication
  namespace: {{ $ns }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  backoffLimit: 3
  template:
    metadata:
      name: mysql-replication
    spec:
      restartPolicy: Never
      enableServiceLinks: false
      containers:
        - name: replication
          image: mysql:8.0.40
          envFrom:
            - secretRef:
                name: mysql-credentials
          env:
            - name: PRIMARY_HOST
              value: {{ $primary | quote }}
            - name: REPLICA_HOSTS
              value: {{ range $i := until (int .Values.infra.mysqlReplica.replicas) }}mysql-replica-{{ $i }}.{{ $headless }} {{ end }}
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 512Mi }
          command:
            - bash
            - -c
            - |
              set -euo pipefail
              ROOT="-uroot -p${MYSQL_ROOT_PASSWORD}"

              wait_for() {
                local host=$1
                echo "waiting for ${host}"
                until mysql -h "$host" $ROOT -e 'SELECT 1' >/dev/null 2>&1; do sleep 3; done
                echo "${host} is up"
              }

              wait_for "$PRIMARY_HOST"
              for rep in $REPLICA_HOSTS; do wait_for "$rep"; done

              echo "configuring replication user on the primary"
              mysql -h "$PRIMARY_HOST" $ROOT -e "
                CREATE USER IF NOT EXISTS '${MYSQL_REPL_USER}'@'%'
                  IDENTIFIED WITH mysql_native_password BY '${MYSQL_REPL_PASSWORD}';
                GRANT REPLICATION SLAVE ON *.* TO '${MYSQL_REPL_USER}'@'%';
                FLUSH PRIVILEGES;"

              for rep in $REPLICA_HOSTS; do
                running=$(mysql -h "$rep" $ROOT -N -e \
                  "SELECT COUNT(*) FROM performance_schema.replication_connection_status
                   WHERE SERVICE_STATE='ON';" 2>/dev/null || echo 0)
                if [ "${running:-0}" -ge 1 ]; then
                  echo "$rep already replicating; skipping"
                  continue
                fi
                echo "starting replication on $rep"
                mysql -h "$rep" $ROOT -e "
                  STOP REPLICA;
                  CHANGE REPLICATION SOURCE TO
                    SOURCE_HOST='${PRIMARY_HOST}',
                    SOURCE_USER='${MYSQL_REPL_USER}',
                    SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}',
                    SOURCE_AUTO_POSITION=1,
                    GET_SOURCE_PUBLIC_KEY=1;
                  START REPLICA;"
              done

              # Verify; fail the release rather than seed onto a broken topology.
              sleep 5
              rc=0
              for rep in $REPLICA_HOSTS; do
                status=$(mysql -h "$rep" $ROOT -e 'SHOW REPLICA STATUS\G')
                if echo "$status" | grep -q 'Replica_IO_Running: Yes' \
                   && echo "$status" | grep -q 'Replica_SQL_Running: Yes'; then
                  echo "$rep replication OK"
                else
                  echo "ERROR: $rep replication not running:"
                  echo "$status" | grep -E 'Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:'
                  rc=1
                fi
              done
              [ "$rc" -eq 0 ] && echo "MySQL replication ready (1 primary + N replicas)"
              exit "$rc"
{{- end }}
```

- [ ] **Step 4: Run the harness — expect pass**

- [ ] **Step 5: Syntax-check the embedded script**

The Job's shell body is the part most likely to be wrong, and a parse error only surfaces as a failed release minutes into an install. Extract and check it now:

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  --show-only charts/infra/templates/hooks/mysql-replication-job.yaml \
  | python3 -c "import sys,yaml;print(yaml.safe_load(sys.stdin)['spec']['template']['spec']['containers'][0]['command'][2])" \
  > /tmp/repl.sh
bash -n /tmp/repl.sh && echo "script parses"
```

Expected: `script parses`.

- [ ] **Step 6: Commit**

```bash
git add deploy/charts/microecom
git commit -m "feat(deploy): move MySQL replication into a post-install hook Job

Drops the kubectl-exec dependency entirely — the Job is a plain mysql client
over Service DNS, so no ServiceAccount and no RBAC. Credentials now come from
mysql-credentials instead of being hardcoded in bash.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Dashboards ConfigMap, AWS-gated resources, and `envs/aws.yaml`

Closes the remaining ordering constraints — the dashboards ConfigMap and the gp3 StorageClass — and writes the AWS values file so gating can be proven now rather than discovered in Phase 7.

**Files:**
- Create: `deploy/charts/microecom/charts/infra/dashboards/*.json` (copies)
- Create: `deploy/charts/microecom/charts/infra/templates/dashboards-cm.yaml`
- Create: `deploy/charts/microecom/charts/infra/templates/storageclass-gp3.yaml`
- Create: `deploy/charts/microecom/charts/infra/templates/external-secrets.yaml`
- Create: `deploy/charts/microecom/envs/aws.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh` (append a section)
- Read-only source: `k8s/infra/dashboards/*.json`, `k8s/infra/overlays/aws/storageclass-gp3.yaml`, `k8s/infra/manifests/external-secrets-{sa,store}.yaml`

**Interfaces:**
- Consumes: `.Values.global.namespaces.monitoring`, `.Values.infra.{storageClassGp3,externalSecrets}.*`.
- Produces: ConfigMap `grafana-custom-dashboards` in `monitoring` with one key per dashboard JSON — the name `charts/infra/values.yaml` already points `grafana.dashboardsConfigMaps.custom` at.

- [ ] **Step 1: Copy the dashboards**

**Copy, do not move** — `install.sh:56-59` still globs `k8s/infra/dashboards`, and the old path must keep working. The duplication is removed in Phase 8 with the rest of `k8s/`.

```bash
mkdir -p deploy/charts/microecom/charts/infra/dashboards
cp k8s/infra/dashboards/*.json deploy/charts/microecom/charts/infra/dashboards/
ls deploy/charts/microecom/charts/infra/dashboards/
```

Expected: 3 JSON files.

- [ ] **Step 2: Append the failing tests**

```bash
# ── Task 7: dashboards + AWS-gated resources ────────────────────────────────
section "dashboards / aws-gated"

out="$(render)"
assert_has   "dashboards ConfigMap is named for grafana's dashboardsConfigMaps" 'name: grafana-custom-dashboards' "$out"
assert_has   "dashboards land in the monitoring namespace"      'namespace: monitoring' "$out"
assert_lacks "gp3 StorageClass is off by default"               'kind: StorageClass' "$out"
assert_lacks "external-secrets is off by default"               'kind: SecretStore' "$out"

out="$(render --set infra.storageClassGp3.enabled=true)"
assert_has   "gp3 StorageClass renders when enabled"            'kind: StorageClass' "$out"
assert_has   "gp3 uses xfs (ext4 lost+found breaks kafka log.dir)" 'xfs' "$out"

out="$(render -f "$CHART_DIR/envs/aws.yaml")"
assert_ok    "envs/aws.yaml renders"                            "$out"
assert_lacks "aws: mysql is replaced by RDS"                    'image: mysql:8\.0\.40' "$out"
assert_lacks "aws: redis is replaced by ElastiCache"            'redis-master' "$out"
assert_lacks "aws: minio is replaced by S3"                     'minio/minio' "$out"
assert_lacks "aws: vault is replaced by ExternalSecrets"        'app.kubernetes.io/name: vault' "$out"
assert_has   "aws: gp3 StorageClass is on"                      'kind: StorageClass' "$out"
assert_has   "aws: external-secrets is on"                      'kind: SecretStore' "$out"
assert_has   "aws: kafka still runs in-cluster"                 'apache/kafka:3\.9\.1' "$out"
```

- [ ] **Step 3: Run — expect failure**

- [ ] **Step 4: Write `dashboards-cm.yaml`**

`.Files` is scoped to the chart containing the template, so this glob reads `charts/infra/dashboards/`.

```yaml
{{- if .Values.infra.grafana.enabled }}
{{/*
Custom dashboards (JVM/Kafka/MySQL) -> ConfigMap mounted by Grafana's `custom`
provider. install.sh built this imperatively from `find | --from-file` because
kubectl's embedded kustomize forbids out-of-tree file refs; .Files.Glob has no
such restriction.

Globbing *.json explicitly means a stray file (macOS .DS_Store) never becomes a
ConfigMap key that Grafana would fail to parse on every reload.

Helm's install order puts ConfigMap ahead of Deployment, so the "must exist
before the grafana pod starts" constraint is satisfied structurally.
*/}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-custom-dashboards
  namespace: {{ .Values.global.namespaces.monitoring }}
  labels:
    app.kubernetes.io/part-of: microecom
data:
{{ (.Files.Glob "dashboards/*.json").AsConfig | indent 2 }}
{{- end }}
```

- [ ] **Step 5: Write `storageclass-gp3.yaml` and `external-secrets.yaml`**

Copy `k8s/infra/overlays/aws/storageclass-gp3.yaml` and the two `external-secrets-*.yaml` manifests, wrapping each in its gate:

```yaml
{{- if .Values.infra.storageClassGp3.enabled }}
{{/*
A fresh EKS cluster defaults to gp2 and the gp3 StorageClass must exist before
any PVC or the infra bring-up stalls
(.claude/memory/conventions/eks-gp3-storageclass-must-precede-pvcs.md).

Helm's install order places StorageClass ahead of PersistentVolumeClaim
unconditionally, so inside the chart that hazard is structurally impossible
rather than documented. fsType stays xfs: ext4's lost+found in the root
directory breaks Kafka's log.dir
(.claude/memory/conventions/... / project_kafka_ebs_lostfound).
*/}}
...
{{- end }}
```

`external-secrets.yaml` gets `{{- if .Values.infra.externalSecrets.enabled }}`, with the IRSA role ARN from `{{ .Values.infra.externalSecrets.roleArn }}` and the region from `{{ .Values.infra.externalSecrets.region }}`. Phase 4 wires the actual values.

- [ ] **Step 6: Write `envs/aws.yaml`**

```yaml
# EKS overrides. Written in Phase 2 so the gating can be proven now; first
# exercised for real in Phase 7.
global:
  image:
    registry: ""            # filled from terraform output (ECR registry) by the deploy script
    tag: ""                 # filled from the build's git sha
    pullPolicy: IfNotPresent
  secret:
    backend: externalSecrets
  ingress:
    className: alb

infra:
  # Managed AWS services replace these in-cluster workloads.
  mysql:          { enabled: false }   # RDS
  mysqlReplica:   { enabled: false }   # RDS read replicas
  mysqldExporter: { enabled: false }   # RDS Enhanced Monitoring / Performance Insights
  redis:          { enabled: false }   # ElastiCache
  minio:          { enabled: false }   # S3
  vault:          { enabled: false }   # AWS Secrets Manager via ExternalSecrets

  # Still in-cluster on EKS.
  mongodb:        { enabled: true, storage: 20Gi }
  kafka:          { enabled: true, storage: 50Gi }
  schemaRegistry: { enabled: true }
  kafkaConnect:   { enabled: true }
  kafkaExporter:  { enabled: true }

  storageClassGp3: { enabled: true }
  externalSecrets: { enabled: true, roleArn: "", region: ap-southeast-1 }

  victoriaMetrics:  { enabled: true }
  grafana:          { enabled: true }
  kubeStateMetrics: { enabled: true }
```

- [ ] **Step 7: Run the harness — expect pass**

- [ ] **Step 8: Confirm the ConfigMap has exactly 3 keys**

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  --show-only charts/infra/templates/dashboards-cm.yaml \
  | python3 -c "import sys,yaml;d=yaml.safe_load(sys.stdin);print(sorted(d['data'].keys()))"
```

Expected: the three dashboard filenames, no `.DS_Store`.

- [ ] **Step 9: Commit**

```bash
git add deploy/charts/microecom
git commit -m "feat(deploy): dashboards ConfigMap via .Files.Glob, AWS-gated resources, envs/aws.yaml

Moving storageclass-gp3 into the chart makes the gp3-before-PVC hazard
structurally impossible — Helm's install order puts StorageClass ahead of PVC
unconditionally, so that convention becomes obsolete rather than carried forward.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: `platform.sh`, the Makefile target, and the docs

The chart is complete; this makes it runnable alongside the old path. Nothing here touches `k8s/`.

**Files:**
- Create: `deploy/scripts/platform.sh`
- Modify: `Makefile`
- Modify: `deploy/README.md`
- Read-only source: `k8s/infra/install.sh:1-40`, `deploy/scripts/cluster.sh` (for style and `lib/colors.sh` usage)

**Interfaces:**
- Consumes: the chart from Tasks 1–7.
- Produces: `make k8s-platform` and `make k8s-infra-helm`.

- [ ] **Step 1: Determine this Helm's `--wait` flag form**

Helm 4 changed `--wait` from a boolean to a mode flag on some subcommands. Settle it once rather than discovering it during a 15-minute install:

```bash
helm version --short
helm upgrade --help | grep -E -A3 '^\s+--wait'
```

Use whichever form this binary documents (`--wait` or `--wait=watcher`) consistently in `platform.sh` and the Makefile.

- [ ] **Step 2: Write `platform.sh`**

```bash
#!/usr/bin/env bash
# Cluster-wide platform charts + Helm dependency vendoring.
#
# ingress-nginx and metrics-server stay SEPARATE releases, not umbrella
# dependencies: they are cluster-wide singletons, and on EKS both are replaced
# outright (ALB controller, EKS addon). Bundling them into a release that also
# owns the MySQL data would mean a failed ingress upgrade can touch a database.
#
#   ./deploy/scripts/platform.sh [ENV]      ENV: local-k8s (default) | aws
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/colors.sh
. deploy/scripts/lib/colors.sh

ENV="${1:-local-k8s}"
CHART=deploy/charts/microecom

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

# `helm dependency update` does NOT recurse into subcharts — it must run against
# charts/infra directly. `build` (not `update`) so Chart.lock stays authoritative.
info "vendoring infra subchart dependencies"
helm dependency build "$CHART/charts/infra"

if [ "$ENV" = "aws" ]; then
  warn "aws platform charts (ALB controller, EKS addons) are Phase 7 — skipping"
  exit 0
fi

info "installing ingress-nginx"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace infra --create-namespace \
  --version 4.10.0 \
  -f k8s/infra/values/ingress-nginx.yaml \
  --wait --timeout 5m

# --kubelet-insecure-tls: minikube kubelet serving certs are self-signed.
# InternalIP avoids inter-node hostname resolution issues. Upstream chart uses
# an `args` list, NOT bitnami's extraArgs/apiService.create keys.
info "installing metrics-server"
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace infra \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' \
  --wait --timeout 3m

ok "platform ready"
```

Check the function names in `deploy/scripts/lib/colors.sh` first and use whatever it actually exports; if it has no `info`/`warn`/`ok`, use plain `echo`.

- [ ] **Step 3: Add the Makefile targets**

Place them next to the existing `k8s-infra` target, leaving it untouched.

```make
## k8s-platform: install cluster-wide platform charts + vendor Helm deps
k8s-platform:
	@./deploy/scripts/platform.sh $(or $(ENV),local-k8s)

## k8s-infra-helm: bring up infra via the Helm umbrella chart (Phase 2 path)
##   Runs ALONGSIDE `make k8s-infra` — the kubectl path is still the default.
##   15m timeout: the Confluent images are ~1.8GB and a cold pull alone is ~5.5m.
k8s-infra-helm: k8s-platform
	@helm upgrade --install microecom deploy/charts/microecom \
	  --namespace infra --create-namespace \
	  -f deploy/charts/microecom/envs/$(or $(ENV),local-k8s).yaml \
	  --wait --timeout 15m
```

- [ ] **Step 4: Verify the targets resolve without running them**

```bash
make -n k8s-platform
make -n k8s-infra-helm
bash -n deploy/scripts/platform.sh
```

Expected: both print their recipes; `bash -n` is silent.

- [ ] **Step 5: Document the chart in `deploy/README.md`**

Append a section covering, at minimum:

- The two commands (`make k8s-platform`, `make k8s-infra-helm`) and that `make k8s-infra` is still the default path for this phase.
- **The `--dry-run` keyfile hazard, stated as a rule:** `lookup` returns empty during `helm template` and `helm --dry-run`, so a dry run renders a *fresh* `mongodb-keyfile`. Rendering to read is fine; `helm template … | kubectl apply -f -` against a live cluster rotates the keyfile and breaks the initialized replica set.
- That `helm dependency update` does not recurse into subcharts, so it must target `deploy/charts/microecom/charts/infra` — `platform.sh` does this, which is why `k8s-infra-helm` depends on `k8s-platform`.
- That `charts/infra/charts/*.tgz` is gitignored and rebuilt from `Chart.lock`.
- That `--wait` timeouts must stay ≥ 15m because of the ~1.8 GB Confluent images.
- That `deploy/charts/microecom/tests/render-test.sh` is the fast check and needs no cluster.

- [ ] **Step 6: Commit**

```bash
git add deploy Makefile
git commit -m "feat(deploy): add platform.sh and the k8s-infra-helm target

Runs alongside the existing k8s-infra path; rollback is reverting one target.
ingress-nginx and metrics-server stay separate releases so a failed ingress
upgrade cannot touch the database release.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: End-to-end verification on minikube

Green pods prove little here — the point of the four ordering fixes is that specific services crash without them. This task runs the spec's seven functional checks against a real cluster.

**Cut-over requires a teardown.** The current infra was created by `kubectl apply` plus six standalone Helm releases; adopting those into a new release means fighting `meta.helm.sh/release-name` ownership on every object. All data here is reproduced by `make k8s-bootstrap`, so a rebuild is cheaper. The minikube hostPath PVs are wiped by `k8s-down` anyway.

**Files:**
- Modify: `docs/superpowers/plans/2026-08-02-helm-infra-subchart.md` (tick the boxes)
- Modify: `deploy/README.md` if any step reveals a missing note

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: nothing.

- [ ] **Step 1: Rebuild the cluster**

```bash
make k8s-down
make k8s-cluster-up
```

- [ ] **Step 2: Bring up infra through Helm**

```bash
time make k8s-infra-helm
```

Expected: the release reaches `deployed`. If it times out, check whether pods are merely still pulling the Confluent images before treating it as a failure.

- [ ] **Step 3: Check 1 — the three crash-without-their-initContainers workloads**

```bash
kubectl -n infra get pods -l 'app.kubernetes.io/name in (schema-registry,kafka-connect,kafka-exporter)' \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
```

Expected: all three `READY=true`, `RESTARTS=0`. Each crashes without its initContainers, so this is direct proof rather than a smoke test.

- [ ] **Step 4: Check 2 — replication on both replicas**

```bash
kubectl -n infra logs job/mysql-replication | tail -20
for i in 0 1; do
  kubectl -n infra exec "mysql-replica-$i" -- \
    mysql -uroot -proot -e 'SHOW REPLICA STATUS\G' \
    | grep -E 'Replica_IO_Running:|Replica_SQL_Running:'
done
```

Expected: `Replica_IO_Running: Yes` **and** `Replica_SQL_Running: Yes` for both.

- [ ] **Step 5: Check 3 — dashboards**

```bash
kubectl -n monitoring get configmap grafana-custom-dashboards \
  -o jsonpath='{range .data.*}{"\n"}{end}' | wc -l
kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana
```

Expected: 3 keys, Grafana Running. Then open Grafana and confirm the JVM / Kafka / MySQL dashboards appear under the `Custom` folder.

- [ ] **Step 6: Check 4 — idempotence**

```bash
kubectl -n infra get secret mongodb-keyfile -o jsonpath='{.data.keyfile}' | sha256sum
kubectl -n infra get pods -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount > /tmp/before.txt

make k8s-infra-helm

kubectl -n infra get secret mongodb-keyfile -o jsonpath='{.data.keyfile}' | sha256sum
kubectl -n infra get pods -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt && echo "no restarts"
kubectl -n infra logs job/mysql-replication | grep 'already replicating'
```

Expected: identical keyfile hashes, no restart-count changes, and the Job reporting "already replicating" for both replicas.

- [ ] **Step 7: Check 5 — restart resilience (the property the old script never had)**

```bash
kubectl -n infra delete pod kafka-0
kubectl -n infra get pods -l app.kubernetes.io/name=kafka-exporter -w   # ctrl-c once Ready
```

Expected: `kafka-exporter` blocks in `Init:0/1` while Kafka is down, then goes Ready on its own. Under `install.sh` it would exit and stay dead.

- [ ] **Step 8: Check 6 — AWS gating renders**

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  -f deploy/charts/microecom/envs/aws.yaml > /tmp/aws-render.yaml
grep -cE 'image: mysql:8\.0\.40|redis-master|minio/minio|app.kubernetes.io/name: vault' /tmp/aws-render.yaml
```

Expected: `0`. (Task 7 asserts this too; repeating it here confirms nothing regressed across Tasks 8–9.)

- [ ] **Step 9: Check 7 — the old path still works**

```bash
make k8s-down
make k8s-cluster-up
make k8s-infra
kubectl -n infra get pods
```

Expected: the kubectl path brings everything up exactly as before. This is the rollback guarantee — if it fails, the phase is not done regardless of how well the Helm path works.

- [ ] **Step 10: Record the results and commit**

Tick every checkbox in this plan that the run verified, and add any newly-discovered gotcha to `deploy/README.md`.

```bash
git add docs/superpowers/plans/2026-08-02-helm-infra-subchart.md deploy/README.md
git commit -m "docs(deploy): record Phase 2 E2E verification results

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 11: Hand the push to the user**

The pre-push hook blocks `git push` from the agent shell — the repo overrides `core.hooksPath=.husky/_`, so the global gitleaks hook cannot run. Do not bypass it. Ask the user to run, with the `! ` prefix:

```
! git push -u origin feat/deploy-helm-infra
```
