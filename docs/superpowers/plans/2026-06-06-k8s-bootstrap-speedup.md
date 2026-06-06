# Speed up `make k8s-bootstrap` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make repeated `make k8s-down` → `make k8s-bootstrap` fast by preserving built images and pulled 3rd-party images across cluster recreation, while still producing a clean cluster.

**Architecture:** Three changes — (1) `k8s-cluster-down` stops deleting the local `kind-registry` so built images survive (new `k8s-nuke` for full wipe); (2) `build.sh` gains a `REUSE_EXISTING` mode that skips images already in the registry, used by a new `k8s-build-reuse` target that `k8s-bootstrap` calls; (3) a new `preload-images.sh` `kind load`s 3rd-party images from the host into fresh nodes to avoid cold docker.io pulls.

**Tech Stack:** GNU Make, bash, kind, Docker, local `registry:2`.

**Spec:** `docs/superpowers/specs/2026-06-06-k8s-bootstrap-speedup-design.md`

**Branch:** implement on `feat/mock-paypal-service` (per user).

---

## Context the engineer needs

- `K8S_CLUSTER := microecom` is defined in the `Makefile`. The kind cluster has 4 nodes (1 control-plane + 3 workers).
- The local registry is `kind-registry` (a `registry:2` container, `--restart=always`, on host port 5001). `k8s/kind/registry.sh` starts it if missing and (re)connects it to the `kind` docker network — it is idempotent and already run by `k8s-cluster-up`.
- Built images are tagged `localhost:5001/<name>:dev` where `<name>` ∈ `maven-cores`, the 8 services, `frontend`, `mock-paypal-service`.
- The Docker Registry HTTP v2 API answers `GET http://localhost:5001/v2/<repo>/manifests/<tag>` with 200 if the tag exists, 404 if not.
- `make` recipe lines MUST be indented with a literal TAB. Verify every target with `make -n <target>` (a "missing separator" error means spaces were used).
- These are infra/script changes; the "tests" are `make -n` parse checks, `bash -n` syntax checks, and a `curl` probe — there is no unit-test framework here. Mirror that style.

---

## File Structure

| File | Responsibility |
|---|---|
| `Makefile` *(modify)* | Preserve registry in `k8s-cluster-down`; add `k8s-nuke`; add `k8s-build-reuse` (+ `FORCE_BUILD`); point `k8s-bootstrap` at it; call `preload-images.sh` in `k8s-cluster-up`; `.PHONY` + help updates. |
| `k8s/images/build.sh` *(modify)* | Honor `REUSE_EXISTING` — skip building an image already present in the registry. |
| `k8s/kind/preload-images.sh` *(create)* | `kind load` manifest-referenced 3rd-party images that are on the host into the cluster nodes. |

---

## Task 1: Preserve the registry on teardown + `k8s-nuke`

**Files:**
- Modify: `Makefile` (`k8s-cluster-down` target, `.PHONY` line, help block)

- [ ] **Step 1: Stop deleting the registry in `k8s-cluster-down`**

Find:
```make
k8s-cluster-down:
	-kind delete cluster --name $(K8S_CLUSTER)
	-docker rm -f kind-registry
```
Replace with (recipe lines start with TAB):
```make
k8s-cluster-down:
	-kind delete cluster --name $(K8S_CLUSTER)
	@echo "==> cluster deleted; kind-registry kept (built images preserved). Use 'make k8s-nuke' to remove it too."
```

- [ ] **Step 2: Add the `k8s-nuke` target**

Immediately AFTER the `k8s-cluster-down` target's recipe (before `k8s-cluster-status`), insert:
```make

# Full clean slate: delete the cluster AND the local registry (drops all built
# images, forcing a cold rebuild + re-pull on the next bootstrap). Use this only
# when you truly want nothing reused; the normal `make k8s-down` keeps images.
k8s-nuke: k8s-apps-down
	-kind delete cluster --name $(K8S_CLUSTER)
	-docker rm -f kind-registry
	@echo "==> cluster + registry destroyed (full clean slate)"
```

- [ ] **Step 3: Add `k8s-nuke` to `.PHONY`**

Find:
```make
.PHONY: k8s-cluster-up k8s-cluster-down k8s-cluster-status k8s-stop k8s-start
```
Replace with:
```make
.PHONY: k8s-cluster-up k8s-cluster-down k8s-cluster-status k8s-nuke k8s-stop k8s-start
```

- [ ] **Step 4: Add a help line for `k8s-nuke`**

Find:
```make
	@echo "  make k8s-down         — tear down apps + cluster"
```
Replace with:
```make
	@echo "  make k8s-down         — tear down apps + cluster (keeps registry/images)"
	@echo "  make k8s-nuke         — full wipe incl. registry (cold rebuild next time)"
```

- [ ] **Step 5: Verify targets parse**

Run: `make -n k8s-cluster-down && echo '---' && make -n k8s-nuke`
Expected: both print their `kind delete` / `docker rm` / echo lines with NO "missing separator" and NO "No rule to make target". `k8s-nuke` should also show the `k8s-apps-down` prerequisite commands.

- [ ] **Step 6: Confirm the registry line is gone from cluster-down and present in nuke**

Run: `awk '/^k8s-cluster-down:/{f=1} /^k8s-nuke:/{f=2} f==1 && /docker rm -f kind-registry/{print "BUG: still in cluster-down"} f==2 && /docker rm -f kind-registry/{print "ok: in nuke"}' Makefile`
Expected: prints only `ok: in nuke` (no `BUG:` line).

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "feat(k8s): preserve kind-registry on k8s-down; add k8s-nuke for full wipe

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `REUSE_EXISTING` build mode + bootstrap rewire

**Files:**
- Modify: `k8s/images/build.sh`
- Modify: `Makefile` (`k8s-build-reuse` target, `.PHONY`, `k8s-bootstrap` prerequisite)

- [ ] **Step 1: Add registry-presence helpers to `build.sh`**

In `k8s/images/build.sh`, find:
```sh
REGISTRY="${REGISTRY:-localhost:5001}"
TAG="${TAG:-dev}"

cd "$(git rev-parse --show-toplevel)"
```
Replace with:
```sh
REGISTRY="${REGISTRY:-localhost:5001}"
TAG="${TAG:-dev}"

cd "$(git rev-parse --show-toplevel)"

# When REUSE_EXISTING is set, skip building an image whose tag is already in the
# local registry. Used by `make k8s-build-reuse` (the bootstrap path) so a
# down->bootstrap cycle does not rebuild unchanged images. `make k8s-build`
# leaves REUSE_EXISTING unset = always rebuild. Fails "closed": if the registry
# probe errors, the image is treated as absent and gets built.
image_in_registry() {  # $1=repo $2=tag -> exit 0 if present
  curl -fsS -o /dev/null \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://${REGISTRY}/v2/$1/manifests/$2" 2>/dev/null
}
reuse_or_build() {  # $1=repo -> exit 0 (caller should skip) if reusing
  if [ -n "${REUSE_EXISTING:-}" ] && image_in_registry "$1" "${TAG}"; then
    echo "==> reusing ${REGISTRY}/$1:${TAG} (already in registry)"
    return 0
  fi
  return 1
}
```

- [ ] **Step 2: Make each `build_*` function honor reuse**

In `build_cores`, find:
```sh
build_cores() {
  echo "==> building cores base image"
```
Replace with:
```sh
build_cores() {
  reuse_or_build "maven-cores" && return 0
  echo "==> building cores base image"
```

In `build_service`, find:
```sh
build_service() {
  local svc="$1"
  echo "==> building ${svc}"
```
Replace with:
```sh
build_service() {
  local svc="$1"
  reuse_or_build "${svc}" && return 0
  echo "==> building ${svc}"
```

In `build_frontend`, find:
```sh
build_frontend() {
  echo "==> building frontend"
```
Replace with:
```sh
build_frontend() {
  reuse_or_build "frontend" && return 0
  echo "==> building frontend"
```

In `build_mock_paypal`, find:
```sh
build_mock_paypal() {
  echo "==> building mock-paypal-service (Java 25, standalone Dockerfile)"
```
Replace with:
```sh
build_mock_paypal() {
  reuse_or_build "mock-paypal-service" && return 0
  echo "==> building mock-paypal-service (Java 25, standalone Dockerfile)"
```

- [ ] **Step 3: Verify `build.sh` parses**

Run: `bash -n k8s/images/build.sh && echo PARSE_OK`
Expected: `PARSE_OK`.

- [ ] **Step 4: Add `k8s-build-reuse` target + `.PHONY` in the Makefile**

Find:
```make
.PHONY: k8s-build k8s-rebuild
```
Replace with:
```make
.PHONY: k8s-build k8s-build-reuse k8s-rebuild
```

Then find the `k8s-build` target:
```make
k8s-build:
	@k8s/images/build.sh
```
Replace with (adds the reuse variant right after; recipe lines start with TAB):
```make
k8s-build:
	@k8s/images/build.sh

# Bootstrap build path: skip images already in the registry (fast down->bootstrap).
# `make k8s-bootstrap FORCE_BUILD=1` rebuilds everything from scratch instead.
k8s-build-reuse:
	@if [ -n "$(FORCE_BUILD)" ]; then k8s/images/build.sh; else REUSE_EXISTING=1 k8s/images/build.sh; fi
```

- [ ] **Step 5: Point `k8s-bootstrap` at `k8s-build-reuse`**

Find:
```make
k8s-bootstrap: k8s-cluster-up k8s-infra k8s-build k8s-seed k8s-seed-images k8s-apps k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest
```
Replace with (only `k8s-build` → `k8s-build-reuse`):
```make
k8s-bootstrap: k8s-cluster-up k8s-infra k8s-build-reuse k8s-seed k8s-seed-images k8s-apps k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest
```

- [ ] **Step 6: Verify the targets parse and wiring is correct**

Run: `make -n k8s-build-reuse`
Expected: prints a line containing `REUSE_EXISTING=1 k8s/images/build.sh` (FORCE_BUILD unset branch), no "missing separator".

Run: `make -n k8s-build-reuse FORCE_BUILD=1`
Expected: prints `k8s/images/build.sh` WITHOUT `REUSE_EXISTING=1`.

Run: `grep -n '^k8s-bootstrap:' Makefile`
Expected: the line contains `k8s-build-reuse` and NO bare `k8s-build` token (check: `grep -c 'k8s-build-reuse' Makefile` ≥ 1, and the bootstrap line does not list plain `k8s-build`).

- [ ] **Step 7: Behavioral check of the reuse helper (only if a cluster+registry is up; otherwise skip with a note)**

If `curl -fsS http://localhost:5001/v2/ >/dev/null 2>&1` succeeds (registry reachable), run:
```bash
REGISTRY=localhost:5001 bash -c '
  source <(sed -n "/^image_in_registry()/,/^}/p;/^REGISTRY=/p;/^TAG=/p" k8s/images/build.sh)
  image_in_registry maven-cores dev && echo "PRESENT" || echo "ABSENT"
  image_in_registry does-not-exist dev && echo "BUG" || echo "ABSENT-OK"
'
```
Expected: the bogus repo prints `ABSENT-OK` (never `BUG`). `maven-cores` prints `PRESENT` or `ABSENT` depending on whether it's been built. If the registry is not reachable, skip this step and note it — Step 6 already proves the wiring.

- [ ] **Step 8: Commit**

```bash
git add k8s/images/build.sh Makefile
git commit -m "feat(k8s): REUSE_EXISTING build mode; bootstrap skips images already in registry

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Preload 3rd-party images into fresh nodes

**Files:**
- Create: `k8s/kind/preload-images.sh`
- Modify: `Makefile` (`k8s-cluster-up` target)

- [ ] **Step 1: Create `k8s/kind/preload-images.sh`**

```sh
#!/usr/bin/env bash
# Load 3rd-party images referenced by the infra manifests from the host Docker
# into the kind nodes, so a freshly (re)created cluster does not cold-pull them
# from docker.io (the Confluent images are ~1.8GB). Images not yet on the host
# are skipped and pull normally the first time. Idempotent.
set -euo pipefail

CLUSTER_NAME='microecom'
cd "$(git rev-parse --show-toplevel)"

# Only run if the cluster exists (kind load targets its nodes).
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "preload-images: cluster '${CLUSTER_NAME}' not found, skipping"
  exit 0
fi

grep -rhE '^[[:space:]]*image:' k8s/infra/manifests/*.yaml \
  | awk '{print $2}' | sort -u \
  | while read -r img; do
      [ -n "$img" ] || continue
      if docker image inspect "$img" >/dev/null 2>&1; then
        echo "==> kind load $img"
        kind load docker-image "$img" --name "${CLUSTER_NAME}"
      else
        echo "skip (not on host yet, will pull): $img"
      fi
    done

echo "preload-images: done"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x k8s/kind/preload-images.sh`

- [ ] **Step 3: Verify it parses**

Run: `bash -n k8s/kind/preload-images.sh && echo PARSE_OK`
Expected: `PARSE_OK`.

- [ ] **Step 4: Verify the image list it derives is the expected 3rd-party set**

Run: `grep -rhE '^[[:space:]]*image:' k8s/infra/manifests/*.yaml | awk '{print $2}' | sort -u`
Expected: includes `apache/kafka:3.9.1`, `confluentinc/cp-kafka-connect:7.6.1`, `confluentinc/cp-schema-registry:7.7.1`, `minio/mc:...`, `minio/minio:...`, `mongo:7.0`, `mysql:8.0.40`, `redis:7.4-alpine`. (This is what the script will `kind load`.)

- [ ] **Step 5: Call it from `k8s-cluster-up`**

In the `Makefile`, find:
```make
	@k8s/kind/registry.sh
	@kubectl cluster-info --context kind-$(K8S_CLUSTER)
```
Replace with (preload after the registry is wired, before reporting cluster-info; recipe lines start with TAB):
```make
	@k8s/kind/registry.sh
	@k8s/kind/preload-images.sh
	@kubectl cluster-info --context kind-$(K8S_CLUSTER)
```

- [ ] **Step 6: Verify `k8s-cluster-up` parses and includes the preload call**

Run: `make -n k8s-cluster-up`
Expected: shows `k8s/kind/registry.sh`, then `k8s/kind/preload-images.sh`, then `kubectl cluster-info ...`, with no "missing separator".

- [ ] **Step 7: Commit**

```bash
git add k8s/kind/preload-images.sh Makefile
git commit -m "feat(k8s): preload 3rd-party images into kind nodes (skip cold docker.io pulls)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Live verification (interactive — run on the machine)

Runs against real Docker/kind. If a step fails, switch to `superpowers:systematic-debugging`.

- [ ] **Step 1: Baseline — ensure images exist once**

Run: `make k8s-bootstrap` (from whatever state; if first time it builds + pulls cold — that's expected). Confirm it completes and `make k8s-status` shows pods healthy. Note: the cluster + registry now hold all images.

- [ ] **Step 2: Fast cycle — down then bootstrap**

Run: `make k8s-down && time make k8s-bootstrap`
Expected:
- During `k8s-cluster-up`: `preload-images.sh` prints `==> kind load <img>` for the 3rd-party images (no long docker.io pulls).
- During the build phase: prints `==> reusing localhost:5001/<name>:dev (already in registry)` for all 11 images (no Maven/Vite builds run).
- Completes substantially faster than Step 1; `make k8s-status` + `make k8s-mysql-status` show a healthy cluster (both replicas `Replica_IO_Running/Replica_SQL_Running: Yes`).

- [ ] **Step 3: Force-rebuild escape hatch works**

Run: `make k8s-bootstrap FORCE_BUILD=1` (on the existing cluster)
Expected: the build phase actually rebuilds (prints `==> building <name>` rather than `reusing`).

- [ ] **Step 4: Full wipe still works**

Run: `make k8s-nuke`
Expected: deletes the cluster AND removes `kind-registry` (`docker ps -a | grep kind-registry` returns nothing). A subsequent `make k8s-bootstrap` does a cold build + pull (registry empty, images re-pulled), proving the cold path is intact.

*(No commit — verification only. Commit any defect fix at the layer it was found.)*

---

## Self-Review notes (already applied)

- **Spec coverage:** Component 1 (registry preserve + `k8s-nuke`) → Task 1 ✓; Component 2 (`REUSE_EXISTING` + `k8s-build-reuse` + bootstrap rewire + `FORCE_BUILD`) → Task 2 ✓; Component 3 (`preload-images.sh` + `k8s-cluster-up` wiring) → Task 3 ✓; acceptance items (parse checks, curl probe, fast cycle, FORCE_BUILD, nuke cold path) → Tasks 1–4 ✓. Out-of-scope items (k8s-reset, pull-through cache, node-count, parallel builds) intentionally excluded.
- **No placeholders:** every step has literal file content + exact commands and expected output.
- **Consistency:** registry repo names (`maven-cores`, `<svc>`, `frontend`, `mock-paypal-service`) match `build.sh`'s push tags; `REUSE_EXISTING`/`FORCE_BUILD` names consistent between `build.sh`, `k8s-build-reuse`, and the `FORCE_BUILD=1` escape; `k8s-bootstrap` now depends on `k8s-build-reuse` (defined in Task 2); `preload-images.sh` uses the same `microecom` cluster name as the rest of the Makefile.
