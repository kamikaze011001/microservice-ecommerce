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

# Filters a render down to the documents of one `kind`. `helm template` emits one
# flat stream, so an unscoped grep asks "does this string appear anywhere in the
# release?" — which has repeatedly passed for the wrong reason. Scope first.
#   usage: out="$(render | docs_of_kind StatefulSet)"
# Latent fragility, not currently triggered: splitting on the literal `\n---\n`
# would fracture a single document if any embedded ConfigMap/Secret data (a
# multi-doc YAML blob, a rendered dashboard JSON with a stray `---` line, etc.)
# contained that exact three-dash line itself. None of this chart's current
# ConfigMap/Secret payloads do. If a future one does, prefer `--show-only` for
# that specific object over trusting this split.
docs_of_kind() {
  awk -v k="kind: $1" 'BEGIN { RS = "\n---\n" } $0 ~ ("(^|\n)" k "([ \t]*$|\n)") { print; print "---" }'
}

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# assert_has <description> <extended-regex> <text>
#
# Uses a here-string, NOT `printf | grep -q`. With `set -o pipefail`, a `grep -q`
# match early in a large `$text` closes the pipe and reads as done, so its
# upstream `printf` — still mid-write — dies of SIGPIPE (exit 141); pipefail then
# reports the pipeline's status as 141, not grep's real 0, and a true match
# reads as FAIL. Surfaced by Task 3: the mongodb keyfile plus three new
# templates pushed a single render past the point where an early match (e.g.
# `kind: Namespace` on line 4) leaves enough trailing output to overrun the
# pipe buffer before `printf` finishes. A here-string has no second process and
# no pipe, so there is nothing for grep to SIGPIPE.
assert_has() {
  if grep -qE -- "$2" <<<"$3"; then ok "$1"; else bad "$1"; fi
}

# assert_lacks <description> <extended-regex> <text>
assert_lacks() {
  if grep -qE -- "$2" <<<"$3"; then bad "$1"; else ok "$1"; fi
}

# assert_ok <description> <text>  — text is a render result; fail if it looks like an error
# Here-string for the same reason as assert_has/assert_lacks above.
assert_ok() {
  if grep -qiE '^Error:|template:.*(error|not defined)' <<<"$2"; then
    bad "$1"
    head -20 <<<"$2" | sed 's/^/       /'
  else
    ok "$1"
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── Phase 3 helpers ─────────────────────────────────────────────────────────

# The apps subchart is gated off by default (side-by-side phase). Every apps
# assertion renders through this instead of render().
apps_render() { render --set apps.enabled=true "$@"; }

# doc_named <kind> <name> <text> — one object, by kind AND metadata.name.
# docs_of_kind alone is not enough here: ten Deployments in one stream means an
# unscoped probe assertion could be satisfied by any of the other nine.
doc_named() {
  docs_of_kind "$1" <<<"$3" | awk -v RS='\n---\n' -v n="$2" '$0 ~ ("(^|\n)  name: " n "([ \t]*$|\n)")'
}

# probe_block <deployment-doc> <liveness|readiness>
# Slices one probe out of a rendered container. The container block's key order
# is fixed by apps.container: ... livenessProbe / readinessProbe / resources.
probe_block() {
  case "$2" in
    liveness)  awk '/livenessProbe:/{f=1} /readinessProbe:/{f=0} f' <<<"$1" ;;
    readiness) awk '/readinessProbe:/{f=1} /resources:/{f=0} f' <<<"$1" ;;
  esac
}

# assert_probe <deployment-name> <liveness|readiness> <field> <expected> <text>
assert_probe() {
  local doc block actual
  doc="$(doc_named Deployment "$1" "$5")"
  block="$(probe_block "$doc" "$2")"
  actual="$(awk -v f="$3:" '$1 == f { print $2; exit }' <<<"$block")"
  if [ "$actual" = "$4" ]; then
    ok   "$1 $2 $3 = $4"
  else
    bad  "$1 $2 $3 is '${actual:-<none>}', expected '$4'"
  fi
}

# ── Task 1: scaffold and gating ─────────────────────────────────────────────
section "scaffold and dependency gating"

out="$(render)"
assert_ok    "default values render"                            "$out"
ns="$(printf '%s\n' "$out" | docs_of_kind Namespace)"
svc="$(printf '%s\n' "$out" | docs_of_kind Service)"
sts="$(printf '%s\n' "$out" | docs_of_kind StatefulSet)"
assert_has   "apps namespace is created"                        'kind: Namespace' "$out"
assert_has   "apps namespace name"                              'name: apps' "$out"
assert_has   "monitoring namespace name"                        'name: monitoring' "$out"
# Scoped to Namespace docs: mongodb's keyfile-bootstrap sidecar container is
# literally named `- name: bootstrap`, so the unscoped form stayed green even
# with global.namespaces.bootstrap renamed away from "bootstrap" (RED-proven).
assert_has   "bootstrap namespace name"                         '^  name: bootstrap$' "$ns"
assert_lacks "infra namespace is NOT templated (--create-namespace owns it)" \
                                                                '^  name: infra$' "$out"
# Scoped to Service docs: vault's ServiceAccount, ClusterRoleBinding, and
# StatefulSet also render `name: vault`, so the unscoped form stayed green even
# with the vault Service itself disabled (server.service.enabled=false,
# RED-proven) — the exact failure mode this assertion's own description names.
assert_has   "vault Service keeps its name (apps hardcode vault.infra.svc)" '^  name: vault$' "$svc"
assert_lacks "no release-name prefix leaked onto vault"         'name: microecom-vault' "$out"
# Scoped to Service docs: grafana's ServiceAccount/Secret/ConfigMap/Role/
# RoleBinding/Deployment/Ingress independently render `name: grafana`, so the
# unscoped form stayed green even with grafana's own Service disabled
# (service.enabled=false, RED-proven).
assert_has   "grafana keeps its name"                           '^  name: grafana$' "$svc"
# Scoped to Service docs: VictoriaMetrics' ServiceAccount/ClusterRole/
# ClusterRoleBinding are gated independently (rbac.create/serviceAccount.create,
# not server.enabled) and also render `name: vmsingle`, so the unscoped form
# stayed green even with the vmsingle Service AND StatefulSet — the actual
# datasource endpoint grafana talks to — disabled (server.enabled=false,
# RED-proven).
assert_has   "vmsingle keeps its name (grafana datasource)"     '^  name: vmsingle$' "$svc"
# The Service existing doesn't prove the server pod exists either — assert the
# StatefulSet independently.
assert_has   "vmsingle StatefulSet exists (server pod, not just its Service)" '^  name: vmsingle$' "$sts"
assert_has   "kube-state-metrics keeps its scrape label"        'app\.kubernetes\.io/name: kube-state-metrics' "$out"
assert_lacks "alias did not leak into the KSM name label"       'app\.kubernetes\.io/name: kubeStateMetrics' "$out"
# Anchored to the name label on purpose. A bare `kubeStateMetrics` can never
# pass: `alias:` also rewrites `.Chart.Name`, which the upstream chart bakes
# into its cosmetic `helm.sh/chart` label, and Helm names the in-memory
# subchart directory after the alias so it appears in `# Source:` comments too.
# Neither is addressable by any override, and neither is what VM scrapes on.

# Our app-registry global is `global.appImage.registry`, NOT `global.image.registry`.
# Helm propagates `global:` into EVERY subchart, vendored upstream ones included,
# and `global.image.registry` is an upstream convention: victoria-metrics-common's
# `vm.internal.image` falls back to it whenever the per-app `image.registry` is
# empty. Under the old key vmsingle rendered as
# `localhost:5000/victoriametrics/victoria-metrics:...` → ImagePullBackOff → and
# because `helm --wait` waits for every resource before post-install hooks run,
# the mysql-replication hook Job was never created and the release hung at
# `pending-install`. 109 render assertions missed it because none looked at an
# image registry. No infra workload should ever carry the local registry — each
# pins its upstream image explicitly.
#
# PHASE 3 (done): the apps subchart's images legitimately ARE localhost:5000/...,
# so this assertion is now scoped to an apps-DISABLED render. `$out` above comes
# from render(), and the umbrella defaults apps.enabled=false — that IS the
# scoping, and it is enforced rather than incidental by the paired assertion in
# the apps section below, which requires apps images TO carry the registry. If
# apps.enabled ever flips to true by default, that pairing makes the conflict
# fail loudly instead of quietly weakening this check.
assert_lacks "no infra image is rewritten to the local registry (apps off)" \
                                                                  'image: .*localhost:5000/' "$out"
assert_has   "vmsingle keeps its upstream image registry"         'image: victoriametrics/victoria-metrics:' "$out"

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
# Scoped to grafana's own Deployment doc: roughly a dozen other objects (VM,
# kube-state-metrics, the dashboards ConfigMap) legitimately render
# `namespace: monitoring` too, so the unscoped form stayed green even with
# grafana's own objects moved out of that namespace via namespaceOverride
# (RED-proven), which would break its VictoriaMetrics datasource DNS lookup.
grafana_dep="$(printf '%s\n' "$out" | docs_of_kind Deployment \
               | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: grafana(\n|$)/')"
assert_has   "grafana lands in the monitoring namespace"        '^  namespace: monitoring$' "$grafana_dep"

# ── Task 2: MySQL family ────────────────────────────────────────────────────
section "mysql family"

out="$(render)"
sts="$(printf '%s\n' "$out" | docs_of_kind StatefulSet)"
svc="$(printf '%s\n' "$out" | docs_of_kind Service)"
# Scoped to StatefulSet docs: the bare name `mysql` also names the mysql
# Service, so an unscoped grep stays green even if the StatefulSet is deleted.
assert_has   "mysql StatefulSet name is exactly 'mysql'"        '^  name: mysql$' "$sts"
# Scoped to Service docs: the bare name `mysql-replica-headless` is unique
# today, but anchor + scope it so it matches its neighbours below.
assert_has   "mysql-replica-headless Service exists"            '^  name: mysql-replica-headless$' "$svc"
# Scoped to Service docs: the bare name `mysql-replica` also names the
# mysql-replica StatefulSet, so an unscoped grep can't detect this Service
# (the risky Task 2 merge of k8s/infra/manifests/mysql-replica-service.yaml
# into charts/infra/templates/mysql-replica.yaml) going missing.
assert_has   "mysql-replica Service exists"                     '^  name: mysql-replica$' "$svc"
# Scoped to StatefulSet docs so this can't be satisfied by mysqlReplica.storage
# or mongodb.storage (both also 4Gi in values.yaml) once mongodb is templated.
assert_has   "mysql storage is 4Gi (default, StatefulSet only)" 'storage: 4Gi' "$sts"
# Scoped to the mysql-credentials Secret doc specifically, mirroring the
# keyfile_sec pattern above: the replication hook Job references
# ${MYSQL_REPL_USER} as a shell variable in its script body, an unrelated
# occurrence of the same literal string that kept the unscoped form green
# even with the key deleted from the Secret's stringData (RED-proven against
# a scratch copy).
sec="$(printf '%s\n' "$out" | docs_of_kind Secret)"
mysql_cred_sec="$(printf '%s' "$sec" | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: mysql-credentials(\n|$)/')"
assert_has   "mysql-credentials carries the repl user"          'MYSQL_REPL_USER' "$mysql_cred_sec"
assert_has   "primary exporter targets the mysql FQDN"          'host=mysql\.infra\.svc\.cluster\.local' "$out"
assert_has   "replica-0 exporter targets pod-0 via headless"    'host=mysql-replica-0\.mysql-replica-headless\.infra\.svc\.cluster\.local' "$out"
assert_has   "replica-1 exporter targets pod-1 via headless"    'host=mysql-replica-1\.mysql-replica-headless\.infra\.svc\.cluster\.local' "$out"

# Wiring check for the "mysql storage is 4Gi" assertion above: prove the
# override is a values change reaching mysql's own volumeClaimTemplate, not a
# coincidence of two subcharts sharing a default. Both halves — mysql moves,
# mysql-replica doesn't — must hold for this to pass.
out="$(render --set infra.mysql.storage=7Gi)"
sts="$(printf '%s\n' "$out" | docs_of_kind StatefulSet)"
mysql_sts="$(printf '%s' "$sts"         | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: mysql(\n|$)/')"
mysql_replica_sts="$(printf '%s' "$sts" | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: mysql-replica(\n|$)/')"
mysql_storage="$(printf '%s\n' "$mysql_sts"         | grep -oE 'storage: [A-Za-z0-9]+' | head -1)"
mysql_replica_storage="$(printf '%s\n' "$mysql_replica_sts" | grep -oE 'storage: [A-Za-z0-9]+' | head -1)"
wiring="mysql:${mysql_storage#storage: } mysql-replica:${mysql_replica_storage#storage: }"
assert_has   "infra.mysql.storage=7Gi lands only on mysql's PVC (mysql-replica stays 4Gi)" \
                                                                  '^mysql:7Gi mysql-replica:4Gi$' "$wiring"

out="$(render --set infra.mysqlReplica.replicas=3)"
assert_has   "replicas=3 generates a third exporter"            'name: mysqld-exporter-replica-2' "$out"

out="$(render --set infra.mysql.enabled=false --set infra.mysqlReplica.enabled=false --set infra.mysqldExporter.enabled=false)"
# NOT `kind: StatefulSet` — mongodb, kafka and minio are StatefulSets too and are
# still enabled here, so that assertion would fail for the wrong reason.
assert_lacks "mysql gated off"                                  'image: mysql:8\.0\.40' "$out"
# NOT the bare string `mysqld-exporter` — victoriaMetrics' own scrape config
# (charts/infra/values.yaml) hardcodes a `job_name: mysqld-exporter` and target
# hostnames containing that literal text, and VM stays enabled here, so that
# assertion would fail for the wrong reason regardless of this gate.
assert_lacks "mysqld-exporter gated off"                        'image: prom/mysqld-exporter:v0\.16\.0' "$out"

out="$(render --set global.namespaces.infra=data)"
assert_has   "namespace is a values change, not a literal"      'host=mysql\.data\.svc\.cluster\.local' "$out"

# ── Task 3: mongodb, redis, minio ───────────────────────────────────────────
section "mongodb / redis / minio"

out="$(render)"
sts="$(printf '%s\n' "$out" | docs_of_kind StatefulSet)"
svc="$(printf '%s\n' "$out" | docs_of_kind Service)"
sec="$(printf '%s\n' "$out" | docs_of_kind Secret)"
ing="$(printf '%s\n' "$out" | docs_of_kind Ingress)"
assert_has   "redis Service is named redis-master (vault-seed contract)" '^  name: redis-master$' "$svc"
assert_has   "mongodb Service exists"                           '^  name: mongodb$' "$svc"
assert_has   "mongodb StatefulSet exists"                       '^  name: mongodb$' "$sts"
assert_has   "minio Service exists"                             '^  name: minio$' "$svc"
# Scoped to Secret docs: the mongodb StatefulSet's keyfile volume references
# `secretName: mongodb-keyfile`, so an unscoped grep stays green with the
# Secret itself deleted — it could never fail.
assert_has   "mongodb-keyfile Secret is rendered"               '^  name: mongodb-keyfile$' "$sec"
# Scoped to the mongodb-keyfile Secret doc specifically: an unscoped grep
# against $sec goes silently vacuous the moment any other Secret carries this
# annotation.
keyfile_sec="$(printf '%s' "$sec" | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: mongodb-keyfile(\n|$)/')"
assert_has   "keyfile carries resource-policy keep"             'helm\.sh/resource-policy: keep' "$keyfile_sec"
# Scoped to the minio-named Ingress doc: grafana and vmsingle also render
# ingressClassName: nginx (charts/infra/values.yaml, hardcoded not templated
# from global.ingress.className), so an unscoped grep against $ing passes even
# with minio-ingress.yaml's logic missing entirely.
minio_ing="$(printf '%s' "$ing" | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: minio(\n|$)/')"
assert_has   "minio ingress uses the media host from values"    'host: media\.microecom\.local' "$minio_ing"
assert_has   "minio ingress uses the ingress class from values" 'ingressClassName: nginx' "$minio_ing"
# Scoped, and backed by the override below: kafka's default storage is also
# 10Gi, so an unscoped check goes vacuous the moment Task 4 lands.
assert_has   "minio storage is 10Gi (default, StatefulSet only)" 'storage: 10Gi' "$sts"

out="$(render --set infra.minio.storage=11Gi)"
minio_sts="$(printf '%s\n' "$out" | docs_of_kind StatefulSet \
             | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: minio(\n|$)/')"
assert_has   "infra.minio.storage reaches minio's own PVC"      'storage: 11Gi' "$minio_sts"

out="$(render --set global.ingress.hosts.media=media.example.com --set global.ingress.className=alb)"
ing="$(printf '%s\n' "$out" | docs_of_kind Ingress)"
assert_has   "media host is a values change"                    'host: media\.example\.com' "$ing"
assert_has   "ingress class is a values change"                 'ingressClassName: alb' "$ing"

out="$(render --set infra.redis.enabled=false)"
# NOT the bare string `redis-master` — it is a hostname in app config and in
# victoriaMetrics' scrape targets, both of which stay enabled here.
assert_lacks "redis gated off"                                  'image: redis:7\.4-alpine' "$out"
assert_lacks "redis Service gated off"                          '^  name: redis-master$' \
                                                                "$(printf '%s\n' "$out" | docs_of_kind Service)"

out="$(render --set infra.minio.enabled=false)"
assert_lacks "minio gated off"                                  'image: minio/minio' "$out"
assert_lacks "minio ingress goes with it"                       'media\.microecom\.local' "$out"

# ── Task 4: kafka + exporter ────────────────────────────────────────────────
section "kafka"

out="$(render)"
sts="$(printf '%s\n' "$out" | docs_of_kind StatefulSet)"
svc="$(printf '%s\n' "$out" | docs_of_kind Service)"
kafka_sts="$(printf '%s\n' "$sts" | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: kafka(\n|$)/')"
exporter="$(printf '%s\n' "$out" | docs_of_kind Deployment \
            | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: kafka-exporter(\n|$)/')"
assert_has   "kafka Service exists"                             '^  name: kafka$' "$svc"
assert_has   "kafka StatefulSet exists"                         '^  name: kafka$' "$sts"
assert_has   "kafka client port"                                'name: client' "$kafka_sts"
# Scoped and override-proved below: minio's default storage is also 10Gi.
assert_has   "kafka storage is 10Gi (default, kafka's own STS)" 'storage: 10Gi' "$kafka_sts"
# The next three are scoped to the exporter's own Deployment. Task 5 gives
# schema-registry and kafka-connect the same `wait-for-kafka` initContainer,
# the same image and the same bootstrap address, so unscoped these would all
# stay green with kafka-exporter deleted outright.
assert_has   "kafka-exporter has a wait-for-kafka initContainer" 'name: wait-for-kafka' "$exporter"
assert_has   "wait-for-kafka reuses the kafka image"            'image: apache/kafka:3\.9\.1' "$exporter"
assert_has   "wait targets the kafka FQDN"                      'kafka\.infra\.svc\.cluster\.local:9092' "$exporter"

out="$(render --set infra.kafka.storage=11Gi)"
kafka_sts="$(printf '%s\n' "$out" | docs_of_kind StatefulSet \
             | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: kafka(\n|$)/')"
assert_has   "infra.kafka.storage reaches kafka's own PVC"      'storage: 11Gi' "$kafka_sts"

out="$(render --set infra.kafka.enabled=false --set infra.kafkaExporter.enabled=false)"
# NOT `apache/kafka` — schema-registry and kafka-connect are still enabled here
# and their wait/compact initContainers reuse that image (Task 5).
assert_lacks "kafka StatefulSet gated off"                      '^  name: kafka$' \
                                                                "$(printf '%s\n' "$out" | docs_of_kind StatefulSet)"
assert_lacks "kafka-exporter gated off"                         'image: danielqsj/kafka-exporter:v1\.8\.0' "$out"

# ── Task 5: schema-registry + kafka-connect ─────────────────────────────────
section "schema-registry / kafka-connect"

out="$(render)"
svc="$(printf '%s\n' "$out" | docs_of_kind Service)"
dep="$(printf '%s\n' "$out" | docs_of_kind Deployment)"
sr="$(printf '%s\n' "$dep" | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: schema-registry(\n|$)/')"
kc="$(printf '%s\n' "$dep" | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: kafka-connect(\n|$)/')"
assert_has   "schema-registry Service exists"                   '^  name: schema-registry$' "$svc"
assert_has   "kafka-connect Service exists"                     '^  name: kafka-connect$' "$svc"
# kafka-connect carried a bare `app:` label until an E2E run caught it — the
# plan's own Check 1 selector
# (`-l 'app.kubernetes.io/name in (schema-registry,kafka-connect,kafka-exporter)'`)
# returned two pods instead of three. Its Service selector matched the pod
# template either way, so nothing broke; a cross-cutting selector just skipped
# this one workload silently. Scoped to the kafka-connect Deployment document,
# since `app:` is a perfectly normal label in the vendored upstream charts.
assert_has   "kafka-connect uses the chart's standard name label" \
                                                                'app\.kubernetes\.io/name: kafka-connect' "$kc"
assert_lacks "kafka-connect has no bare app: label"             '^ *app: kafka-connect$' "$kc"
# Both workloads get `ensure-compacted`, `cleanup.policy=compact` and
# `enableServiceLinks: false` from the same helper, so an unscoped assertion is
# satisfied by whichever pod still has it — each is asserted per workload.
# NOTE: the brief's original single-regex assertion here was
# 'TOPICS.*_schemas' against $sr. `.` never matches a newline under
# `grep -E` (verified: `printf 'foo TOPICS\nbar _schemas\n' | grep -qE
# 'TOPICS.*_schemas'` exits 1), and the ensure-compacted helper always
# renders `- name: TOPICS` and `value: "..."` on separate lines — so that
# regex can never match regardless of the template. Split into two
# same-scope assertions that verify the same intent (schema-registry's
# TOPICS env var is set to _schemas) without requiring a single-line match.
assert_has   "schema-registry ensure-compacted carries a TOPICS env var" 'name: TOPICS' "$sr"
assert_has   "schema-registry compacts _schemas"                'value: "_schemas"' "$sr"
assert_has   "schema-registry has ensure-compacted"             'name: ensure-compacted' "$sr"
assert_has   "schema-registry applies cleanup.policy=compact"   'cleanup\.policy=compact' "$sr"
assert_has   "schema-registry disables service links"           'enableServiceLinks: false' "$sr"
assert_has   "kafka-connect compacts its three internal topics" 'connect-configs connect-offsets connect-status' "$kc"
assert_has   "kafka-connect has ensure-compacted"               'name: ensure-compacted' "$kc"
assert_has   "kafka-connect waits for schema-registry"          'name: wait-for-schema-registry' "$kc"
assert_has   "kafka-connect keeps its install-plugins step"     'name: install-plugins' "$kc"
assert_has   "kafka-connect disables service links"             'enableServiceLinks: false' "$kc"

out="$(render --set infra.schemaRegistry.enabled=false --set infra.kafkaConnect.enabled=false)"
assert_lacks "confluent workloads gated off"                    'confluentinc/cp-' "$out"

# ── Task 6: replication hook ────────────────────────────────────────────────
section "mysql replication hook"

out="$(render)"
# Every assertion here is scoped to the Job. Unscoped, all of them are
# unsound: the mysql StatefulSet carries the same image, mysqld-exporter
# (Task 2) already targets both replica FQDNs, and — worst — the
# `mysql-credentials` Secret legitimately contains `replica_ecommerce`, so
# `assert_lacks` against the full render can never pass.
job="$(printf '%s\n' "$out" | docs_of_kind Job)"
assert_has   "replication Job is a post-install/post-upgrade hook" 'helm\.sh/hook: post-install,post-upgrade' "$job"
assert_has   "hook weight is 5"                                 'helm\.sh/hook-weight: "5"' "$job"
assert_has   "hook deletes before re-creation"                  'hook-delete-policy: before-hook-creation' "$job"
assert_has   "job uses the pinned mysql image"                  'image: mysql:8\.0\.40' "$job"
assert_has   "credentials come from the Secret, not literals"   'secretRef' "$job"
assert_lacks "no hardcoded replication password in the Job"     'replica_ecommerce' "$job"
assert_has   "job enumerates replica-0"                         'mysql-replica-0\.mysql-replica-headless' "$job"
assert_has   "job enumerates replica-1"                         'mysql-replica-1\.mysql-replica-headless' "$job"
assert_has   "idempotence check on replication_connection_status" 'replication_connection_status' "$job"
assert_has   "activeDeadlineSeconds is derived to cover one full graceful attempt (default 960 = (1+2 hosts)*300 + 60 slack)" 'activeDeadlineSeconds: 960' "$job"
assert_has   "WAIT_TIMEOUT is wired as a real env var from values, not just a shell default" 'name: WAIT_TIMEOUT' "$job"
assert_has   "wait_for has a bounded WAIT_TIMEOUT default"      'WAIT_TIMEOUT="\$\{WAIT_TIMEOUT:-300\}"' "$job"
assert_has   "wait_for reports a readable error when WAIT_TIMEOUT is reached" 'ERROR: \$\{host\} unreachable after \$\{WAIT_TIMEOUT\}s' "$job"

out="$(render --set infra.mysqlReplica.enabled=false)"
assert_lacks "hook gated off with the replicas"                 'mysql-replication' "$out"

# ── Task 7: dashboards + AWS-gated resources ────────────────────────────────
section "dashboards / aws-gated"

out="$(render)"
# Scoped to the ConfigMap itself: `grafana-custom-dashboards` is also the value
# of grafana.dashboardsConfigMaps.custom in charts/infra/values.yaml, so the
# string appears in grafana's own rendered objects whether or not this
# ConfigMap exists — and `namespace: monitoring` is on dozens of objects.
cm="$(printf '%s\n' "$out" | docs_of_kind ConfigMap \
      | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: grafana-custom-dashboards(\n|$)/')"
assert_has   "dashboards ConfigMap exists"                      '^  name: grafana-custom-dashboards$' "$cm"
assert_has   "dashboards land in the monitoring namespace"      '^  namespace: monitoring$' "$cm"
assert_lacks "gp3 StorageClass is off by default"               'kind: StorageClass' "$out"
# NOT 'kind: SecretStore' — the ESO resource is ClusterSecretStore (cluster-
# scoped, shared across every service namespace; see external-secrets.yaml's
# own comment on why). 'kind: SecretStore' is a substring that can never match
# 'kind: ClusterSecretStore' (the text right after "kind: " is "Cluster", not
# "Secret"), which would make this assert_lacks vacuously true forever —
# instead assert on the real kind so a regression is actually catchable.
assert_lacks "external-secrets is off by default"               'kind: ClusterSecretStore' "$out"

# mysqld-exporter scrape job must use endpoint discovery, not a static target
# list: envs/aws.yaml disables mysqldExporter (RDS replaces it) but leaves
# victoriaMetrics enabled, and the exporter's own instance list already varies
# with mysqlReplica.replicas, so a hardcoded target is wrong in both dimensions.
# Each `mysqld-exporter-<instance>.infra.svc.cluster.local:9104` FQDN appears
# ONLY inside a static_configs target list (see mysqld-exporter.yaml's Service/
# Deployment, which never render the FQDN form) — a precise, non-vacuous probe.
assert_lacks "no hardcoded mysqld-exporter primary target (default render)" \
                                                                'mysqld-exporter-primary\.infra\.svc\.cluster\.local:9104' "$out"
assert_lacks "no hardcoded mysqld-exporter replica-0 target (default render)" \
                                                                'mysqld-exporter-replica-0\.infra\.svc\.cluster\.local:9104' "$out"
assert_lacks "no hardcoded mysqld-exporter replica-1 target (default render)" \
                                                                'mysqld-exporter-replica-1\.infra\.svc\.cluster\.local:9104' "$out"
# Scoped to the mysqld-exporter job's own stanza inside the embedded
# scrape_configs YAML text — `kubernetes_sd_configs` and `role: endpoints` are
# also used by spring-actuator/kubelet-cadvisor/kube-state-metrics, so an
# unscoped assert_has would pass regardless of what THIS job does.
mysqld_job="$(printf '%s\n' "$out" | awk '
  /^    - job_name: mysqld-exporter$/ { flag=1; print; next }
  flag && (/^    - job_name:/ || /^---$/ || /^$/) { flag=0; next }
  flag { print }
')"
assert_has   "mysqld-exporter scrape job still exists"          'job_name: mysqld-exporter' "$mysqld_job"
assert_has   "mysqld-exporter job discovers endpoints, not static_configs" 'kubernetes_sd_configs' "$mysqld_job"
assert_has   "mysqld-exporter job discovery role is endpoints"  'role: endpoints' "$mysqld_job"
assert_lacks "mysqld-exporter job no longer uses static_configs" 'static_configs' "$mysqld_job"
assert_has   "mysqld-exporter relabels the pod's mysql-instance label into instance" \
                                                                '__meta_kubernetes_pod_label_mysql_instance' "$mysqld_job"

out="$(render --set infra.storageClassGp3.enabled=true)"
sc="$(printf '%s\n' "$out" | docs_of_kind StorageClass)"
assert_has   "gp3 StorageClass renders when enabled"            '^  name: gp3$' "$sc"
# NOT a bare `xfs` — the source manifest carries a long comment explaining why
# xfs, which the render preserves, so `xfs` stays green with the parameter
# dropped. Assert the parameter key itself.
assert_has   "gp3 uses xfs (ext4 lost+found breaks kafka log.dir)" 'csi\.storage\.k8s\.io/fstype: xfs' "$sc"

out="$(render -f "$CHART_DIR/envs/aws.yaml")"
assert_ok    "envs/aws.yaml renders"                            "$out"
# Each keys on the workload's image, not its name: `redis-master` and
# `mysql-replica` are hostnames in app config and in victoriaMetrics' scrape
# targets, which stay enabled on AWS.
assert_lacks "aws: mysql is replaced by RDS"                    'image: mysql:8\.0\.40' "$out"
assert_lacks "aws: redis is replaced by ElastiCache"            'image: redis:7\.4-alpine' "$out"
assert_lacks "aws: minio is replaced by S3"                     'image: minio/minio' "$out"
assert_lacks "aws: vault is replaced by ExternalSecrets"        'app\.kubernetes\.io/name: vault' "$out"
assert_has   "aws: gp3 StorageClass is on"                      'kind: StorageClass' "$out"
# See the "external-secrets is off by default" note above: the real kind is
# ClusterSecretStore, not SecretStore.
assert_has   "aws: external-secrets is on"                      'kind: ClusterSecretStore' "$out"
# Scoped to the kafka StatefulSet. `apache/kafka:3.9.1` is ALSO the image of the
# wait-for-kafka (x3) and ensure-compacted (x2) initContainers, and those hang off
# kafkaExporter / schemaRegistry / kafkaConnect, all of which stay enabled on AWS.
# Verified: rendering with `--set infra.kafka.enabled=false` still yields 5 hits for
# that image, so the unscoped form passes with the broker gone.
kafka_sts="$(printf '%s\n' "$out" | docs_of_kind StatefulSet \
             | awk -v RS='\n---\n' '$0 ~ /(^|\n)  name: kafka(\n|$)/')"
assert_has   "aws: kafka still runs in-cluster"                 'image: apache/kafka:3\.9\.1' "$kafka_sts"

# envs/aws.yaml sets mysqldExporter.enabled=false (RDS Enhanced Monitoring
# replaces it) but leaves victoriaMetrics enabled — before the fix, VM's
# scrape config still hardcoded these three now-nonexistent targets, so it
# would scrape nothing forever and the mysql.json dashboard would be blank.
# Endpoint discovery self-gates: no exporter Services on AWS → no targets.
assert_lacks "aws: no hardcoded mysqld-exporter primary target"   'mysqld-exporter-primary\.infra\.svc\.cluster\.local:9104' "$out"
assert_lacks "aws: no hardcoded mysqld-exporter replica-0 target" 'mysqld-exporter-replica-0\.infra\.svc\.cluster\.local:9104' "$out"
assert_lacks "aws: no hardcoded mysqld-exporter replica-1 target" 'mysqld-exporter-replica-1\.infra\.svc\.cluster\.local:9104' "$out"

# ── Task 8: Makefile --timeout <-> hook activeDeadlineSeconds coupling ─────
section "Makefile --timeout / hook activeDeadlineSeconds drift guard"

# `make k8s-infra-helm`'s outer `helm --wait --timeout` is a Makefile literal;
# the mysql-replication hook Job's activeDeadlineSeconds is derived from
# .Values.mysqlReplica.{replicas,waitTimeout}. Helm's `--wait` blocks on every
# OTHER resource going Ready (cold Confluent image pull ~330s) BEFORE the
# post-install hook Job is even created, so the two windows are additive: the
# Makefile timeout must cover activeDeadlineSeconds + that cold-pull margin,
# or Helm abandons the wait before the hook can ever emit its own readable
# "ERROR: <host> unreachable after Ns" diagnostic. Parsed out of the checked-in
# files (not hardcoded here) so a future change to either side that lets them
# drift apart fails loudly instead of silently reintroducing that bug.
repo_root="$(cd "$CHART_DIR/../../.." && pwd)"
k8s_infra_helm_recipe="$(awk '/^k8s-infra-helm:/{flag=1} flag{print} flag && /^$/{exit}' "$repo_root/Makefile")"
timeout_token="$(printf '%s\n' "$k8s_infra_helm_recipe" | grep -oE -- '--timeout [0-9]+[hms]' | grep -oE '[0-9]+[hms]$' | head -1)"
case "$timeout_token" in
  *h) helm_timeout_s=$(( ${timeout_token%h} * 3600 )) ;;
  *m) helm_timeout_s=$(( ${timeout_token%m} * 60 )) ;;
  *s) helm_timeout_s=$(( ${timeout_token%s} )) ;;
  *)  helm_timeout_s="" ;;
esac

out="$(render)"
job="$(printf '%s\n' "$out" | docs_of_kind Job)"
active_deadline_s="$(printf '%s\n' "$job" | grep -oE 'activeDeadlineSeconds: [0-9]+' | grep -oE '[0-9]+$' | head -1)"
cold_pull_margin_s=330
required_s=$(( ${active_deadline_s:-0} + cold_pull_margin_s ))

if [ -n "$timeout_token" ] && [ -n "$active_deadline_s" ] && [ "$helm_timeout_s" -ge "$required_s" ]; then
  ok "Makefile k8s-infra-helm --timeout (${helm_timeout_s}s) covers hook activeDeadlineSeconds (${active_deadline_s}s) + ${cold_pull_margin_s}s cold-pull margin (need >= ${required_s}s)"
else
  bad "Makefile k8s-infra-helm --timeout (${helm_timeout_s:-0}s, parsed '${timeout_token:-<none>}') is LESS THAN hook activeDeadlineSeconds (${active_deadline_s:-<none>}s) + ${cold_pull_margin_s}s cold-pull margin (need >= ${required_s}s) -- raise the Makefile's --timeout or lower mysqlReplica.replicas/waitTimeout so they stay in sync"
fi

# ── Phase 3 / Task 1: apps subchart gating and Deployments ──────────────────
section "apps subchart — gating and Deployments"

infra_only="$(render)"
assert_lacks "apps subchart is OFF by default (side-by-side phase)" \
             '^  name: order-service$' "$(docs_of_kind Deployment <<<"$infra_only")"

apps_out="$(apps_render)"
assert_ok    "apps.enabled=true renders"                          "$apps_out"

apps_deploys="$(docs_of_kind Deployment <<<"$apps_out")"
# Asserted by NAME, not by count: the stream also carries infra Deployments, so a
# count would flip to a false red the day infra gains or loses one.
for s in authorization-server bff-service frontend gateway inventory-service \
         mock-paypal-service orchestrator-service order-service payment-service \
         product-service; do
  assert_has "Deployment rendered: $s" "^  name: ${s}\$" "$apps_deploys"
done

# Pairs with the infra-only assertion above: apps images MUST carry the local
# registry. Together the two pin the scoping in both directions.
gw="$(doc_named Deployment gateway "$apps_out")"
assert_has   "gateway image comes from the local registry" \
             'image: localhost:5000/gateway:dev' "$gw"

# ── deepCopy contamination guard (design spec §3 rule 1) ────────────────────
# `range` over a map iterates in SORTED KEY ORDER, so without deepCopy each
# service's overrides mutate .Values.defaults in place and leak into every
# service sorting after it — and each later override compounds on the last.
# gateway (4th of 10) leaks initialDelaySeconds:45; mock-paypal-service (6th)
# then overwrites that with 30; so order-service (8th) inherits 30, NOT 45.
# Asserting order-service still gets its own 60 fails the moment deepCopy is
# dropped, whichever value happens to be the one that leaks.
assert_probe order-service liveness initialDelaySeconds 60 "$apps_out"
assert_probe gateway       liveness initialDelaySeconds 45 "$apps_out"
assert_probe gateway       readiness initialDelaySeconds 25 "$apps_out"

# Per-service transcription checks (design spec §3 table).
assert_probe mock-paypal-service liveness  initialDelaySeconds 30 "$apps_out"
assert_probe mock-paypal-service readiness initialDelaySeconds 15 "$apps_out"
assert_probe frontend            liveness  initialDelaySeconds 10 "$apps_out"
assert_probe frontend            readiness initialDelaySeconds 2  "$apps_out"
# The base frontend readinessProbe omits failureThreshold; the merge supplies an
# explicit inherited 6 (design spec §5, a deliberate stated change).
assert_probe frontend            readiness failureThreshold    6  "$apps_out"

# managementPort is listed per service, never derived. authorization-server and
# gateway break the `port + 10000` pattern; deriving would point their probes at
# dead ports and both would fail readiness forever with a clean-looking values file.
auth="$(doc_named Deployment authorization-server "$apps_out")"
assert_has   "authorization-server management port is 19091, not 16991" \
             'containerPort: 19091' "$auth"
assert_lacks "authorization-server management port was not derived" \
             'containerPort: 16666' "$auth"
assert_has   "gateway management port is 19093, not 16868" 'containerPort: 19093' "$gw"
assert_lacks "gateway management port was not derived"     'containerPort: 16868' "$gw"

# env: null semantics — mergo would have silently kept these.
mock="$(doc_named Deployment mock-paypal-service "$apps_out")"
assert_lacks "mock-paypal-service does not inherit VAULT_TOKEN (null unset)" \
             'VAULT_TOKEN' "$mock"
assert_lacks "mock-paypal-service does not inherit SPRING_CLOUD_VAULT_URI" \
             'SPRING_CLOUD_VAULT_URI' "$mock"
assert_has   "mock-paypal-service keeps its own JAVA_OPTS (no G1GC)" \
             'value: "-XX:MaxRAMPercentage=75.0"' "$mock"
fe="$(doc_named Deployment frontend "$apps_out")"
assert_lacks "frontend has no env block at all"            '^          - name: JAVA_OPTS$' "$fe"
assert_lacks "frontend has no management port"             'name: management' "$fe"

# gateway is the only service with SPRING_PROFILES_ACTIVE.
assert_has   "gateway sets SPRING_PROFILES_ACTIVE=k8s"     'SPRING_PROFILES_ACTIVE' "$gw"
assert_lacks "order-service does not set SPRING_PROFILES_ACTIVE" \
             'SPRING_PROFILES_ACTIVE' "$(doc_named Deployment order-service "$apps_out")"

# extraPorts, envFrom, serviceAccountName hatches.
inv="$(doc_named Deployment inventory-service "$apps_out")"
assert_has   "inventory-service exposes grpc 9090"         'containerPort: 9090' "$inv"
assert_has   "authorization-server has envFrom app-secrets" 'name: app-secrets' "$auth"
assert_lacks "order-service has no envFrom"                'envFrom' "$(doc_named Deployment order-service "$apps_out")"
assert_has   "gateway uses the gateway ServiceAccount"     'serviceAccountName: gateway' "$gw"

# Resources, sampled across the spread of the §3 table.
assert_has   "authorization-server cpu limit is 2000m"     'cpu: 2000m' "$auth"
assert_has   "frontend memory request is 32Mi"             'memory: 32Mi' "$fe"

# Labels and namespace.
assert_has   "apps objects land in the apps namespace"     '^  namespace: apps$' "$gw"
# Any indent, not just 4: pod-template labels sit at 8 spaces, and a bare `app:`
# there would be just as wrong as one in metadata.
assert_lacks "no bare app: label anywhere in apps"         '^ +app: ' "$apps_deploys"

# Vault backend (default) renders no app-config volume.
assert_lacks "backend=vault renders no app-config volume"  'app-config' "$apps_deploys"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
