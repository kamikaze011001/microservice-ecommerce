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

## Canonical secrets (`deploy/secrets/`)

`deploy/secrets/<service>.yaml` plus `deploy/secrets/contexts/<env>.yaml` are
the single source of truth for the ~90 Spring config keys previously hand-kept
in sync across `docker/vault-configs/*.json`, `k8s/infra/jobs/03-vault-seed/`,
and `scripts/aws/seed-secrets.sh`. Three targets operate on this tree:

```bash
make secrets-validate              # consistency checks only — no backend,
                                    # no credentials, safe to run anywhere
make secrets-render ENV=compose    # resolve only — writes
                                    # deploy/.run/secrets-<env>.json (mode 600),
                                    # touches no backend
make secrets-seed ENV=compose      # resolve, then push to the env's backend
```

`ENV` is one of `compose`, `k8s`, `aws` (default `compose`).

**`secrets-seed` always overwrites.** This is a deliberate design decision,
not an oversight: the canonical file is authoritative, so a value hand-edited
directly in Vault or AWS Secrets Manager does **not** survive the next seed —
it is silently replaced by whatever `deploy/secrets/` currently resolves to.
If you need a value to persist, put it in the canonical file, not the
backend. There is no "skip if exists" mode.

Per-env specifics:

- **`ENV=compose`** pushes to the local Vault (`VAULT_ADDR`, default
  `http://localhost:8200`) over its HTTP API. It needs `VAULT_TOKEN` in the
  environment — run `make vault-login` first, or export it yourself.
- **`ENV=k8s`** opens a temporary `kubectl -n infra port-forward svc/vault
  18200:8200` for the duration of the push and tears it down on exit
  (success, failure, or interrupt). The in-cluster Vault runs in dev mode
  with the fixed root token `root`, so no token lookup is needed unless you
  override `VAULT_TOKEN` yourself.
- **`ENV=aws`** reads `deploy/.run/terraform-outputs.json`, a cached copy of
  `terraform output -json` from `aws/main` (which keeps its real state in an
  S3 remote backend — there is no local file whose mtime can be trusted
  automatically). The cache is generated on first use and warned about once
  it is over 24h old, but never auto-refreshed — an implicit `terraform`
  call mid-seed is exactly the coupling this design removes. The Makefile
  target does not expose `--refresh-tf`; call the script directly to force a
  refresh:
  ```bash
  bash deploy/scripts/secrets-seed.sh --env aws --refresh-tf
  ```
  Any resolve against `ENV=aws` — including `--dry-run` — needs terraform
  outputs from somewhere: pass `--tf-outputs FILE` to point at one directly
  and skip the cache (and terraform) entirely, which is how an offline or CI
  run avoids touching terraform at all:
  ```bash
  bash deploy/scripts/secrets-seed.sh --env aws --dry-run \
    --tf-outputs deploy/secrets/tests/fixtures/terraform-outputs.json
  ```

The old paths — `make vault-import`, the `03-vault-seed` Job, and
`scripts/aws/seed-secrets.sh` — still work today and are **not** being
removed by this change. They are retired in Phase 8, once both the compose
and k8s seeding paths have been run against a live backend and proven
equivalent (Phase 7).

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

## Helm apps subchart (Phase 3 path)

`deploy/charts/microecom/charts/apps` renders the ten application workloads
previously brought up by `kubectl apply -k k8s/apps/overlays/local`: nine JVM
services plus the storefront SPA, with their Services, five HPAs, the gateway's
discovery RBAC, the nginx Ingresses, and — on AWS — the ExternalSecrets,
`app-config` configtree mounts and S3 IRSA ServiceAccounts.

```bash
make k8s-apps        # kubectl/kustomize path (still the default)
make k8s-apps-helm   # Helm path (ENV=aws selects envs/aws.yaml)
```

The subchart is gated `apps.enabled: false` in the umbrella `values.yaml`, so
`make k8s-infra-helm` renders exactly what it rendered in Phase 2.
`k8s-apps-helm` passes `--set apps.enabled=true`.

### The apps paths are alternatives too — same rule, different reason

The infra rule above is about Helm ownership metadata. For apps the reason is
sharper: the base manifests use a bare `app: <name>` as their
`spec.selector.matchLabels`, the chart uses `app.kubernetes.io/name`, and
**`spec.selector` is immutable on a Deployment**. Neither path can be installed
over the other. Tear the cluster down before switching.

### One shared template, variation in values

Per-service blocks under `apps:` are merged over a chart-level `defaults:` block.
Three rules are load-bearing, and breaking any of them fails quietly:

1. **`deepCopy` before every merge.** Sprig's `mergeOverwrite` wraps mergo's
   in-place API and mutates its destination. Without `deepCopy`, the first
   service's overrides contaminate `.Values.defaults` permanently, and because
   `range` over a map iterates in sorted key order, every service sorting after
   it inherits them — `gateway` sorts 4th of 10, so its `initialDelaySeconds: 45`
   leaks into the six after it. `render-test.sh` asserts order-service still gets
   60.
2. **`enabled` is read from the raw values block, before the merge.** Mergo
   treats falsy values as absent, so `enabled: false` cannot survive a merge
   against a default of `true`.
3. **`env` is merged outside mergo, key by key.** For the same reason: mergo
   skips nil source values, so a per-key `null` could not unset an inherited
   variable. `env` is a map rather than a list because YAML lists cannot merge
   element-wise; the list-of-`{name,value}` shape appears only at render time,
   emitted by a sorted `range`.

### `managementPort` is listed, never derived

Seven of the nine JVM services put Actuator on `port + 10000`. Two do not:
authorization-server is `6666 → 19091` and gateway is `6868 → 19093` (fossils of
an older shared-9091 scheme, later prefixed with `1`). Both probes target the
management port by name, so deriving it would render correctly for seven
services and point two at dead ports — permanent readiness failure with a
values file that looks clean.

General rule: derive a value only when the relationship is *enforced*, not
merely *observed*. The ALB service prefixes (§ below) are safe to derive because
the gateway's `Path=/<service-name>/**` routing convention enforces them.

### The ALB service prefixes are derived from the service list

The hand-written `k8s/apps/overlays/aws/ingress-gateway.yaml` lists eight
`/<service>` paths by hand. Adding a service and forgetting that list gave you a
service that worked locally and was invisible on AWS. The chart ranges the
service list, skips `gateway` and `frontend`, and emits the rest — the
divergence is no longer representable.

