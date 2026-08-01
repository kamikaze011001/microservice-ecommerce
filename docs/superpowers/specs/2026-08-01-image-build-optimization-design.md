# Image build optimization — design

Date: 2026-08-01
Status: implemented, verified 2026-08-01
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

### Measured results (2026-08-01, after implementation)

| Metric | Before | After |
|---|---|---|
| `order-service` source-only rebuild, wall | 41s | **10.7s** (`time make k8s-rebuild svc=order-service`) |
| `order-service` source-only rebuild, downloads | 459 | **0** |
| Full `make k8s-build`, cold cache | n/a (serial) | **839s** (~14m; cores 395s serial + 8 services 444s parallel at `BUILD_JOBS=4`), **3962** `Downloaded from central` lines — corrected 2026-08-02, see breakdown below |
| Full `make k8s-build`, warm cache | n/a (serial) | **9.5s**, 0 downloads |
| Maven build cache on disk | 0 | **6.95 GB** total BuildKit builder cache after the warm build (`docker builder du`) |

All eight service JARs verified non-truncated (`BOOT-INF/lib/` entry counts in the hundreds: 233,
198, 211, 185, 226, 195, 140, 165 for authorization-server, gateway, inventory-service,
product-service, order-service, payment-service, orchestrator-service, bff-service respectively),
and a rebuilt `order-service` rolled out and served traffic through the ingress rule.

Method notes, for anyone re-running this:

- **Cold-cache methodology deviation.** `make k8s-build-cache-prune` only removes BuildKit's
  `type=exec.cachemount` entries (the per-service `/root/.m2` mounts) — it does not touch BuildKit's
  regular content-addressed layer cache. Tasks 1–3's standalone `docker build` verification runs had
  already warmed that layer cache against this exact unchanged source, so the first "cold" attempt
  (prune + `make k8s-build`) hit full layer-cache reuse on every `RUN` step (`CACHED` in the BuildKit
  output) and finished in 27s with 0 downloads — not a cold build, a false cold reading. Confirmed by
  inspecting the build log for `CACHED` markers before drawing that conclusion. A cold number was then
  measured after `docker builder prune -af` (a full builder-cache wipe, not just the exec.cachemount
  filter), which is the state a genuinely fresh host or CI runner would start from — but that first
  attempt (424s / 683 downloads, captured from one merged stdout stream) turned out to itself be
  wrong; see the correction immediately below for the re-measured, per-service-attributable number.
- **Correction (2026-08-02): the 424s / 683-download cold-build number above was wrong.**
  A retained log from an earlier, strictly *warmer* run (the Task 3 parallel-verification build,
  where only `order-service`'s cache mount was warm and the other seven services were cold) showed
  **2499** `Downloaded from central` lines and a 460s wall time — more downloads and more time than
  the "cold" 683/424s reading, which is impossible: a warmer run cannot download less than a colder
  one. The 683 was a measurement artifact, most likely a partially-captured or interleaved read of
  one merged stdout stream shared by four concurrent BuildKit children under
  `BUILDKIT_PROGRESS=plain` — exactly the kind of output that is easy to lose or truncate. It was
  re-measured from a genuine `docker builder prune -af` (full builder-cache wipe, confirmed empty via
  `docker builder du` reporting `Total: 0B` immediately after) with **one log file per service**, so
  every count below is individually attributable and none of them came from a merged/truncated
  stream:

  | Image | `Downloaded from central` |
  |---|---|
  | `maven-cores` | 982 |
  | authorization-server | 306 |
  | gateway | 425 |
  | inventory-service | 432 |
  | product-service | 318 |
  | order-service | 459 |
  | payment-service | 411 |
  | orchestrator-service | 283 |
  | bff-service | 346 |
  | **Total** | **3962** |

  `order-service`'s cold count (459) lands exactly on the single-service baseline measured earlier in
  this document — strong corroboration that this run, unlike the 683 reading, is genuinely cold and
  attributable per service. None of the nine per-service logs contain a `CACHED` marker (checked with
  `grep -c CACHED`), confirming no layer was silently reused. The corrected total (3962) is not
  directly comparable to the 2499 in the Task 3 log either — that run still had `order-service` warm
  and (per its own build order) may have reused more of the `maven-cores` layer than this fully-wiped
  run did — but it is in the same order of magnitude and, unlike 683, does not contradict any other
  measurement in this document.

  The baseline's 459 downloads were for one service (`order-service`) alone. The cold
  `make k8s-build` run builds the `maven-cores` base plus all eight services, each with its own
  isolated `m2-${SERVICE}` cache per the per-service-cache-id design — so 3962 is the total across
  nine independent Maven resolutions from empty caches, not a regression versus 459. **This does not
  change the headline result.** A cold build is a one-time cost (new machine, new CI runner, or after
  a deliberate prune); the optimization targets the warm inner loop, and that number — 10.7s / 0
  downloads versus the 41s / 459-download baseline — is unaffected by this correction.
- **Warm full build (9.5s, 0 downloads)** re-ran `make k8s-build` immediately after the cold run with
  no source changes: every layer, including the `mvn package` `RUN` steps, hit BuildKit's layer cache
  directly (not just the `/root/.m2` mount), so this is the best case — nothing rebuilt at all.
- **Inner loop (10.7s, 0 downloads)** is the meaningful headline number: a real content edit to
  `OrderServiceApplication.java` (a comment line, not `touch` — BuildKit content-hashes `COPY` inputs,
  so `touch` alone would not invalidate the layer) invalidated the `COPY order-service/` layer and
  forced `RUN --mount=type=cache,...,id=m2-order-service ... mvn package` to actually re-execute;
  the BuildKit log shows `mvn` reaching `BUILD SUCCESS` in 4.4s with zero `Downloaded from central`
  lines, pulling every dependency from the warm per-service cache mount instead of the network. The
  full `make k8s-rebuild` wall time (10.7s) also includes the image push and triggering
  `kubectl rollout restart`.
- **JAR verification substitution.** The runtime images ship a JRE-slim base with no `unzip` binary,
  so `docker run --entrypoint sh ... unzip -l` (the brief's literal command) silently returned 0 for
  all eight services — a false corruption signal caused by a missing tool, not a truncated JAR. Each
  jar was instead extracted with `docker run --rm --entrypoint cat <image> /app/app.jar > file.jar`
  and checked with Python's `zipfile.ZipFile(...).testzip()` (stronger than `unzip -l`: it CRC-checks
  every member, not just lists names) plus a `BOOT-INF/lib/` count. All eight passed with no
  `testzip()` failures and sizes in the 99–142 MB range.
- **Ingress path.** `sudo -v && make k8s-cluster-up` could not cache a sudo credential in this
  non-interactive agent shell (macOS `tty_tickets` scopes the credential to the terminal that created
  it, and this shell has no TTY at all), so `minikube tunnel` was not started — `cluster.sh` detects
  this and treats it as non-fatal, matching its documented design. Both the pre-rebuild and
  post-rebuild HTTP checks in Step 7 were therefore run against
  `kubectl -n infra port-forward svc/ingress-nginx-controller 18080:80` with an explicit
  `Host: api.microecom.local` header (`curl -H 'Host: api.microecom.local' http://127.0.0.1:18080/product-service/v1/products`),
  both returning `200` with real catalog data. **This verifies the Ingress rule and the app behind
  it, not the `minikube tunnel` transport itself** — the tunnel path (`http://api.microecom.local/...`
  directly) remains unverified in this session and needs a user-run
  `sudo -v && make k8s-tunnel` from an interactive terminal.

## Out of scope

- `deploy/` Helm work (Plan 2 onward).
- Registry-backed CI cache (deploy-refactor Phase 9).
- Any change to `frontend/` or `mock-paypal-service/` images.
- A root Maven aggregator pom. Each service is an independent project under
  `spring-boot-starter-parent`; introducing a reactor is a structural change to local dev and
  `scripts/maven/install-modules.sh`, and is not needed to fix the measured problem.
