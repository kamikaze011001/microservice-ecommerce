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
assert_has   "vmsingle keeps its name (grafana datasource)"     '^  name: vmsingle$' "$out"
assert_has   "kube-state-metrics keeps its scrape label"        'app\.kubernetes\.io/name: kube-state-metrics' "$out"
assert_lacks "alias did not leak into the KSM name label"       'app\.kubernetes\.io/name: kubeStateMetrics' "$out"
# Anchored to the name label on purpose. A bare `kubeStateMetrics` can never
# pass: `alias:` also rewrites `.Chart.Name`, which the upstream chart bakes
# into its cosmetic `helm.sh/chart` label, and Helm names the in-memory
# subchart directory after the alias so it appears in `# Source:` comments too.
# Neither is addressable by any override, and neither is what VM scrapes on.

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
assert_has   "mysql-credentials carries the repl user"          'MYSQL_REPL_USER' "$out"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
