# Helm Infra Subchart — Phase 2 of the Deployment Refactor

Status: approved, not yet implemented
Date: 2026-08-02
Parent spec: `docs/superpowers/specs/2026-08-01-deploy-refactor-design.md` (Phase 2)
ADR: `.claude/memory/decisions/0003-deploy-refactor-helm-umbrella-three-envs.md`
Predecessor: Plan 1 (Foundation) — merged as `3d67d0e`

## Problem

`k8s/infra/install.sh` is not a manifest applier. It is a 229-line **sequencer**, and the
sequence is the product. Nine ordering constraints are encoded in bash, four of them
discovered the hard way during the minikube bring-up:

1. namespaces exist before anything else
2. the `grafana-custom-dashboards` ConfigMap exists before the Grafana pod starts
3. `mongodb-keyfile` is created **only if missing** — a re-run must never rotate it, because
   rotating it breaks an already-initialized replica set
4. the stateful services are applied, then waited on individually
5. Kafka is Ready **before** `kafka-exporter` is applied — the exporter hard-exits when no
   broker answers, and a cold start can exhaust the Deployment progress deadline
6. `_schemas` and `connect-*` are force-compacted **before** Schema Registry and Connect
   start — Kafka auto-creates them with `cleanup.policy=delete`, and both services then
   refuse to start
7. MySQL primary + both replicas Ready **before** `CHANGE REPLICATION SOURCE`, which then
   verifies and **fails the install** rather than seeding onto a broken topology
8. MySQL replication established before the `mysqld-exporter` rollout checks
9. Kafka + compacted topics before Schema Registry, and Schema Registry before Kafka Connect

Helm has no cross-resource ordering inside a release. It will not wait for a StatefulSet to
become Ready before creating the next object. So converting the manifests is the easy half;
every one of these nine constraints needs a new home, and that choice shapes the chart.

## Scope

**In scope — Phase 2 only.** The infra subchart: 14 plain manifests, the four upstream Helm
charts that stay bundled, and the ordering logic above.

**Deliberately out of scope**, deferred exactly as the parent spec sequences them:

| Deferred | Phase |
|---|---|
| Apps subchart — the 11 services, the shared `microecom.deployment` template | 3 |
| k6 stress Jobs (`k8s/apps/base/k6-stress/`) | 3 |
| Canonical secrets, `vault-seed-env`, the `<terraform:*>` placeholder question | 4 |
| The 6 seed Jobs (`k8s/infra/jobs/*`) | 5 |
| Unified `make <verb> ENV=…` entry points | 6 |
| AWS cut-over — `envs/aws.yaml` is written here but not exercised | 7 |
| Deleting `k8s/` and `aws/` | 8 |

Apps continue to deploy through Kustomize for the duration of this phase. That hybrid is a
working, testable state, which is what the parent spec's build-new-alongside-old rule requires.

## Decisions

### D1 — Plan 2 covers Phase 2 only, not Phase 2 + 3

**Rejected:** doing the whole chart in one pass. The values schema would be written once
instead of twice and no throwaway hybrid wiring would be needed, but every unknown in this
phase — dependency gating, `lookup` semantics, whether initContainers actually replace the
sequencing — is an unknown that would be resolved *while* also designing the apps template.
Resolve them first, then design the apps template against settled ground.

**Rejected:** splitting Phase 2 further into upstream-deps-then-manifests. Three plans to
reach where the parent spec says two phases land, and the split point is artificial — the
ordering logic spans both halves.

### D2 — Remove the ordering constraints rather than sequence around them

Push waiting into the workloads that care. A service that blocks until its dependency answers
does not need an installer to order it, and — the decisive property — it **self-heals on any
later restart**, not just on first install. The current script only orders the *initial*
bring-up; if Kafka restarts at 3am, `kafka-exporter` still dies and stays dead.

**Rejected:** a thin wrapper script (`helm upgrade --wait`, then the same imperative steps).
Lowest risk and keeps the four fixes as readable bash, but it preserves the 3am failure mode
and means the chart alone cannot bring up a working cluster.

**Rejected:** every step as a weighted post-install hook Job. Purely declarative and
in-chart, but hook Jobs need images carrying `kubectl` and client binaries, a failed hook marks
the entire release failed, and debugging a crashed Job is markedly worse than reading a bash
line — which matters, given these four fixes were found by debugging in the first place.

One step stays a hook Job regardless: MySQL replication is a genuine one-shot cluster-level
operation with no single workload that "wants" it.

### D3 — Platform charts stay separate releases; the rest bundle into the umbrella

`ingress-nginx` and `metrics-server` are cluster-wide singletons, and on EKS both are replaced
outright (ALB controller, EKS addon). Bundling them into a release that also owns the MySQL
data misrepresents ownership and widens the blast radius: a failed ingress upgrade should not
touch a database.

`vault`, `victoria-metrics-single`, `grafana`, `kube-state-metrics` become umbrella
dependencies gated by `condition:`.

**Rejected:** all six as dependencies (the parent spec's original sketch). One atomic release
and one rollback, but every upgrade re-renders six third-party charts.

**Rejected:** all six as separate releases. Smallest chart and fastest iteration, but a script
stays the real entry point, so "one `helm upgrade` per env" would not hold even for infra.

## Architecture

### Chart layout

```
deploy/charts/microecom/
├── Chart.yaml                    umbrella, v0.1.0
├── values.yaml                   base defaults (infra populated, apps stubbed)
├── envs/
│   ├── local-k8s.yaml            minikube
│   └── aws.yaml                  EKS — written now, first exercised in Phase 7
└── charts/infra/
    ├── Chart.yaml                4 upstream dependencies, each with condition:
    ├── Chart.lock                committed
    ├── dashboards/               3 JSON files, moved from k8s/infra/dashboards/
    ├── values.yaml               subchart defaults
    └── templates/
        ├── _helpers.tpl          microecom.fqdn, labels, image refs
        ├── mysql.yaml            mysql-replica{,-service}, mysqld-exporter
        ├── mongodb.yaml          + keyfile Secret
        ├── redis.yaml
        ├── minio.yaml            + minio-ingress
        ├── kafka.yaml            + kafka-exporter
        ├── schema-registry.yaml
        ├── kafka-connect.yaml
        ├── external-secrets.yaml SA + SecretStore, AWS-gated
        ├── storageclass-gp3.yaml AWS-gated
        ├── dashboards-cm.yaml    .Files.Glob
        └── hooks/
            └── mysql-replication-job.yaml
```

### Upstream dependency gating

Dependencies are declared in `charts/infra/Chart.yaml` so their values nest under `infra.*`,
matching the parent spec's values schema. Two need an alias, because the chart name is the
values key and the schema uses camelCase:

| Chart | Repo | Version | Alias | Condition |
|---|---|---|---|---|
| `vault` | hashicorp | 0.27.0 | — | `vault.enabled` |
| `victoria-metrics-single` | vm | 0.39.0 | `victoriaMetrics` | `victoriaMetrics.enabled` |
| `grafana` | grafana | 10.5.15 | — | `grafana.enabled` |
| `kube-state-metrics` | prometheus-community | see below | `kubeStateMetrics` | `kubeStateMetrics.enabled` |

`kube-state-metrics` is the one chart `install.sh` installs **unpinned** today. A `Chart.yaml`
dependency requires an explicit version, so implementation must read the currently-installed
version (`helm list -n monitoring`) and pin that exact value — pinning whatever `helm repo
update` happens to resolve would be an unreviewed upgrade smuggled into a refactor.

`condition:` paths are evaluated against the values of the chart that *declares* the
dependency. Inside `charts/infra`, that scope is what the umbrella supplies under its `infra:`
key — so `infra.vault.enabled: false` in `values.yaml` reaches `vault.enabled` in the subchart
and gates the dependency. **This must be verified empirically before the manifests are
converted** (see Risks); it is open question #2 from the parent spec.

Note the deliberate key overlap: `infra.vault.*` is simultaneously the gate (`enabled`) and the
vault chart's own values namespace. That is the standard Helm idiom. `enabled` is not a key
`hashicorp/vault` recognises, and it ignores it.

`helm dependency update` does **not** recurse into subcharts. It must be run against
`deploy/charts/microecom/charts/infra`. This becomes a step in `platform.sh` and a documented
prerequisite, not a thing a newcomer is expected to know.

### Values schema (Phase 2 subset)

```yaml
# values.yaml
global:
  namespaces: { infra: infra, apps: apps, monitoring: monitoring, bootstrap: bootstrap }
  image: { registry: localhost:5000, tag: dev, pullPolicy: Always }
  secret: { backend: vault }
  ingress:
    className: nginx
    hosts: { storefront: microecom.local, api: api.microecom.local, media: media.microecom.local }

infra:
  mysql:          { enabled: true, storage: 5Gi }
  mysqlReplica:   { enabled: true, replicas: 2, storage: 5Gi }
  mongodb:        { enabled: true, storage: 4Gi }
  redis:          { enabled: true }
  kafka:          { enabled: true, storage: 10Gi }
  minio:          { enabled: true, storage: 10Gi }
  schemaRegistry: { enabled: true }
  kafkaConnect:   { enabled: true }
  kafkaExporter:  { enabled: true }
  mysqldExporter: { enabled: true }
  storageClassGp3:  { enabled: false }   # EKS only
  externalSecrets:  { enabled: false }   # EKS only — Phase 4 wires it
  vault:            { enabled: true }
  victoriaMetrics:  { enabled: true }
  grafana:          { enabled: true }
  kubeStateMetrics: { enabled: true }

apps: {}   # stub — Phase 3 populates this
```

`envs/local-k8s.yaml` overrides almost nothing (minikube is the base case).
`envs/aws.yaml` disables `mysql`, `mysqlReplica`, `redis`, `minio`, and `vault` (RDS,
ElastiCache, S3 and ESO replace them), enables `storageClassGp3` and `externalSecrets`, and
switches `global.image.registry` to ECR with an empty `tag` for the deploy script to fill.

### Cross-namespace addressing

One helper replaces every hardcoded FQDN, so a namespace rename is a values change:

```
{{- define "microecom.fqdn" -}}
{{- printf "%s.%s.svc.cluster.local" .name .namespace -}}
{{- end -}}
```

## The ordering rewrite

| Constraint | New home |
|---|---|
| kafka-exporter after Kafka Ready + restart | initContainer `wait-for-kafka` |
| `_schemas` compacted before Schema Registry | initContainers `wait-for-kafka`, `ensure-compacted` |
| `connect-*` compacted before Connect | same pair, plus `wait-for-schema-registry` |
| MySQL replication after both StatefulSets Ready | post-install/post-upgrade hook Job |
| `mongodb-keyfile` only if missing | `lookup` + `helm.sh/resource-policy: keep` |
| dashboards ConfigMap before Grafana starts | `.Files.Glob` template |
| gp3 StorageClass before any PVC | Helm's own install order (free) |
| namespaces before everything | umbrella templates + Helm install order |
| rollout waits per service | `helm upgrade --wait` |

### wait-for-kafka / ensure-compacted

Both initContainers reuse `apache/kafka:3.9.1`, already on the node and already carrying
`kafka-topics.sh` and `kafka-configs.sh`. No new image, no new pull.

```yaml
initContainers:
  - name: wait-for-kafka
    image: apache/kafka:3.9.1
    command: ["sh","-c","until /opt/kafka/bin/kafka-broker-api-versions.sh
      --bootstrap-server $KAFKA:9092 >/dev/null 2>&1; do echo waiting for kafka; sleep 3; done"]
  - name: ensure-compacted
    image: apache/kafka:3.9.1
    command: ["sh","-c","for t in $TOPICS; do
      /opt/kafka/bin/kafka-topics.sh --bootstrap-server $KAFKA:9092 --create --if-not-exists
        --topic $t --partitions 1 --replication-factor 1;
      /opt/kafka/bin/kafka-configs.sh --bootstrap-server $KAFKA:9092 --alter
        --entity-type topics --entity-name $t --add-config cleanup.policy=compact; done"]
```

`$TOPICS` is `_schemas` for Schema Registry and `connect-configs connect-offsets
connect-status` for Connect — each service repairs exactly the topics it needs, which is
better than today's single loop that fixes all four from one place. `kafka-connect` already
has an `install-plugins` initContainer; initContainers run sequentially, so these prepend.

### MySQL replication hook Job

`post-install,post-upgrade`, hook-weight 5, `hook-delete-policy: before-hook-creation`,
image `mysql:8.0.40`.

The conversion delivers a real simplification. Today the logic runs `kubectl exec mysql-0`,
which requires `kubectl` in the caller's path and cluster credentials. As a Job it is a plain
`mysql` client connecting to `mysql-0.mysql.infra.svc` and the two replica FQDNs — **no Kubernetes
API access at all**, so no ServiceAccount, no RBAC. The SQL, the idempotence check
(`replication_connection_status WHERE SERVICE_STATE='ON'`) and the verify-or-fail behaviour
are carried over unchanged.

Helm's sequence is: pre-install hooks → create resources → **wait for readiness (only with
`--wait`)** → post-install hooks. `--wait` is therefore load-bearing, not cosmetic. The Job
also polls for replica reachability defensively, so it survives being run without it.

### mongodb-keyfile

```
{{- $existing := lookup "v1" "Secret" $ns "mongodb-keyfile" -}}
{{- $keyfile := $existing | ternary (index (default dict $existing).data "keyfile" | default "")
                                    (randAlphaNum 756 | b64enc) -}}
```

plus `helm.sh/resource-policy: keep` so `helm uninstall` cannot take the keyfile with it and
strand the replica set's data volume.

### The free win

`k8s/infra/overlays/aws/storageclass-gp3.yaml` exists because a fresh EKS cluster defaults to
gp2 and the gp3 StorageClass must be applied before any PVC, or the infra bring-up stalls
(recorded in `.claude/memory/conventions/eks-gp3-storageclass-must-precede-pvcs.md`).

Helm's install order places `StorageClass` ahead of `PersistentVolumeClaim` unconditionally.
Moving the file into the chart makes that hazard structurally impossible rather than
documented — one convention becomes obsolete instead of being carried forward.

## Migration and rollback

`k8s/infra/install.sh` stays on disk, unmodified, for the whole phase. A new `make
k8s-infra-helm` target runs the Helm path alongside it. Deleting the old path is Phase 8, gated
on a full bootstrap pass. Rollback at any point is reverting one Makefile target.

**Cut-over requires a teardown.** Current infra was created by `kubectl apply` plus six
standalone Helm releases; folding those into a new release means fighting Helm's ownership
metadata (`meta.helm.sh/release-name`, `app.kubernetes.io/managed-by`) on every adopted object.
Since all data here is reproduced by `make k8s-bootstrap`, `make k8s-down` followed by a
rebuild is cheaper and less error-prone than adoption. The minikube hostPath PVs are wiped by
`k8s-down` anyway.

`platform.sh` installs `ingress-nginx` and `metrics-server`, runs `helm dependency update` on
the infra subchart, and is written to take `ENV` so Phase 7 can swap in the ALB controller.

## Verification

Green pods prove little here — the point of the four fixes is that specific services crash
without them. Verification is therefore functional:

1. `schema-registry`, `kafka-connect`, `kafka-exporter` all Running and Ready. Each of the
   three crashes without its initContainers, so this is direct proof, not a smoke test.
2. Both replicas report `Replica_IO_Running: Yes` **and** `Replica_SQL_Running: Yes`.
3. `grafana-custom-dashboards` ConfigMap exists with exactly 3 keys, and Grafana lists the
   JVM / Kafka / MySQL dashboards.
4. **Idempotence:** re-run `helm upgrade`. The keyfile is byte-identical, the replication Job
   re-runs and reports "already replicating", nothing restarts.
5. **Restart resilience** — the property the old script never had: delete the Kafka pod, and
   `kafka-exporter` recovers on its own instead of staying dead.
6. `helm template -f envs/aws.yaml` renders without error and omits `mysql`, `mysqlReplica`,
   `redis`, `minio`, `vault`, proving the gating works before Phase 7 depends on it.
7. The existing `make k8s-infra` path still works, unchanged.

## Risks and known hazards

**`condition:` on subchart dependencies must be proven first.** If the scope resolution does
not behave as described, the fallback is declaring the four dependencies in the umbrella's
`Chart.yaml` with conditions pointing at `infra.<name>.enabled`, accepting that their values
then sit at top level rather than nested. Verify with `helm template --set` before converting
any manifest — this is the one unknown that could reshape the chart.

**`lookup` returns empty during `helm template` and `--dry-run`.** A dry run therefore renders
a *fresh* keyfile that does not match the live one. Harmless when rendering to read, but
piping that output to `kubectl apply` rotates the keyfile and breaks the initialized replica
set — precisely the failure the current `if ! kubectl get secret` guard prevents. This must be
called out in `deploy/README.md`, not just known.

**Confluent images are ~1.8 GB.** The existing script uses a 10-minute rollout timeout for
Schema Registry and Connect because a cold pull alone can take ~5.5 minutes. The Helm `--wait`
timeout must be at least as generous, or a healthy cluster will be reported as a failed
release.

**The hybrid state is not free.** For this phase, infra is Helm-managed and apps are
Kustomize-managed. `make k8s-bootstrap` must keep working across the seam.

## Resolved and remaining open questions

Resolved here: parent-spec open question **#2** (dependency gating — via `condition:`, pending
empirical confirmation) and **#4** (keyfile rotation — via `lookup` + `resource-policy: keep`).

Still open, unchanged: **#1** minikube tunnel watchdog, **#3** terraform output resolution
(Phase 4/7), **#5** k6 Jobs placement (Phase 3).
