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

`k8s-infra-helm` uses `--timeout 20m`, not the more obvious `15m`. The
`mysql-replication` post-install hook Job carries its own **derived**
`activeDeadlineSeconds` — `(mysqlReplica.replicas + 1) * mysqlReplica.waitTimeout
+ 60`, which at the defaults (`replicas: 2`, `waitTimeout: 300`) renders to
**960s (16m)**. The layering has to put the *inner, more specific* bound
first: the Job's own deadline should fire and emit its readable
`ERROR: <host> unreachable after 300s` diagnostic before Helm's `--timeout`
gives up. `15m` (900s) is tighter than the Job's 960s deadline, so Helm would
abandon the wait ~60s before the Job could ever produce that message — you'd
get a generic Helm timeout instead. `20m` keeps Helm's timeout as the outer
backstop. Separately, the Confluent (Kafka/Schema Registry/Connect) images
are ~1.8 GB combined and a cold image pull alone takes ~5.5 minutes, which
also has to fit inside the window.

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

### Fast check — no cluster required

`deploy/charts/microecom/tests/render-test.sh` renders the chart with `helm
template` and asserts on the output; it needs no cluster and no network. Run
it after any chart change:

```bash
bash deploy/charts/microecom/tests/render-test.sh
```
