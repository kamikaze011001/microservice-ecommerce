# Image build optimization — design

Date: 2026-08-01
Status: approved, not yet implemented
Scope: `k8s/images/` (Dockerfiles + `build.sh`). Kustomize manifests, Helm work, and the
`deploy/` refactor are out of scope.

## Problem

Both loops are slow, and for the same reason:

- inner loop — `make k8s-rebuild svc=<name>` after a code change
- cold build — `make k8s-build` / `make k8s-bootstrap`, ten images

### Measured baseline (2026-08-01, `order-service`, source-only change)

| Metric | Value |
|---|---|
| Wall time | **41s** |
| `mvn -B -DskipTests package` | **37.6s** |
| Artifacts downloaded from Maven Central | **459** |
| Bytes downloaded | **~150 MB** |
| Last download completes at | **37.30s of a 37.58s `RUN`** |
| Build context transferred | 24 kB |

Reproduce with:

```bash
docker build -f k8s/images/Dockerfile.jvm \
  --build-arg SERVICE=order-service \
  --build-arg CORES_IMAGE=localhost:5001/maven-cores:dev \
  --no-cache-filter builder --progress=plain -t probe:x . 2>&1 \
  | grep -cE 'Downloaded from central'
```

### Root cause

`Dockerfile.jvm` copies the whole service directory and then runs `mvn package` in one layer:

```dockerfile
COPY ${SERVICE}/ ./${SERVICE}/
RUN cd ${SERVICE} && mvn -B -DskipTests package
```

Any source edit invalidates the `COPY`, so the `RUN` re-executes and every artifact Maven wrote
into `/root/.m2` is discarded with the layer. All 459 artifacts are re-fetched on **every**
rebuild of **every** service — roughly 1.5 GB per cold build.

Downloading is not a startup phase that finishes early: the final download lands at 37.30s of a
37.58s run, so it is interleaved with compilation across the whole build.

### What is *not* the problem

Ruled out by measurement, recorded so nobody re-opens them:

- **Build context.** There is no root `.dockerignore` and the context is `.` (a 3.0 GB repo), but
  BuildKit transfers lazily — only 24 kB moved, in 0.0s. A `.dockerignore` would save nothing.
- **`frontend/Dockerfile` and `mock-paypal-service/Dockerfile`.** Both already do lockfile/pom-first
  layering; mock-paypal already runs `dependency:go-offline`. No measured problem → no change.
- **The registry push** and **serial builds** are real but second-order next to 459 downloads.

## Approach

Chosen: **BuildKit cache mount for the Maven repository, plus parallel builds, minus the
`maven-cores` push.**

### Why not `dependency:go-offline` layering

The textbook fix — `COPY pom.xml` → `dependency:go-offline` → `COPY src` → `package` — is simpler
and CI-portable, but `dependency:go-offline` is known to under-fetch **plugin** dependencies. The
baseline log shows `maven-shade-plugin`, `spring-boot-loader-tools` and `asm` arriving at package
time, so it would leave an unmeasured tail re-downloading on every build. Rejected for being
approximately right in a way we cannot bound without building it.

### The shadowing trap

The reflex implementation is wrong and must not be attempted:

```dockerfile
# BROKEN
FROM ${CORES_IMAGE} AS builder
RUN --mount=type=cache,target=/root/.m2 ... mvn package
```

`Dockerfile.cores` deliberately **bakes** the core module artifacts into `/root/.m2` inside the
image, and `Dockerfile.jvm` inherits them through `FROM ${CORES_IMAGE}`. A cache mount at that
path **shadows** the image's directory the way a volume mount does — the baked core JARs become
invisible and every service build fails to resolve `common-dto`, `grpc-common`, etc.

The fix is a second stage from the same image, bind-mounted read-only as a seed source:

```dockerfile
FROM ${CORES_IMAGE} AS cores

FROM ${CORES_IMAGE} AS builder
ARG SERVICE
WORKDIR /workspace
COPY ${SERVICE}/ ./${SERVICE}/
RUN --mount=type=cache,target=/root/.m2,id=m2-${SERVICE} \
    --mount=type=bind,from=cores,source=/root/.m2,target=/cores-m2,ro \
    cp -r /cores-m2/. /root/.m2/ && cd ${SERVICE} && mvn -B -DskipTests package
```

Both stages resolve to the same image, so the extra `FROM` costs no pull and no layers.

`cp -r` **clobbers**, and that direction is load-bearing. The cache outlives cores rebuilds, so a
`core/*` artifact already sitting in it must lose to the one from the freshly built cores image.
`cp -n` (no-clobber) does the opposite — it skips the destination file that already exists, which
is exactly the stale copy — and was corrected during planning after being verified by poisoning a
cache with a `STALE` `common-dto-0.0.1.jar`: `-n` kept it, `-r` refreshed it. The overwrite costs
~0.2s for 190 MB / 3008 files. See "Stale cores" under Risks.

### Per-service cache id, not a shared repo

Maven's local repository is **not safe for concurrent writes**. Two parallel service builds
downloading the same artifact can leave a truncated JAR that poisons every later build. So:

- `sharing=shared` — permits the corruption. Rejected.
- `sharing=locked` — safe, but serializes the Maven step and cancels most of the parallelism.
  Rejected.
- **`id=m2-${SERVICE}`** — each service gets its own cache, no contention, full parallelism.
  Chosen. Costs disk: ~8 × 150 MB ≈ 1.2 GB.

ARG expansion inside a cache-mount `id` is not documented prominently, so it was verified on this
host (buildx 0.33 / Docker 29.4) before approval: the step header renders as `id=m2-alpha` /
`id=m2-beta`, and a build with `SERVICE=beta` sees only its own file, never `alpha`'s. The caches
are genuinely isolated, not silently collapsed into one shared `m2-`.

## Components

### `k8s/images/Dockerfile.jvm`

As above. The `builder` stage keeps `FROM ${CORES_IMAGE}` so a cold cache still resolves core
modules from the baked repo — the cache mount is an accelerator, never a correctness dependency.

### `k8s/images/Dockerfile.cores`

Split the single `COPY core/` plus ten-module install loop into per-module `COPY` + `RUN` pairs,
preserving the existing order (canonical: `scripts/maven/install-modules.sh`). Editing one core
module then rebuilds that module and the ones after it, instead of all ten.

**No cache mount here.** Cores must bake its artifacts into the image layer, because that layer is
what `Dockerfile.jvm` bind-mounts. A cache mount would divert them into the cache and leave the
bind source empty.

### `k8s/images/build.sh`

1. Run the eight service builds concurrently (`xargs -P`), failing the whole run if any fails.
2. Stop pushing `maven-cores`. No pod pulls it — it is a build-only base, and
   `FROM localhost:5001/maven-cores:dev` resolves from the local image store. Its
   `REUSE_EXISTING` check becomes `docker image inspect` instead of a registry probe.
3. Cores still builds first; the bind mount requires it present.

Keep these changes small: `build.sh` moves to `deploy/images/` in a later plan, while the
Dockerfiles move unchanged.

### `Makefile`

Add `k8s-build-cache-prune` wrapping `docker builder prune --filter type=exec.cachemount`, and
document it. The host already carries 37.77 GB of reclaimable build cache; per-service Maven
caches must not silently repeat that.

## Risks

**Stale cores.** Already a known hazard — `.claude/memory/` records that `k8s-rebuild` uses
`SKIP_CORES=1`, so a `core/*` change needs `SVC=cores build.sh` first or services build against
stale baked JARs. The cache mount does not fix it either: `cp -r` copies from whatever
`FROM ${CORES_IMAGE}` resolves to on that build, stale or fresh, and overwrites the cache to match.

**Cold cache.** First build after a prune, on a new machine, or in CI downloads everything exactly
as today, then warms. Degradation is graceful, never a failure.

**CI portability.** Cache mounts are host-local and do not survive a fresh runner. Phase 9 of the
deploy refactor adds `.github/workflows/deploy.yml`; if build time matters there, the follow-up is
registry-backed cache (`--cache-from` / `--cache-to`), which composes with this design rather than
replacing it. Explicitly out of scope now.

**Disk.** ~1.2 GB of Maven caches, mitigated by the prune target.

## Verification

Re-run the baseline measurements. The numbers to beat: **459 downloads, 41s**.

1. **Inner loop** — touch a source file in `order-service`, rebuild, count
   `Downloaded from central` and wall time. Expect near-zero downloads on the second build.
2. **Cold build** — `make k8s-build` from a pruned cache, then again warm. Record both.
3. **Correctness, not just speed** — all ten images build, and at least one rebuilt service rolls
   out and serves traffic in-cluster. A fast build producing a broken JAR is worse than a slow one.
4. **Parallel safety** — a full parallel cold build must not produce a corrupt artifact; per-service
   cache ids are the control, and this run is the evidence.

Verification needs a running cluster: the push step requires the registry port-forward.

## Out of scope

- `deploy/` Helm work (Plan 2 onward).
- Registry-backed CI cache (deploy-refactor Phase 9).
- Any change to `frontend/` or `mock-paypal-service/` images.
- A root Maven aggregator pom. Each service is an independent project under
  `spring-boot-starter-parent`; introducing a reactor is a structural change to local dev and
  `scripts/maven/install-modules.sh`, and is not needed to fix the measured problem.
