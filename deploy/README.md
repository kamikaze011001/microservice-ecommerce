# deploy/ deployment structure

This directory consolidates deployment artifacts for three target environments:
**docker-compose** (fast inner loop), **minikube** (local Kubernetes), and
**AWS EKS** (cloud).

## Status

This is a work-in-progress refactor. See:
`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`.

## Target layout

```text
deploy/
├── charts/microecom/   # Helm umbrella chart
├── compose/            # docker-compose files
├── terraform/          # AWS infrastructure
├── secrets/            # canonical secret definitions and contexts
├── seed/               # canonical seed data
├── scripts/            # environment-aware deployment scripts
└── images/             # image build definitions
```

## Current minikube workflow

```bash
make k8s-bootstrap
make k8s-tunnel
make k8s-status
make k8s-down
```

Kustomize remains in use until the Helm migration phase.

Host image builds push through `localhost:5001`; minikube nodes pull those
repositories through the registry addon's `localhost:5000` proxy.

## Helm umbrella chart (Phase 2 path)

`deploy/charts/microecom` is a Helm umbrella chart that renders every
infrastructure workload previously brought up by `k8s/infra/install.sh`
(MySQL + replicas, MongoDB, Redis, Kafka + Schema Registry + Connect +
exporters, MinIO, VictoriaMetrics, Grafana, Vault) via an `infra` subchart,
plus a post-install replication hook Job, a dashboards ConfigMap, and
AWS-gated resources.

```bash
make k8s-platform     # cluster-wide platform charts (ingress-nginx, metrics-server)
                      # + vendors the infra subchart's Helm dependencies
make k8s-infra-helm   # brings up infra via the umbrella chart (runs k8s-platform first)
```

**`make k8s-infra` is still the default path for this phase.** `k8s-infra-helm`
runs *alongside* it, not in place of it — rollback is reverting one target.
"Runs alongside it" is a codebase-level statement (both bring-up paths stay in
the tree, either can be chosen), **not** a claim that both are safe to run
against the *same already-provisioned cluster*. See the next section.

### The two infra bring-up paths are alternatives, not composable, on one cluster

`k8s-infra` (`k8s/infra/install.sh`) creates mysql/mongodb/redis/minio/kafka/
schema-registry/kafka-connect/mysqld-exporter/vault via plain `kubectl apply
-f`. The `infra` subchart deliberately renders the **same object names** in
the same `infra` namespace (`charts/infra/values.yaml`'s `fullnameOverride`
comments say so explicitly — the whole point is to keep app-facing DNS names
byte-identical across both paths). Plain `kubectl`-created objects carry none
of Helm's ownership annotations (`meta.helm.sh/release-name`,
`app.kubernetes.io/managed-by: Helm`), and Helm 3+ refuses to adopt an
existing unmanaged object into a release ("... exists and cannot be imported
into the current release: invalid ownership metadata"). So running
`make k8s-infra` and then `make k8s-infra-helm` against the **same** cluster
(or the reverse order) should be expected to fail `helm upgrade --install`
on essentially every stateful workload it tries to create — not a graceful
no-op. `ingress-nginx` and `metrics-server` (installed by `make k8s-platform`,
a genuine Helm release either way) are the one exception: both paths use the
same release name/namespace/chart version there, so sharing a cluster across
paths is fine for those two specifically.

**Operational rule: pick one infra bring-up path per cluster.** Tear the
cluster down (or use a fresh one) before switching from `k8s-infra` to
`k8s-infra-helm` or back.

Caveat: this is reasoned from documented Helm ownership-metadata behavior,
not verified against a live cluster in this repo — nobody has run both paths
back-to-back against one cluster and captured the actual error text. Treat
the *rule* (don't mix them) as solid and the *exact failure mode/error text*
as inferred, not observed.

### `--dry-run` / `helm template` keyfile hazard

`lookup` returns empty during `helm template` and any `--dry-run`, so a dry
run always renders a **fresh** `mongodb-keyfile`. Rendering to *read* the
output is fine. Piping a dry-run render into a live cluster is not:
`helm template … | kubectl apply -f -` rotates the keyfile and breaks an
already-initialized MongoDB replica set. Only `helm upgrade --install`
(no `--dry-run`) is safe to actually apply.

### Dependency vendoring

`helm dependency update` does **not** recurse into subcharts — it must be run
directly against `deploy/charts/microecom/charts/infra`, using `build` (not
`update`) so `Chart.lock` stays authoritative. `platform.sh` does this, which
is why `k8s-infra-helm` depends on `k8s-platform`. The resulting
`charts/infra/charts/*.tgz` files are gitignored and rebuilt from
`Chart.lock` on demand — never commit them.

### `--wait` timeouts

`k8s-infra-helm` uses `--timeout 30m`, not the more obvious `15m` or `20m`.
The `mysql-replication` post-install hook Job carries its own **derived**
`activeDeadlineSeconds` — `(mysqlReplica.replicas + 1) * mysqlReplica.waitTimeout
+ 60`, which at the defaults (`replicas: 2`, `waitTimeout: 300`) renders to
**960s (16m)**. The layering has to put the *inner, more specific* bound
first: the Job's own deadline should fire and emit its readable
`ERROR: <host> unreachable after 300s` diagnostic before Helm's `--timeout`
gives up.

These two windows are **additive, not independent**: Helm's sequence is
`create resources -> wait for readiness (--wait) -> post-install hooks`, so
the post-install `mysql-replication` hook is not even created until *every
other* resource is Ready — including schema-registry/kafka-connect, whose
cold Confluent image pull (~1.8 GB combined) alone takes ~5.5 minutes (~330s).
Worst case: `330s` (cold-pull wait phase) `+ 960s` (hook's own deadline)
`≈ 1290s (~21.5m)`. `15m` (900s) and even `20m` (1200s) are both tighter than
that compound worst case — Helm would abandon the wait *before* the hook
could ever emit its own diagnostic, the exact inversion this timeout exists
to prevent. `30m` = the 960s hook deadline + ~330s cold-pull + headroom.
`deploy/charts/microecom/tests/render-test.sh` asserts that the Makefile's
`--timeout` (parsed from the recipe) stays `>= activeDeadlineSeconds + 330s`
(parsed from the rendered hook Job), so a future change to either
`mysqlReplica.replicas`/`waitTimeout` or the Makefile literal that lets them
drift apart fails the render-test suite instead of failing silently on a
cold cluster.

### `global:` keys collide with upstream charts

Helm merges the umbrella's `global:` block into **every** subchart, vendored
upstream dependencies included. Several `global.*` paths are de-facto upstream
conventions, so picking one for our own use silently rewrites a third-party
chart's behaviour.

Our app-image registry therefore lives at **`global.appImage.registry`**, not
`global.image.registry`. victoria-metrics-common's `vm.internal.image` falls
back to `global.image.registry` whenever the per-app `image.registry` is empty,
so under the natural name `vmsingle` rendered as
`localhost:5000/victoriametrics/victoria-metrics:v1.144.0` and sat in
`ImagePullBackOff`. Because `helm --wait` waits for **every** resource to be
Ready before running post-install hooks, that one unpullable pod meant the
`mysql-replication` hook Job was never created and the release hung at
`pending-install` until the timeout — a failure mode with no obvious link to
its cause.

Known reserved spellings to avoid: `global.image.*` (victoria-metrics family),
`global.imageRegistry` and `global.imagePullSecrets` (grafana, bitnami),
`global.storageClass` (bitnami). When adding a `global.*` key, grep the
vendored charts for it first:

```bash
for t in deploy/charts/microecom/charts/infra/charts/*.tgz; do
  tar -xzOf "$t" --wildcards '*/templates/*' '*/values.yaml' | grep -o 'global\.[A-Za-z.]*'
done | sort -u
```

`render-test.sh` asserts no infra image carries the local registry, which is
what locks this in.

### Docker Hub rate limiting looks like a chart failure

A fresh 4-node cluster pulls ~10 upstream images in parallel and can exhaust
Docker Hub's anonymous quota. Hub answers an exhausted quota with **401
`unauthorized: authentication required`**, not the 429 `toomanyrequests` you
would expect, so the pod event reads like a credentials problem. It is
per-IP — the host's own `docker pull` fails identically, and
`~/.docker/config.json` holds no Hub login on either side.

Downstream, `k8s/infra/install.sh` aborts at its `kubectl wait` with a bare
`error: timed out waiting for the condition`, and every stage *after* that
wait is never applied. The cluster then looks "mostly up" while
schema-registry, kafka-connect, vault, VictoriaMetrics and Grafana are simply
absent. Re-running is idempotent and resumes — one bring-up needed three
invocations of `make k8s-infra` to get through.

It is transient and self-healing: kubelet backoff eventually lands every
image. Waiting is the correct first response. To skip Hub entirely, pre-load
from the host cache before installing:

```bash
for img in $(grep -rhoE 'image: *"?[a-z0-9][^ "]*' \
               deploy/charts/microecom/charts/infra/templates/ \
             | sed 's/image: *"*//' | sort -u); do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
  minikube -p microecom image load "$img"
done
```

This only works for tags the host actually has, so it is worth doing right
after `make k8s-cluster-up`. Bumping a pinned tag that the local cache does
not carry converts a soft dependency on Docker Hub into a hard one — a stale
cache holding `cp-kafka-connect:7.7.1` does nothing for a chart pinned to
`7.6.1`. With all ten images pre-loaded, `make k8s-infra-helm` completes in
about 4 minutes instead of stalling on pulls.

### Fast check — no cluster required

`deploy/charts/microecom/tests/render-test.sh` renders the chart with `helm
template` and asserts on the output; it needs no cluster and no network. Run
it after any chart change:

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

**Prerequisite: vendor the dependencies first**, or this "fast check" gives a
false green. `helm template` does **not** error on a missing vendored
dependency (see "Dependency vendoring" above) — it exits 0 and silently omits
every object from any subchart that isn't vendored yet. On a fresh clone (or
CI) that has never run `make k8s-platform` / `helm dependency build`, the
render-test assertions for vault/grafana/vmsingle/kube-state-metrics fail
loudly (not silently) for the "chart not vendored" reason, which a first-time
reader could mistake for a real regression rather than a missing setup step:

```bash
helm dependency build deploy/charts/microecom/charts/infra
```
