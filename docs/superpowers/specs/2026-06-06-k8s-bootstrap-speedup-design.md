# Speed up `make k8s-bootstrap` (repeated down→bootstrap) — Design Spec

**Date:** 2026-06-06
**Branch:** `feat/mock-paypal-service` (implement here, per user)
**Status:** approved (design)

## Goal

Make the repeated **`make k8s-down` → `make k8s-bootstrap`** cycle fast, while
still producing a genuinely clean cluster. The user uses `down`→`bootstrap` as a
catch-all for: reset DB/seed data, pick up infra/manifest changes, recover a
broken cluster, and "clean slate" habit — none of which change application
*source*. So the cluster (etcd, PVCs, manifests) must be recreated, but the
**built images and pulled 3rd-party images do not need to be redone**.

## Root cause of the slowness

`make k8s-bootstrap` = `k8s-cluster-up → k8s-infra → k8s-build → k8s-seed-images
→ k8s-apps → k8s-seed-mysql → k8s-seed-inventory → k8s-seed-perftest`. Two steps
dominate, and `down` forces both to redo every cycle:

1. **`k8s-build` rebuilds 11 images sequentially** — `maven-cores` + 8 services
   (Maven) + frontend (Vite) + mock-paypal (Java 25). Source rarely changes
   between down→bootstrap cycles, so this is wasted work.
2. **Cold 3rd-party image pulls** — `kind delete` wipes each node's containerd
   cache, so `mysql:8.0.40`, `mongo:7.0`, `redis:7.4-alpine`, `minio/*`,
   `apache/kafka:3.9.1`, and the heavy `confluentinc/cp-schema-registry:7.7.1`
   (~1.8 GB) + `cp-kafka-connect:7.6.1` are re-pulled from docker.io. The 1.8 GB
   pull alone previously exceeded a 5-minute rollout wait.

`k8s-cluster-down` also runs `docker rm -f kind-registry`, discarding all 11
built images so they must be rebuilt + re-pushed next time.

**Principle: decouple image lifecycle from cluster lifecycle.** Image content is
a pure function of source; recreating the cluster should not rebuild/re-pull
images that haven't changed.

## Approach (chosen: A — preserve & reuse images across recreation)

Keep the familiar `down`→`bootstrap` UX; stop discarding the expensive
artifacts. Three changes (Makefile + two small scripts). No app/manifest changes.

Rejected: **B** (a no-recreate `make k8s-reset`) — faster for the non-broken
cases but can't cover "recover broken cluster", so it can't replace
down→bootstrap; noted as optional future. **C** (containerd pull-through cache) —
more general but more moving parts than warranted for local dev. Reducing kind
node count — changes the multi-node demo/topology; out of scope.

## Components (modify / create)

### 1. Registry lifecycle — preserve built images (`Makefile`, modify)

- **`k8s-cluster-down`**: remove the `docker rm -f kind-registry` line. The
  `kind-registry` (`registry:2`, `--restart=always`) container keeps running and
  holds all built images; `k8s/kind/registry.sh` (run by `k8s-cluster-up`)
  already restarts/reconnects it to the fresh `kind` network. A comment notes
  that images are preserved and that `make k8s-nuke` removes the registry.
- **New `k8s-nuke` target** (full clean slate / old behavior):
  ```make
  k8s-nuke: k8s-apps-down
  	-kind delete cluster --name $(K8S_CLUSTER)
  	-docker rm -f kind-registry
  	@echo "==> cluster + registry destroyed (full clean slate)"
  ```
  Added to `.PHONY` and to `make` help.
- `make k8s-down` (`k8s-apps-down k8s-cluster-down`) now preserves the registry
  by virtue of the `k8s-cluster-down` change — no edit to `k8s-down` itself.

### 2. Build only what's missing during bootstrap (`k8s/images/build.sh` + `Makefile`, modify)

- **`build.sh`**: honor a `REUSE_EXISTING` env var. When set, before building
  each image (cores, each service, frontend, mock-paypal) check the local
  registry and **skip if the tag already exists**:
  ```sh
  image_in_registry() {  # repo tag -> 0 if present
    curl -fsS -o /dev/null \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      "http://${REGISTRY}/v2/$1/manifests/$2"
  }
  ```
  Each `build_*` function, when `REUSE_EXISTING=1` and the image is present,
  prints `==> reusing <img> (already in registry)` and returns without building.
  Default (unset) behavior is unchanged: always build.
- **`Makefile`**: add `k8s-build-reuse` → `@REUSE_EXISTING=1 k8s/images/build.sh`.
  Change the `k8s-bootstrap` prerequisite from `k8s-build` to `k8s-build-reuse`.
  Plain `make k8s-build` and `make k8s-rebuild svc=…` remain always-rebuild
  (unchanged). Escape hatch: `make k8s-bootstrap FORCE_BUILD=1` maps to building
  everything — implemented by making `k8s-build-reuse`'s recipe honor
  `FORCE_BUILD` (`if [ -n "$(FORCE_BUILD)" ]; then k8s/images/build.sh; else
  REUSE_EXISTING=1 k8s/images/build.sh; fi`).
- **Tradeoff (documented):** during bootstrap, an image present in the registry
  is reused even if source changed. To pick up code changes use
  `make k8s-rebuild svc=<name>` (single) or `make k8s-build` (all), or
  `make k8s-bootstrap FORCE_BUILD=1`. This matches the existing code-change
  workflow and is safe because down→bootstrap never changes source.

### 3. Preload 3rd-party images into fresh nodes (`k8s/kind/preload-images.sh`, create; `Makefile`, modify)

- **New `k8s/kind/preload-images.sh`**: derive the image list from the infra
  manifests and `kind load` each image **already present on the host** (images
  not yet on the host are skipped and pull normally the first time):
  ```sh
  #!/usr/bin/env bash
  set -euo pipefail
  CLUSTER_NAME='microecom'
  cd "$(git rev-parse --show-toplevel)"
  grep -rhE '^[[:space:]]*image:' k8s/infra/manifests/*.yaml \
    | awk '{print $2}' | sort -u \
    | while read -r img; do
        if docker image inspect "$img" >/dev/null 2>&1; then
          echo "==> kind load $img"
          kind load docker-image "$img" --name "$CLUSTER_NAME"
        else
          echo "skip (not on host yet, will pull): $img"
        fi
      done
  ```
  Covers `mysql:8.0.40`, `mongo:7.0`, `redis:7.4-alpine`, `minio/minio`,
  `minio/mc`, `apache/kafka:3.9.1`, `confluentinc/cp-schema-registry:7.7.1`,
  `confluentinc/cp-kafka-connect:7.6.1`. (Helm-chart images — vault,
  ingress-nginx, monitoring — are smaller and left to pull normally; can be added
  later if needed.)
- **`Makefile` `k8s-cluster-up`**: call `@k8s/kind/preload-images.sh` right after
  `@k8s/kind/registry.sh` (the cluster + nodes exist by then, so `kind load` can
  target them).

## Data / control flow after the change (fast down→bootstrap)

`make k8s-down` → `kind delete` (registry container + its images preserved; node
containerd cache gone). `make k8s-bootstrap`:
1. `k8s-cluster-up` → `kind create` (4 nodes) → `registry.sh` (reconnect
   registry) → `preload-images.sh` (`kind load` 3rd-party from host — local, no
   network).
2. `k8s-infra` → apply manifests; nodes already have 3rd-party images locally →
   pods start without cold pulls; MySQL replication + vault + schema-registry +
   kafka-connect come up fast.
3. `k8s-build-reuse` → every service image already in the persisted registry →
   all skipped.
4. `k8s-apps` → nodes pull service images from the persisted local registry
   (fast, local).
5. seeds run as normal.

The two dominant costs (rebuild 11 images, cold-pull ~5 GB) are eliminated on
the repeat path. The **first-ever** bootstrap (nothing cached on host, registry
empty) behaves exactly as today — it builds and pulls once; every cycle after is
fast.

## Error handling / edge cases

- **Registry not running / empty** (first bootstrap, or after `k8s-nuke`):
  `image_in_registry` returns non-zero → images build normally;
  `preload-images.sh` skips images not on host → they pull normally. No special
  casing needed.
- **`kind load` of an image not on host**: guarded by `docker image inspect`;
  skipped with a message.
- **Stale image after a source change**: covered by `make k8s-rebuild svc=…` /
  `make k8s-build` / `FORCE_BUILD=1` (documented).
- **`curl` availability**: present on the dev host (already used elsewhere); if
  the registry probe errors for any reason it fails "closed" (treats image as
  absent → builds), so correctness is preserved, only speed is lost.

## Testing / acceptance

1. `make -n k8s-bootstrap` / `make -n k8s-nuke` / `make -n k8s-cluster-up` parse
   with no "missing separator"; `bash -n` on `build.sh` and `preload-images.sh`.
2. `image_in_registry` returns 0 for a pushed tag and non-zero for a missing one
   (quick `curl` check against the running registry).
3. **End-to-end (user-run):** with images already built once, `make k8s-down &&
   make k8s-bootstrap` completes noticeably faster; the build phase prints
   `reusing …` for all 11 images and `preload-images.sh` prints `kind load …`
   for the 3rd-party images; the cluster is healthy (`make k8s-status`,
   `make k8s-mysql-status`).
4. `make k8s-nuke` removes both cluster and registry; the subsequent
   `make k8s-bootstrap` rebuilds + pulls (cold path still works).
5. `make k8s-bootstrap FORCE_BUILD=1` rebuilds all images even when present.

## Out of scope

- B: a no-recreate `make k8s-reset` (optional future; doesn't cover broken-cluster recovery).
- C: containerd pull-through cache for docker.io.
- Reducing kind node count (changes the multi-node demo/topology).
- Parallelizing the image builds (only helps when source changed, which this
  scenario excludes).
- App/manifest/Vault changes.
