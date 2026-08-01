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
