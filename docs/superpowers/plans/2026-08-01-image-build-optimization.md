# Image Build Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop every service image rebuild from re-downloading 459 Maven artifacts (~150 MB) by giving each service a persistent BuildKit cache mount for its Maven repository, then build the eight services in parallel.

**Architecture:** `Dockerfile.jvm` mounts a per-service BuildKit cache at `/root/.m2` and seeds it from the `maven-cores` image through a read-only bind mount, because a cache mount shadows the baked core artifacts the image inherits via `FROM ${CORES_IMAGE}`. `Dockerfile.cores` splits its single ten-module install loop into per-module `COPY` + `RUN` layers so editing one core module no longer rebuilds all ten. `build.sh` then runs the service builds concurrently (safe only because each has a private cache — Maven's local repository is not concurrency-safe) and stops pushing the 764 MB build-only `maven-cores` image.

**Tech Stack:** Docker 29.4.0 / buildx v0.33.0 (BuildKit cache + bind mounts), `maven:3.9-eclipse-temurin-17`, bash under `set -euo pipefail`, GNU make, macOS host.

**Spec:** `docs/superpowers/specs/2026-08-01-image-build-optimization-design.md`

## Global Constraints

- Scope is `k8s/images/` (both Dockerfiles + `build.sh`) plus one new `Makefile` target and its docs. Nothing else.
- **No** changes to `frontend/Dockerfile` or `mock-paypal-service/Dockerfile` — measurement showed both already layer correctly.
- **No** registry-backed CI cache (`--cache-from`/`--cache-to`), **no** root Maven aggregator pom, **no** `deploy/` Helm work. All deferred.
- Core module install order is `common-dto grpc-common core-jwt-util core-redis core-s3 core-order-cache core-routing-db core-paypal core-email core-exception-api` — canonical source is `scripts/maven/install-modules.sh`.
- **`Dockerfile.cores` gets NO cache mount.** It must bake its artifacts into an image layer, because that layer is what `Dockerfile.jvm` bind-mounts as its seed. A cache mount there would divert them into the cache and leave the bind source empty.
- The registry split is correct and must not be "fixed": host pushes `localhost:5001`, pods pull `localhost:5000`.
- After Task 3, `maven-cores` is **never pushed**. `FROM ${CORES_IMAGE}` resolves it from the local image store. Every *service* image is still pushed to `${REGISTRY}`.
- Numbers to beat, measured 2026-08-01 on `order-service` with a source-only change: **459 `Downloaded from central` lines, 41s wall, 37.6s of it `mvn package`.**
- Stay on branch `feat/aws-live-deploy`. Do not branch off.

## File Structure

| File | Change | Responsibility after the change |
|---|---|---|
| `k8s/images/Dockerfile.jvm` | Modify (lines 1–9) | Build one service JAR against a persistent, per-service Maven cache seeded from the cores image. |
| `k8s/images/Dockerfile.cores` | Modify (whole file) | Bake all ten `core/*` artifacts into `/root/.m2`, one layer per module. |
| `k8s/images/build.sh` | Modify (lines 12–14, 23–39, 52–60, 122–128) | Orchestrate: cores first (local only, not pushed), then services in parallel, then frontend + mock-paypal. |
| `Makefile` | Modify (lines 43–47 help, 226 `.PHONY`, after line 246) | Add `k8s-build-cache-prune` to reclaim the per-service Maven caches. |
| `k8s/README.md` | Modify (Daily table ~line 41, new section) | Document the prune target and `BUILD_JOBS`. |
| `.claude/memory/conventions/buildkit-cache-mount-shadows-baked-m2.md` | Create | Durable record of the shadowing trap, so nobody writes the reflex (broken) version. |
| `.claude/memory/MEMORY.md` | Modify (Conventions section) | One index line for the new convention. |
| `docs/superpowers/specs/2026-08-01-image-build-optimization-design.md` | Modify (lines 92–108) | Correct the `cp -rn` → `cp -r` decision (see "Spec deviation" below). |

## Spec deviation — `cp -r`, not `cp -rn`

The approved spec specifies `cp -rn` (no-clobber) and justifies it as: *"it never overwrites, so a freshly rebuilt cores image cannot be masked by a stale copy already sitting in the cache."* That rationale is backwards, and the plan implements `cp -r` (clobbering) instead.

`cp -n` **skips** files that already exist at the destination. The destination is the cache, which outlives cores rebuilds. So under `-n`, a stale `common-dto.jar` already in the cache is exactly what survives, and the freshly built one from the cores image is the thing that gets skipped — the opposite of the stated goal.

Verified on this host (Docker 29.4.0 / buildx 0.33.0) by poisoning the cache with a `STALE` `common-dto-0.0.1.jar` and running both variants:

```
=== cp -rn ===  RESULT: cache kept STALE jar
=== cp -r  ===  RESULT: cache refreshed from cores
```

The cost of clobbering is negligible: the cores repo is 190 MB / 3008 files, and a full overwrite measured **~0.18s** (0.078s → 0.255s in the plain build log). Also note GNU coreutils ≥ 9.3 prints `cp: warning: behavior of -n is non-portable and may change in future` on every `cp -rn` — a load-bearing flag whose behavior upstream has flagged as unstable is the wrong flag for a build that runs ten times a bootstrap.

Task 1 corrects the spec text as part of the change so the two documents do not contradict each other.

## Prerequisites

- The cluster may be **down** for Tasks 1–3; they build images without pushing. `localhost:5001/maven-cores:dev` must exist in the local image store (verify with `docker image inspect localhost:5001/maven-cores:dev`). It was present at 764 MB when this plan was written.
- Task 4 needs a **running cluster** — the push step requires the registry port-forward.
- All commands run from the repo root: `/Users/sonanh/Documents/AIBLES/microservice-ecommerce`.
- Scratch logs: `export SCRATCH=${SCRATCH:-/tmp/imgopt}; mkdir -p "$SCRATCH"`.

---

### Task 1: `Dockerfile.jvm` — per-service Maven cache seeded from cores

**Files:**
- Modify: `k8s/images/Dockerfile.jvm:1-9`
- Modify: `Makefile:43` (help), `Makefile:226` (`.PHONY`), after `Makefile:246` (new target)
- Modify: `k8s/README.md` (Daily table, ~line 41)
- Modify: `docs/superpowers/specs/2026-08-01-image-build-optimization-design.md:92-108`
- Create: `.claude/memory/conventions/buildkit-cache-mount-shadows-baked-m2.md`
- Modify: `.claude/memory/MEMORY.md` (Conventions section)

**Interfaces:**
- Consumes: `localhost:5001/maven-cores:dev` in the local image store, with `core/*` artifacts baked into `/root/.m2`.
- Produces: build args `SERVICE` (e.g. `order-service`) and `CORES_IMAGE` (default `localhost:5001/maven-cores:dev`), unchanged from today. BuildKit cache ids named `m2-<SERVICE>`, one per service — Task 3 relies on these being distinct to build in parallel. Makefile target `k8s-build-cache-prune` (no arguments).

- [ ] **Step 1: Measure the failing baseline**

This is the test. `--no-cache-filter builder` forces the `mvn package` layer to re-execute without touching any cache mount — the same rebuild an edited source file causes, but deterministic.

```bash
export SCRATCH=${SCRATCH:-/tmp/imgopt}; mkdir -p "$SCRATCH"
docker build -f k8s/images/Dockerfile.jvm \
  --build-arg SERVICE=order-service \
  --build-arg CORES_IMAGE=localhost:5001/maven-cores:dev \
  --no-cache-filter builder --progress=plain -t probe:baseline . \
  > "$SCRATCH/baseline.log" 2>&1
grep -cE 'Downloaded from central' "$SCRATCH/baseline.log" || true
```

Expected: a number in the hundreds (**~459**). If it prints `0`, the `builder` stage was served from the layer cache — re-check that `--no-cache-filter builder` is present.

- [ ] **Step 2: Rewrite `k8s/images/Dockerfile.jvm`**

Replace the whole file with:

```dockerfile
# Per-service image. Inherits the maven local repo populated by Dockerfile.cores
# so the service `mvn package` resolves core/* modules instantly.
ARG CORES_IMAGE=localhost:5001/maven-cores:dev

# The same image as `builder` below, bind-mounted read-only as the seed source
# for the Maven cache. Both FROMs resolve to one image: no extra pull, no extra
# layer, no extra build time.
FROM ${CORES_IMAGE} AS cores

FROM ${CORES_IMAGE} AS builder
ARG SERVICE
WORKDIR /workspace
COPY ${SERVICE}/ ./${SERVICE}/
# Why the bind mount exists: a cache mount SHADOWS the image's own directory at
# the same path, the way a volume mount does. Dockerfile.cores deliberately
# BAKES the core/* artifacts into /root/.m2, so a bare
#   RUN --mount=type=cache,target=/root/.m2 ... mvn package
# hides them and every service build fails to resolve common-dto, grpc-common,
# etc. Seeding the cache from the `cores` stage restores them.
#
# `cp -r` CLOBBERS on purpose. The cache outlives cores rebuilds, so a core/*
# artifact already sitting in it must LOSE to the one from the freshly built
# cores image; `cp -n` would keep the stale copy. Measured cost of the full
# overwrite: ~0.2s for 190 MB / 3008 files.
#
# id=m2-${SERVICE} gives each service a private cache. Maven's local repository
# is not safe for concurrent writes and build.sh builds services in parallel;
# a shared cache can leave a truncated jar that poisons every later build.
RUN --mount=type=cache,target=/root/.m2,id=m2-${SERVICE} \
    --mount=type=bind,from=cores,source=/root/.m2,target=/cores-m2,ro \
    cp -r /cores-m2/. /root/.m2/ && cd ${SERVICE} && mvn -B -DskipTests package

FROM eclipse-temurin:17-jre AS runtime
ARG SERVICE
ENV SERVICE=${SERVICE}
WORKDIR /app
COPY --from=builder /workspace/${SERVICE}/target/*.jar /app/app.jar
EXPOSE 8080 9091
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
```

- [ ] **Step 3: Run the cold build — it warms the cache and must still succeed**

```bash
docker build -f k8s/images/Dockerfile.jvm \
  --build-arg SERVICE=order-service \
  --build-arg CORES_IMAGE=localhost:5001/maven-cores:dev \
  --no-cache-filter builder --progress=plain -t probe:cold . \
  > "$SCRATCH/cold.log" 2>&1
echo "exit=$?"
grep -cE 'Downloaded from central' "$SCRATCH/cold.log" || true
```

Expected: `exit=0`, and a download count still in the hundreds. A cold cache downloads everything — that is correct, not a failure. If the build **fails** with `Could not resolve dependencies ... org.aibles.ecommerce:common-dto`, the bind seed is not working: check that the `cores` stage exists and that `source=/root/.m2` matches the path `Dockerfile.cores` installs into.

- [ ] **Step 4: Run the warm build — this is the assertion**

```bash
docker build -f k8s/images/Dockerfile.jvm \
  --build-arg SERVICE=order-service \
  --build-arg CORES_IMAGE=localhost:5001/maven-cores:dev \
  --no-cache-filter builder --progress=plain -t probe:warm . \
  > "$SCRATCH/warm.log" 2>&1
echo "exit=$?"
grep -cE 'Downloaded from central' "$SCRATCH/warm.log" || true
grep -E '^#[0-9]+ DONE' "$SCRATCH/warm.log" | tail -3
```

Expected: `exit=0` and a download count of **0 or single digits** (down from ~459). The `DONE` lines give the per-stage wall time; the `mvn package` stage should drop from ~37.6s to a few seconds.

If the count is still in the hundreds, the cache is not persisting. Check the step header in the log renders as `id=m2-order-service` — if it shows a literal `id=m2-${SERVICE}` or a bare `m2-`, the ARG did not expand and every service is sharing one cache.

- [ ] **Step 5: Confirm the produced JAR is real, not just fast**

```bash
docker run --rm --entrypoint sh probe:warm -c 'ls -l /app/app.jar && unzip -l /app/app.jar | grep -c BOOT-INF/lib/'
```

Expected: a file of tens of MB and a `BOOT-INF/lib/` entry count in the hundreds. A near-empty JAR means the build resolved nothing and silently produced a thin artifact.

- [ ] **Step 6: Add the `k8s-build-cache-prune` target to the Makefile**

Add to the help block, immediately after the `k8s-rebuild` line at `Makefile:47`:

```make
	@echo "  make k8s-build-cache-prune  — reclaim the per-service Maven build caches"
```

Extend the `.PHONY` at `Makefile:226` to:

```make
.PHONY: k8s-build k8s-build-reuse k8s-rebuild k8s-build-cache-prune k8s-registry-forward k8s-registry-stop
```

And append after the `k8s-registry-stop` target (`Makefile:246`):

```make
# Each service keeps its own BuildKit cache mount for /root/.m2 (see
# Dockerfile.jvm) -- roughly 150 MB apiece, ~1.2 GB across the eight services.
# Reclaim them when disk gets tight; the next build re-downloads and re-warms,
# so this costs time, never correctness. Also the fix if a core/* artifact in a
# cache ever looks stale.
k8s-build-cache-prune:
	@docker builder prune --filter type=exec.cachemount -f
	@docker builder du | tail -3
```

- [ ] **Step 7: Verify the Makefile target parses and runs**

```bash
make -n k8s-build-cache-prune
```

Expected: it echoes the two `docker` commands. Do **not** actually run the target yet — it would discard the cache you just warmed and invalidate Step 4's evidence.

- [ ] **Step 8: Document the target in `k8s/README.md`**

In the `## Daily` table, add a row immediately after the `Re-deploy one service after code change` row:

```markdown
| Reclaim Maven build caches (disk) | `make k8s-build-cache-prune` |
```

- [ ] **Step 9: Correct the spec's `cp -rn` decision**

In `docs/superpowers/specs/2026-08-01-image-build-optimization-design.md`, change the code block's `cp -rn` to `cp -r`, and replace the paragraph that currently reads:

```markdown
`cp -rn` (no-clobber) is load-bearing in the other direction: it never overwrites, so a freshly
rebuilt cores image cannot be masked by a stale copy already sitting in the cache. See
"Stale cores" under Risks.
```

with:

```markdown
`cp -r` **clobbers**, and that direction is load-bearing. The cache outlives cores rebuilds, so a
`core/*` artifact already sitting in it must lose to the one from the freshly built cores image.
`cp -n` (no-clobber) does the opposite — it skips the destination file that already exists, which
is exactly the stale copy — and was corrected during planning after being verified by poisoning a
cache with a `STALE` `common-dto-0.0.1.jar`: `-n` kept it, `-r` refreshed it. The overwrite costs
~0.2s for 190 MB / 3008 files. See "Stale cores" under Risks.
```

Then confirm no `cp -rn` survives anywhere in the spec (it appears both in the `### The shadowing trap` code block and in that paragraph):

```bash
grep -n 'cp -rn' docs/superpowers/specs/2026-08-01-image-build-optimization-design.md
```

Expected: no output.

- [ ] **Step 10: Record the shadowing trap as a durable convention**

Create `.claude/memory/conventions/buildkit-cache-mount-shadows-baked-m2.md`:

```markdown
---
name: buildkit-cache-mount-shadows-baked-m2
description: A BuildKit cache mount hides the image's own directory at that path, so Dockerfile.jvm must bind-seed /root/.m2 from the cores image
metadata: { type: convention, date: 2026-08-01 }
---

`k8s/images/Dockerfile.cores` **bakes** the ten `core/*` artifacts into `/root/.m2`, and
`Dockerfile.jvm` inherits them through `FROM ${CORES_IMAGE}`. Mounting a BuildKit cache at that
same path **shadows** the image's directory the way a volume mount does — the baked jars become
invisible and every service build fails to resolve `common-dto`, `grpc-common`, etc.

So the reflex version is broken and must not be re-attempted:

```dockerfile
# BROKEN
FROM ${CORES_IMAGE} AS builder
RUN --mount=type=cache,target=/root/.m2 ... mvn package
```

**Why:** the fix is a second stage from the same image (`FROM ${CORES_IMAGE} AS cores`, costing no
pull and no layer) bind-mounted read-only as a seed source, copied into the cache before Maven
runs.

**How to apply:**
- Seed with `cp -r` (clobbering), never `cp -n`. The cache outlives cores rebuilds, so a stale
  `core/*` artifact in the cache must lose to the fresh one from the image. `cp -n` keeps the
  stale copy — verified by poisoning a cache. Full overwrite costs ~0.2s / 190 MB / 3008 files.
- Keep `id=m2-${SERVICE}`. Maven's local repository is not safe for concurrent writes and
  `build.sh` builds services in parallel; a shared cache can leave a truncated jar. ARG expansion
  inside a cache-mount `id` works (verified on buildx 0.33 / Docker 29.4) — check the step header
  renders `id=m2-order-service`, not a bare `m2-`.
- The same rule bans a cache mount in `Dockerfile.cores`: it must bake into a layer, because that
  layer is the bind source. Related: [[minikube-registry-host-5001-pod-5000]].
```

Add one line to `.claude/memory/MEMORY.md`, at the end of the `## Conventions` section:

```markdown
- [buildkit-cache-mount-shadows-baked-m2](conventions/buildkit-cache-mount-shadows-baked-m2.md) — a cache mount hides the image's baked `/root/.m2`; seed it from a read-only bind with `cp -r` (never `-n`)
```

- [ ] **Step 11: Commit**

```bash
git add k8s/images/Dockerfile.jvm Makefile k8s/README.md \
  docs/superpowers/specs/2026-08-01-image-build-optimization-design.md \
  .claude/memory/conventions/buildkit-cache-mount-shadows-baked-m2.md \
  .claude/memory/MEMORY.md
git commit -m "perf(images): cache the Maven repo per service instead of re-downloading it

Every rebuild of every service re-fetched 459 artifacts (~150 MB) from Maven
Central, because Dockerfile.jvm ran mvn package in the same layer as the COPY --
any source edit discarded /root/.m2 with the layer. A source-only order-service
rebuild cost 41s, 37.6s of it Maven.

Mount a BuildKit cache at /root/.m2, seeded from the cores image through a
read-only bind. The bind is not optional: a cache mount shadows the image's own
directory, so the core/* artifacts Dockerfile.cores bakes there would otherwise
be invisible and nothing would resolve.

Seed with cp -r, not the spec's cp -rn. The cache outlives cores rebuilds, so a
stale core/* artifact in it must lose to the fresh one from the image -- -n
keeps the stale copy, the opposite of what the spec's rationale claimed.
Verified by poisoning a cache; the full overwrite costs ~0.2s.

id=m2-\${SERVICE} keeps the caches private per service, so the parallel builds
coming in a later commit cannot corrupt a shared Maven repo.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `Dockerfile.cores` — one layer per core module

**Files:**
- Modify: `k8s/images/Dockerfile.cores` (whole file, currently 16 lines)

**Interfaces:**
- Consumes: `core/<module>/` source directories in the build context; the install order defined by `scripts/maven/install-modules.sh`.
- Produces: an image whose `/root/.m2` contains all ten `core/*` artifacts baked into layers — the exact contract Task 1's `--mount=type=bind,from=cores,source=/root/.m2` depends on. Working directory `/workspace/core`. No behavioural change for `Dockerfile.jvm`, which only reads `/root/.m2` and writes under `/workspace/${SERVICE}`.

- [ ] **Step 1: Establish the failing behaviour — editing the last module rebuilds all ten**

```bash
export SCRATCH=${SCRATCH:-/tmp/imgopt}; mkdir -p "$SCRATCH"
docker build -f k8s/images/Dockerfile.cores -t probe:cores0 . > /dev/null 2>&1
touch core/core-exception-api/pom.xml
docker build -f k8s/images/Dockerfile.cores --progress=plain -t probe:cores1 . \
  > "$SCRATCH/cores-before.log" 2>&1
grep -E 'Installing /workspace/core' "$SCRATCH/cores-before.log" | sed 's/.*core\///' | cut -d/ -f1 | sort -u
```

Expected: **all ten** module names. A one-line change to the last module re-ran the whole loop, because there is only one `COPY core/` and one `RUN`.

- [ ] **Step 2: Rewrite `k8s/images/Dockerfile.cores`**

Replace the whole file with:

```dockerfile
# Base image with all core/* modules installed into the maven local repo.
# Built once; per-service Dockerfile.jvm uses this as FROM *and* bind-mounts its
# /root/.m2 as the seed for that service's Maven cache, so each service build
# resolves common-dto, grpc-common, etc. without rebuilding them.
#
# One COPY + RUN pair per module, in the dependency order defined by
# scripts/maven/install-modules.sh (that script is canonical). Editing one
# module invalidates its layer and the ones after it -- not all ten.
#
# NO cache mount here, deliberately. This image must BAKE its artifacts into a
# layer, because that layer is what Dockerfile.jvm bind-mounts. A cache mount at
# /root/.m2 would divert them into the cache and leave the bind source empty.
# See .claude/memory/conventions/buildkit-cache-mount-shadows-baked-m2.md
FROM maven:3.9-eclipse-temurin-17
WORKDIR /workspace/core

COPY core/common-dto/ ./common-dto/
RUN cd common-dto && mvn -B -DskipTests install

COPY core/grpc-common/ ./grpc-common/
RUN cd grpc-common && mvn -B -DskipTests install

COPY core/core-jwt-util/ ./core-jwt-util/
RUN cd core-jwt-util && mvn -B -DskipTests install

COPY core/core-redis/ ./core-redis/
RUN cd core-redis && mvn -B -DskipTests install

COPY core/core-s3/ ./core-s3/
RUN cd core-s3 && mvn -B -DskipTests install

COPY core/core-order-cache/ ./core-order-cache/
RUN cd core-order-cache && mvn -B -DskipTests install

COPY core/core-routing-db/ ./core-routing-db/
RUN cd core-routing-db && mvn -B -DskipTests install

COPY core/core-paypal/ ./core-paypal/
RUN cd core-paypal && mvn -B -DskipTests install

COPY core/core-email/ ./core-email/
RUN cd core-email && mvn -B -DskipTests install

COPY core/core-exception-api/ ./core-exception-api/
RUN cd core-exception-api && mvn -B -DskipTests install
```

- [ ] **Step 3: Build it once to populate the layer cache**

```bash
docker build -f k8s/images/Dockerfile.cores -t localhost:5001/maven-cores:dev . \
  > "$SCRATCH/cores-new.log" 2>&1
echo "exit=$?"
docker run --rm localhost:5001/maven-cores:dev \
  sh -c 'ls -d /root/.m2/repository/org/aibles*/*/ | wc -l'
```

Expected: `exit=0`, and a count of **at least 10** artifact directories under `org/aibles*`. (The ten modules live under two group ids — `org.aibles.ecommerce` for most, `org.aibles` for `core-jwt-util`.) A count below 10 means a module silently failed to install.

- [ ] **Step 4: Verify the layering — editing the LAST module rebuilds only that module**

```bash
touch core/core-exception-api/pom.xml
docker build -f k8s/images/Dockerfile.cores --progress=plain -t probe:cores2 . \
  > "$SCRATCH/cores-last.log" 2>&1
grep -c 'CACHED' "$SCRATCH/cores-last.log" || true
grep -E 'Installing /workspace/core' "$SCRATCH/cores-last.log" | sed 's/.*core\///' | cut -d/ -f1 | sort -u
```

Expected: a high `CACHED` count, and the `Installing` list naming **only `core-exception-api`**. If earlier modules appear, the per-module `COPY` boundaries are not taking effect.

- [ ] **Step 5: Verify the other direction — editing the FIRST module rebuilds everything after it**

```bash
touch core/common-dto/pom.xml
docker build -f k8s/images/Dockerfile.cores --progress=plain -t probe:cores3 . \
  > "$SCRATCH/cores-first.log" 2>&1
grep -E 'Installing /workspace/core' "$SCRATCH/cores-first.log" | sed 's/.*core\///' | cut -d/ -f1 | sort -u | wc -l
```

Expected: **10**. `common-dto` is first in dependency order, so everything downstream must rebuild — that is correct, not a regression.

- [ ] **Step 6: Restore the cores image tag and confirm a service still builds against it**

Step 5 left `localhost:5001/maven-cores:dev` pointing at the pre-touch build. Rebuild the tag, then prove `Dockerfile.jvm` still resolves core modules from it:

```bash
git checkout -- core/common-dto/pom.xml core/core-exception-api/pom.xml
docker build -f k8s/images/Dockerfile.cores -t localhost:5001/maven-cores:dev . > /dev/null 2>&1
docker build -f k8s/images/Dockerfile.jvm \
  --build-arg SERVICE=order-service \
  --build-arg CORES_IMAGE=localhost:5001/maven-cores:dev \
  --no-cache-filter builder --progress=plain -t probe:aftercores . \
  > "$SCRATCH/jvm-aftercores.log" 2>&1
echo "exit=$?"
grep -cE 'Downloaded from central' "$SCRATCH/jvm-aftercores.log" || true
```

Expected: `exit=0` and a **low** download count. This is the integration point between Tasks 1 and 2 — the bind seed must still find `/root/.m2` in the restructured cores image.

- [ ] **Step 7: Commit**

```bash
git add k8s/images/Dockerfile.cores
git commit -m "perf(images): one layer per core module in Dockerfile.cores

A single COPY core/ plus a ten-module install loop meant a one-line change to
core-exception-api -- last in dependency order -- re-ran all ten installs. Split
into per-module COPY + RUN pairs in the order scripts/maven/install-modules.sh
defines, so an edit invalidates that module and the ones after it.

Still no cache mount here, and that is deliberate: this image must bake its
artifacts into a layer, because that layer is what Dockerfile.jvm bind-mounts as
its cache seed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `build.sh` — parallel service builds, no `maven-cores` push

**Files:**
- Modify: `k8s/images/build.sh:12-14` (config), `:23-39` (reuse helpers), `:52-60` (`build_cores`), `:122-128` (dispatch)
- Modify: `k8s/README.md` (new "Image builds" section)

**Interfaces:**
- Consumes: the per-service cache ids `m2-<SERVICE>` from Task 1 — the only reason concurrent Maven builds are safe here. The restructured `Dockerfile.cores` from Task 2.
- Produces: env knob `BUILD_JOBS` (default `4`), and shell variable `SELF` (absolute path to `build.sh`, captured before the `cd` to the repo root, used to re-exec one child per service). Existing contract is unchanged: `SVC=<name>` builds one, `SVC=cores` builds cores only, unset builds everything; `REUSE_EXISTING`, `SKIP_CORES`, `REGISTRY`, `TAG`, `VITE_API_BASE_URL` keep their meanings. `scripts/aws/push-images.sh` calls this script and needs all of that intact.

- [ ] **Step 1: Capture the script's own absolute path**

The parallel loop re-execs `build.sh` once per service, so it needs a path that survives the `cd` on line 15 and works whether callers invoke it relatively (`k8s/images/build.sh`, from the Makefile) or absolutely (`"$ROOT/k8s/images/build.sh"`, from `scripts/aws/push-images.sh`).

Insert immediately **before** the `cd "$(git rev-parse --show-toplevel)"` line (currently line 15):

```bash
# Absolute path to this script, resolved BEFORE the cd below. The parallel build
# re-execs one child per service and callers invoke us both relatively (Makefile)
# and absolutely (scripts/aws/push-images.sh), so "$0" is not reliable here.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
```

- [ ] **Step 2: Add the `BUILD_JOBS` knob**

Immediately after the `TAG="${TAG:-dev}"` line (currently line 13), add:

```bash
# How many service images to build at once. Safe only because each service has
# its own Maven cache (id=m2-${SERVICE} in Dockerfile.jvm) -- Maven's local
# repository is not safe for concurrent writes. 4 is conservative for a 12-core
# laptop; raise it if the machine is idle during a build.
BUILD_JOBS="${BUILD_JOBS:-4}"
```

- [ ] **Step 3: Stop pushing `maven-cores`, and check the local store instead of the registry**

Add this helper immediately after the existing `reuse_or_build()` function (currently ends line 39):

```bash
# maven-cores is a BUILD-ONLY base: Dockerfile.jvm consumes it through
# `FROM ${CORES_IMAGE}`, which resolves from the local image store. No pod ever
# pulls it, so it is not pushed -- that keeps 764 MB off the registry forward on
# every build. Its reuse check therefore asks docker, not the registry.
image_in_local_store() {  # $1=repo:tag -> exit 0 if present locally
  docker image inspect "$1" >/dev/null 2>&1
}
```

Then replace the `build_cores()` function (currently lines 52-60) with:

```bash
build_cores() {
  if [ -n "${REUSE_EXISTING:-}" ] && image_in_local_store "${REGISTRY}/maven-cores:${TAG}"; then
    echo "==> reusing ${REGISTRY}/maven-cores:${TAG} (already in the local image store)"
    return 0
  fi
  echo "==> building cores base image"
  docker build \
    -f k8s/images/Dockerfile.cores \
    -t "${REGISTRY}/maven-cores:${TAG}" \
    .
}
```

Note the removed `docker push` line — that is the point of this step.

- [ ] **Step 4: Build the eight services in parallel**

Replace the `else` branch of the final dispatch (currently lines 122-128, the `for svc in "${SERVICES[@]}"` loop) with:

```bash
else
  # Build the service images concurrently. Each child re-execs this script with
  # SVC set, so it runs exactly one build_service; REGISTRY / TAG /
  # REUSE_EXISTING / VITE_API_BASE_URL are already exported by the caller and
  # are inherited. xargs exits non-zero if any child failed and `set -e` turns
  # that into a failed run -- verified on macOS xargs, which returns 1.
  # BUILDKIT_PROGRESS=plain because concurrent fancy progress renderers fight
  # over the terminal and produce unreadable output.
  echo "==> building ${#SERVICES[@]} services, ${BUILD_JOBS} at a time"
  printf '%s\n' "${SERVICES[@]}" \
    | BUILDKIT_PROGRESS=plain xargs -P "${BUILD_JOBS}" -I{} \
        env SVC={} SKIP_CORES=1 "$SELF"
  build_frontend
  build_mock_paypal
fi
```

- [ ] **Step 5: Syntax check**

```bash
bash -n k8s/images/build.sh && echo "SYNTAX OK"
```

Expected: `SYNTAX OK`.

- [ ] **Step 6: Verify no `maven-cores` push remains, and the AWS wrapper's contract still holds**

```bash
grep -n 'docker push' k8s/images/build.sh
grep -n 'SELF\|BUILD_JOBS' k8s/images/build.sh
```

Expected from the first: exactly **three** `docker push` lines — one each in `build_service`, `build_frontend`, and `build_mock_paypal`. `build_cores` must not appear.
Expected from the second: the `SELF=` assignment before the `cd`, `BUILD_JOBS=` after `TAG=`, and their two uses in the parallel branch.

- [ ] **Step 7: Exercise the full script against a throwaway registry**

`build.sh` refuses to run without a reachable registry, and its push path must be tested. A plain `registry:2` on 5001 satisfies both without a cluster. Do this only while the minikube cluster is **down** — otherwise port 5001 is taken by the registry forward.

```bash
docker run -d -p 5001:5000 --name probe-registry registry:2
sleep 2
curl -fsS http://localhost:5001/v2/ && echo " registry up"
time k8s/images/build.sh 2>&1 | tee "$SCRATCH/parallel.log" | tail -20
```

Expected: exit 0. Then confirm all ten service images landed and `maven-cores` did **not**:

```bash
curl -s http://localhost:5001/v2/_catalog
```

Expected: the eight services plus `frontend` and `mock-paypal-service`, and **no `maven-cores`** entry.

- [ ] **Step 8: Confirm the builds actually overlapped**

```bash
grep -c '==> building' "$SCRATCH/parallel.log" || true
grep -n '==> building' "$SCRATCH/parallel.log" | head -12
```

Expected: ten `==> building` lines. With `BUILD_JOBS=4` the eight service lines appear in interleaved bursts rather than one-at-a-time; the wall time from `time` should be well under the serial sum.

- [ ] **Step 9: Prove a failure still fails the whole run**

```bash
printf '%s\n' a b nope | xargs -P 2 -I{} sh -c '[ {} = nope ] && exit 7; echo ok {}'; echo "xargs exit=$?"
```

Expected: `xargs exit=1`. This is the mechanism the parallel branch relies on; under `set -euo pipefail` a non-zero `xargs` aborts `build.sh`.

- [ ] **Step 10: Tear down the throwaway registry**

```bash
docker rm -f probe-registry
```

Expected: the container name printed. Port 5001 is now free for `make k8s-cluster-up` in Task 4.

- [ ] **Step 11: Document the build knobs in `k8s/README.md`**

Add a new section immediately after the `## Daily` table:

```markdown
## Image builds

`k8s/images/build.sh` builds the eight JVM services **in parallel** — `BUILD_JOBS=4`
by default, override it with `BUILD_JOBS=8 make k8s-build`. This is safe only
because each service has a private BuildKit cache for its Maven repository
(`id=m2-<service>` in `Dockerfile.jvm`); Maven's local repository is not safe for
concurrent writes.

`maven-cores` is a build-only base image and is **not pushed** to the registry —
`Dockerfile.jvm` resolves it from the local image store. Nothing in the cluster
pulls it.

The Maven caches cost roughly 150 MB per service. `make k8s-build-cache-prune`
reclaims them; the next build re-downloads and re-warms.
```

- [ ] **Step 12: Commit**

```bash
git add k8s/images/build.sh k8s/README.md
git commit -m "perf(images): build services in parallel and stop pushing maven-cores

The eight JVM service images built one after another even though nothing
serialises them. Run them through xargs -P (BUILD_JOBS, default 4), re-execing
one child per service; xargs returns non-zero if any child fails and set -e
turns that into a failed run. Safe only because Dockerfile.jvm now gives each
service a private Maven cache -- a shared local repo under concurrent writes can
leave a truncated jar.

maven-cores is a build-only base that no pod pulls: Dockerfile.jvm resolves it
through FROM, from the local image store. Pushing 764 MB over the registry
forward on every build bought nothing, so drop it and check the local store
rather than the registry when REUSE_EXISTING is set.

BUILDKIT_PROGRESS=plain in the parallel branch -- concurrent progress renderers
fight over the terminal.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: End-to-end verification in-cluster

**Files:**
- Modify: `docs/superpowers/specs/2026-08-01-image-build-optimization-design.md` (Verification section — record the measured results)

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: the measured after-numbers, recorded next to the 459-downloads / 41s baseline in the spec.

This task needs a running cluster. A fast build that produces a broken JAR is worse than a slow one, so correctness comes before any timing number.

- [ ] **Step 1: Start from a cold cache, and record the disk baseline**

```bash
export SCRATCH=${SCRATCH:-/tmp/imgopt}; mkdir -p "$SCRATCH"
docker builder du | tail -3
make k8s-build-cache-prune
```

Expected: the prune runs and the post-prune `docker builder du` shows a smaller total. This is also the first real exercise of the Task 1 target.

- [ ] **Step 2: Bring the cluster up**

```bash
sudo -v && make k8s-cluster-up
```

Expected: four nodes, the registry port-forward on 5001, and the tunnel started. `sudo -v` must be in the *same* command and the *same* terminal — macOS caches the credential per-tty (`tty_tickets`).

- [ ] **Step 3: Cold full build — timed**

```bash
time make k8s-build 2>&1 | tee "$SCRATCH/e2e-cold.log" | tail -5
grep -cE 'Downloaded from central' "$SCRATCH/e2e-cold.log" || true
```

Expected: exit 0. The download count is high — a cold cache downloads everything, which is the documented graceful degradation, not a failure. Record the wall time.

- [ ] **Step 4: Warm full build — timed. This is the headline number**

```bash
time make k8s-build 2>&1 | tee "$SCRATCH/e2e-warm.log" | tail -5
grep -cE 'Downloaded from central' "$SCRATCH/e2e-warm.log" || true
```

Expected: exit 0, and a download count near zero. Record the wall time against the 41s-per-service baseline.

- [ ] **Step 5: Parallel-safety check — no corrupt artifact reached any image**

```bash
for s in authorization-server gateway inventory-service product-service \
         order-service payment-service orchestrator-service bff-service; do
  n=$(docker run --rm --entrypoint sh "localhost:5001/$s:dev" \
        -c 'unzip -l /app/app.jar 2>/dev/null | grep -c "BOOT-INF/lib/"')
  echo "$s $n"
done
```

Expected: eight lines, each with a `BOOT-INF/lib/` count in the hundreds. A zero or a `unzip` error means a truncated JAR — that is exactly the corruption per-service cache ids exist to prevent, and it invalidates the parallel design.

- [ ] **Step 6: Bring up the rest of the stack**

```bash
sudo -v && make k8s-bootstrap
```

Expected: completes and prints the status table. `k8s-build-reuse` finds every image already in the registry and skips rebuilding.

- [ ] **Step 7: Prove a rebuilt image actually serves traffic**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' http://api.microecom.local/product-service/v1/products
touch order-service/src/main/java/org/aibles/order_service/OrderServiceApplication.java
time make k8s-rebuild svc=order-service
kubectl -n apps rollout status deployment/order-service --timeout=180s
```

Expected: `200` from the storefront before the change; the rebuild finishes in **seconds, not ~41s**, with near-zero downloads; and the rollout reaches `successfully rolled out`. This is the real inner loop the whole change exists for.

- [ ] **Step 8: Confirm the service is healthy after the roll**

```bash
kubectl -n apps get pods -l app=order-service
kubectl -n apps logs deploy/order-service --tail=20 | grep -i 'started\|error' | tail -5
git checkout -- order-service/src/main/java/org/aibles/order_service/OrderServiceApplication.java
```

Expected: `1/1 Running`, `0` restarts, and a `Started OrderServiceApplication` line. A `CrashLoopBackOff` here means the fast build produced a JAR that does not boot — stop and investigate before recording any timing.

- [ ] **Step 9: Record the measured results in the spec**

In `docs/superpowers/specs/2026-08-01-image-build-optimization-design.md`, append to the `## Verification` section:

```markdown
### Measured results (2026-08-01, after implementation)

| Metric | Before | After |
|---|---|---|
| `order-service` source-only rebuild, wall | 41s | <fill in from Step 7> |
| `order-service` source-only rebuild, downloads | 459 | <fill in from Step 7> |
| Full `make k8s-build`, cold cache | n/a (serial) | <fill in from Step 3> |
| Full `make k8s-build`, warm cache | n/a (serial) | <fill in from Step 4> |
| Maven build cache on disk | 0 | <`docker builder du` after Step 4> |

All eight service JARs verified non-truncated (`BOOT-INF/lib/` entry counts in the hundreds), and
a rebuilt `order-service` rolled out and served traffic through the ingress.
```

Replace each `<fill in ...>` with the actual number recorded in that step. Do not commit the placeholders.

- [ ] **Step 10: Commit**

```bash
grep -n '<fill in' docs/superpowers/specs/2026-08-01-image-build-optimization-design.md
git add docs/superpowers/specs/2026-08-01-image-build-optimization-design.md
git commit -m "docs: record measured image-build results against the 459/41s baseline

Verified end to end on a live cluster: all ten images build, every service JAR
is intact (BOOT-INF/lib entry counts in the hundreds, so the parallel builds did
not corrupt a shared Maven repo), and a rebuilt order-service rolled out and
served traffic through the ingress.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

The `grep` must print nothing before committing — a committed `<fill in>` is a lie in the spec.

---

## Out of scope (from the spec — do not do these here)

- `deploy/` Helm work (Plan 2 onward).
- Registry-backed CI cache (`--cache-from` / `--cache-to`), deploy-refactor Phase 9.
- Any change to `frontend/` or `mock-paypal-service/` images.
- A root Maven aggregator pom.
- A root `.dockerignore` — ruled out by measurement (BuildKit transferred 24 kB of a 3.0 GB context).

## Known leftovers (noticed while planning, not fixed here)

- `aws/bootstrap/ecr.tf:58` still lists `maven-cores` in the ECR repository set. Harmless — an empty repository — but it becomes dead once Task 3 stops pushing it. Removing it means a `terraform apply` against the persistent bootstrap stack, which is a billed AWS action and the user's call.
- `k8s/images/build.sh:17` gates every run on `curl -fsS http://${REGISTRY}/v2/`. ECR serves HTTPS only, so `scripts/aws/push-images.sh` would fail that probe. Pre-existing, unrelated to this change, and untested since the minikube migration — flagged, not touched.
