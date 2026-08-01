# Deploy Refactor — Plan 1: Foundation (scaffold + minikube) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Scaffold the `deploy/` directory and migrate the local k8s cluster from kind to minikube — keeping the existing kustomize manifests untouched — so `make k8s-bootstrap` works end-to-end on minikube.

**Architecture:** This plan implements Phases 0 + 1 of the deploy refactor spec. It creates the empty `deploy/` tree (no behavior change), writes a `cluster.sh` that drives minikube lifecycle (start/stop/tunnel) and enables the minikube registry addon with a `kubectl port-forward` bridge so the host can push images, rewrites the Makefile's k8s-cluster targets to call it instead of kind, switches the registry from `localhost:5001` (kind-registry container) to `localhost:5000` (minikube registry addon — same address on host and pod side), and flips ingress-nginx from hostPort+ClusterIP to LoadBalancer so `minikube tunnel` exposes :80/:443. The kustomize manifests, vault seed, app seed, and everything inside the cluster stay exactly as-is — only the cluster boundary changes.

**Tech Stack:** minikube (docker driver), Helm (for ingress-nginx — unchanged), kubectl, bash, make.

**Spec:** `docs/superpowers/specs/2026-08-01-deploy-refactor-design.md` (Phases 0 + 1)

**Branch:** create `refactor/deploy-foundation` from current branch.

> **Implementation deviation (2026-08-01):** macOS Control Center owns host
> port 5000 on this machine. The user chose host port **5001** for the registry
> port-forward. Host builds therefore push `localhost:5001/<repo>:dev`, while
> minikube pods still pull the same registry repositories through the addon's
> node proxy at `localhost:5000/<repo>:dev`. Any host-side `5000` command below
> should be read as `5001`; pod manifests remain on `5000`.

---

## Registry approach (follows spec Q4-B)

The spec (line 432) says: kind used a manual `registry.sh` + `hosts.toml` per node;
minikube uses `minikube addons enable registry` — built-in, auto-wires all nodes,
no manual `hosts.toml`. The spec (line 338) sets `registry: localhost:5000` and
(line 340) `pullPolicy: Always`.

**How the minikube registry addon works (verified from addon source code):**

The addon deploys three resources in `kube-system`:

1. **`registry` Deployment** — the actual Docker registry container, listening on
   port 5000.
2. **`registry` Service** — **ClusterIP** (NOT NodePort), port 80 → targetPort 5000.
   Reachable inside the cluster at `registry.kube-system.svc.cluster.local:80`.
3. **`registry-proxy` DaemonSet** — runs `kube-registry-proxy:0.4` on **every node**
   with `hostPort: 5000`. It proxies `localhost:5000` on each node to
   `registry.kube-system.svc.cluster.local:80`.

**What this means for pod-side pulls:**
- Pods reference `localhost:5000/<svc>:dev` — the proxy DaemonSet runs on every
  node, so every pod's node has `localhost:5000` forwarding to the in-cluster
  registry. No containerd `hosts.toml` patches needed (unlike kind). This auto-
  wires all nodes in a multi-node profile because it's a DaemonSet.
- `imagePullPolicy: Always` ensures each pod restart pulls the latest `:dev` tag.

**What this means for host-side pushes:**
- The registry Service is **ClusterIP** — NOT reachable from the macOS host
  directly (the Docker driver doesn't bridge node IPs to the host).
- `cluster.sh` runs `kubectl port-forward -n kube-system svc/registry 5000:80`
  as a **background process** (managed via PID file). This maps the host's
  `localhost:5000` → registry Service:80 → registry pod:5000.
- The host then does `docker push localhost:5000/<svc>:dev`.
- Docker Desktop trusts `localhost:5000` as insecure automatically (localhost is
  always trusted) — no Docker Desktop config needed.
- **Same image reference on both sides**: host pushes `localhost:5000/<svc>:dev`,
  pods pull `localhost:5000/<svc>:dev`. The port-forward (host side) and proxy
  DaemonSet (pod side) both reach the same in-cluster registry. Clean and symmetric.

**What this means for the manifests:** the 10 service `deployment.yaml` files
change `image: localhost:5001/<svc>:dev` → `image: localhost:5000/<svc>:dev`.
`imagePullPolicy: Always` stays as-is. The `k8s/images/build.sh` changes
`REGISTRY=localhost:5001` → `REGISTRY=localhost:5000` (hardcoded — no auto-discovery
needed, the port-forward makes localhost:5000 reachable from the host).

---

## File map

**Create:**
- `deploy/README.md` — placeholder onboarding doc (Phase 0 scaffold)
- `deploy/scripts/cluster.sh` — minikube lifecycle (start/stop/pause/resume/delete/tunnel) + registry port-forward management
- `deploy/scripts/lib/colors.sh` — shared logging (copy of `scripts/lib/colors.sh`)

**Modify:**
- `Makefile` — rewrite `k8s-cluster-up/down/status/stop/start/nuke` + `k8s-build/k8s-build-reuse/k8s-rebuild` targets to use minikube + `deploy/scripts/cluster.sh`; update `k9s` + `k8s-use/k8s-ctx` context names; update help text
- `k8s/images/build.sh` — change `REGISTRY` default from `localhost:5001` to `localhost:5000` (minikube registry addon via port-forward); keep `docker push` + `image_in_registry` registry-probe logic (unchanged mechanism, new endpoint)
- `k8s/infra/values/ingress-nginx.yaml` — change `service.type: ClusterIP` + `hostPort` → `service.type: LoadBalancer`; remove hostPort + nodeSelector + tolerations (minikube tunnel handles exposure)
- `k8s/apps/base/*/deployment.yaml` (10 files) — `image: localhost:5001/<svc>:dev` → `image: localhost:5000/<svc>:dev`; `imagePullPolicy: Always` stays as-is
- `k8s/CLAUDE.md` — add a note that kind is replaced by minikube (scars about `containerdConfigPatches`/`hosts.toml`/`extraPortMappings` are now historical)

**Delete (after verifying nothing references them):**
- `k8s/kind/cluster.yaml`
- `k8s/kind/registry.sh`
- `k8s/kind/preload-images.sh`
- (the `k8s/kind/` directory itself)

---

## Prerequisites (engineer checks before starting)

1. **minikube installed:** `minikube version` prints ≥ 1.30. If missing: `brew install minikube`.
2. **Docker running:** `docker info` succeeds. minikube's docker driver needs Docker Desktop / colima / OrbStack running.
3. **helm installed:** `helm version` prints v3.x. Used by `k8s/infra/install.sh` (unchanged this plan).
4. **kubectl installed:** `kubectl version --client` works.
5. **The kind cluster is currently down** (so there's no port conflict on :80/:443): `kind get clusters` — if `microecom` exists, run `make k8s-down` first. Also stop the old kind-registry container if it's still running on port 5000: `docker rm -f kind-registry 2>/dev/null || true` (the old kind-registry used port 5001, but check 5000 too — the new port-forward needs it free).
6. **Port 5000 is free on the host:** `lsof -i :5000` should show nothing. The registry port-forward binds to localhost:5000. If something is already listening, the forward will fail with a clear error message.
7. **Current branch:** create `refactor/deploy-foundation` from the branch the spec was committed on (`feat/aws-live-deploy`).

```bash
git checkout -b refactor/deploy-foundation feat/aws-live-deploy
```

---

## Task 1: Scaffold the `deploy/` directory (Phase 0)

**Files:**
- Create: `deploy/README.md`
- Create: `deploy/scripts/lib/colors.sh` (copy of `scripts/lib/colors.sh`)
- Modify: `.gitignore` — add `deploy/.run/` (runtime PID files from cluster.sh)

- [x] **Step 1: Create the `deploy/` directory tree**

```bash
mkdir -p deploy/{charts,compose,terraform,secrets,seed,scripts/lib,images}
```

Verify:
```bash
find deploy -type d | sort
```
Expected output:
```
deploy
deploy/charts
deploy/compose
deploy/images
deploy/scripts
deploy/scripts/lib
deploy/seed
deploy/secrets
deploy/terraform
```

- [x] **Step 1b: Add `deploy/.run/` to `.gitignore`**

`cluster.sh` creates `deploy/.run/` at runtime for the registry-forward PID file. Add it to `.gitignore`:

```bash
echo "deploy/.run/" >> .gitignore
```

Verify:
```bash
grep 'deploy/.run/' .gitignore
```
Expected: `deploy/.run/`

- [x] **Step 2: Copy `colors.sh` into `deploy/scripts/lib/`**

The deploy scripts will use the same logging helpers as the existing `scripts/`. Copy it so `deploy/scripts/` is self-contained.

```bash
cp scripts/lib/colors.sh deploy/scripts/lib/colors.sh
```

Verify:
```bash
head -5 deploy/scripts/lib/colors.sh
```
Expected: the first lines of the colors library (`#!/bin/bash` + color code definitions).

- [x] **Step 3: Write the `deploy/README.md` placeholder**

This is the newcomer onboarding doc. For now it's a stub pointing at the spec; later plans fill it in. Create `deploy/README.md` with this exact content:

```markdown
# deploy/ — deployment structure

This directory consolidates all deployment artifacts for the three target
environments: **docker-compose** (fast inner loop), **minikube** (local k8s),
and **AWS EKS** (cloud).

## Status

This is a work-in-progress refactor. See the design spec:
`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`

## Target layout (when complete)

```
deploy/
├── charts/microecom/   # Helm umbrella chart (infra + apps subcharts)
├── compose/            # docker-compose files
├── terraform/          # AWS IaC
├── secrets/            # canonical secret definitions + env contexts
├── seed/               # canonical seed data
├── scripts/            # env-aware deploy scripts (make <verb> ENV=<env>)
└── images/             # Dockerfiles + build.sh
```

## Quick start (current — minikube, kustomize still in use)

```bash
make k8s-bootstrap    # one-shot: minikube cluster + infra + images + seed + apps
make k8s-status       # pod health across namespaces
make k8s-down         # tear it all down
```
```

- [x] **Step 4: Commit**

```bash
git add deploy/ .gitignore
git commit -m "deploy: scaffold deploy/ directory tree (Phase 0)

Empty directory structure + README placeholder + colors.sh copy.
Adds deploy/.run/ to .gitignore (runtime PID files from cluster.sh).
No behavior change — the old k8s/, aws/, docker/ paths still work.
See docs/superpowers/specs/2026-08-01-deploy-refactor-design.md"
```

---

## Task 2: Write `deploy/scripts/cluster.sh` — minikube lifecycle

**Files:**
- Create: `deploy/scripts/cluster.sh`

This script owns all minikube cluster lifecycle: start, stop, pause, resume, delete, and the `minikube tunnel` background process for ingress :80/:443. It also enables the minikube registry addon (the spec's Q4-B local-registry approach) and manages a `kubectl port-forward` background process so the host can push images to `localhost:5000`. The Makefile targets call it with a subcommand.

- [x] **Step 1: Write `deploy/scripts/cluster.sh`**

Create `deploy/scripts/cluster.sh` with this exact content:

```bash
#!/usr/bin/env bash
# minikube cluster lifecycle for the microecom local k8s env.
#
# Subcommands:
#   up               — create the cluster (4 nodes, docker driver) + enable registry addon
#                      + start registry port-forward (host localhost:5000 → registry svc:80)
#   down             — stop registry forward + delete the cluster entirely (full wipe)
#   stop             — stop registry forward + stop the cluster (preserve data + images)
#   start            — resume a stopped cluster (re-enables addon, re-starts forward,
#                      re-seeds Vault, bounces apps)
#   tunnel           — start minikube tunnel in the foreground (exposes LoadBalancer
#                      services at 127.0.0.1 — needed for ingress :80/:443)
#   registry-forward — start the registry port-forward in the background
#   registry-stop    — stop the registry port-forward
#   status           — print cluster + nodes + registry addon + forward status
#
# Replaces k8s/kind/{cluster.yaml,registry.sh,preload-images.sh}.
# The old kind cluster is gone; this is the one local k8s path now.
set -euo pipefail

CLUSTER_NAME="microecom"
NODES=4
CPUS=4
MEMORY=6g

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/deploy/scripts/lib/colors.sh"

RUN_DIR="$ROOT/deploy/.run"
REGISTRY_FORWARD_PIDFILE="$RUN_DIR/registry-forward.pid"
mkdir -p "$RUN_DIR"

usage() {
  echo "usage: cluster.sh <up|down|stop|start|tunnel|registry-forward|registry-stop|status>"
  exit 1
}

# --- Registry port-forward helpers ---

# Start kubectl port-forward so the host can push to localhost:5000.
# The registry addon's Service is ClusterIP (port 80) — not reachable from
# the macOS host directly. This forward bridges host:5000 → svc:80 → pod:5000.
# Pods pull via localhost:5000 through the addon's proxy DaemonSet (hostPort 5000
# on every node). Same image reference on both sides: localhost:5000/<svc>:dev.
start_registry_forward() {
  if ! kubectl get svc -n kube-system registry >/dev/null 2>&1; then
    log_err "registry addon not found — run 'cluster.sh up' first"
    return 1
  fi

  # Kill any existing forward
  stop_registry_forward 2>/dev/null || true

  # Check port 5000 is free on the host
  if lsof -i :5000 >/dev/null 2>&1; then
    log_err "port 5000 is already in use on the host."
    log_err "Free it (e.g. stop the old kind-registry: docker rm -f kind-registry) or:"
    log_err "  $0 registry-stop"
    return 1
  fi

  log_info "starting registry port-forward: localhost:5000 → kube-system/registry:80"
  kubectl port-forward -n kube-system svc/registry 5000:80 &
  local pf_pid=$!
  echo "$pf_pid" > "$REGISTRY_FORWARD_PIDFILE"

  # Wait for it to be ready (retry up to 15s)
  local i
  for i in $(seq 1 15); do
    if curl -fsS -o /dev/null "http://localhost:5000/v2/" 2>/dev/null; then
      log_ok "registry forward ready — push with: docker push localhost:5000/<svc>:dev"
      return 0
    fi
    sleep 1
  done

  log_warn "registry forward started (pid=$pf_pid) but localhost:5000 not responding yet"
  log_warn "check: curl http://localhost:5000/v2/"
  return 0
}

# Stop the registry port-forward if running.
stop_registry_forward() {
  if [[ -f "$REGISTRY_FORWARD_PIDFILE" ]]; then
    local pid
    pid=$(cat "$REGISTRY_FORWARD_PIDFILE" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log_info "stopped registry forward (pid=$pid)"
    fi
    rm -f "$REGISTRY_FORWARD_PIDFILE"
  fi
}

# --- Cluster lifecycle ---

cmd_up() {
  log_info "Starting minikube cluster '${CLUSTER_NAME}' (${NODES} nodes, docker driver)..."

  # Delete any stale cluster with the same name first (idempotent bring-up).
  if minikube status -p "$CLUSTER_NAME" >/dev/null 2>&1; then
    log_info "Cluster already exists — deleting and recreating for a clean state"
    minikube delete -p "$CLUSTER_NAME"
  fi

  minikube start \
    -p "$CLUSTER_NAME" \
    --driver=docker \
    --nodes="$NODES" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --kubernetes-version=1.30.0 \
    --insecure-registry="localhost:5000"

  # Enable the registry addon — deploys:
  #   1. registry Deployment (actual Docker registry, port 5000)
  #   2. registry Service (ClusterIP, port 80 → targetPort 5000)
  #   3. registry-proxy DaemonSet (hostPort 5000 on EVERY node → svc:80)
  # Pods pull localhost:5000/<img>:dev via the proxy; no hosts.toml needed.
  # This replaces kind's registry.sh + hosts.toml approach.
  log_info "Enabling minikube registry addon..."
  minikube addons enable registry -p "$CLUSTER_NAME"

  # Wait for the registry pod + proxy DaemonSet to be ready.
  log_info "Waiting for registry pods to be ready..."
  kubectl -n kube-system wait \
    --for=condition=ready pod \
    -l kubernetes.io/minikube-addons=registry \
    --timeout=5m 2>/dev/null || log_warn "registry pods not ready yet — forward will retry"

  # Start the port-forward so the host can push images.
  start_registry_forward

  log_ok "minikube cluster '${CLUSTER_NAME}' is up"
  log_info "kubectl context: $(kubectl config current-context)"
  log_info "registry: host pushes to localhost:5000, pods pull from localhost:5000 (same address)"
  log_info ""
  log_info "Next: start a tunnel for ingress (run in a separate terminal):"
  log_info "  make k8s-tunnel"
  log_info ""
  log_info "Then: make k8s-infra  (deploy infra via Helm + manifests)"
}

cmd_down() {
  stop_registry_forward
  log_info "Deleting minikube cluster '${CLUSTER_NAME}'..."
  minikube delete -p "$CLUSTER_NAME" || true
  log_ok "cluster deleted (full wipe — next 'up' rebuilds from scratch)"
}

cmd_stop() {
  stop_registry_forward
  log_info "Stopping minikube cluster '${CLUSTER_NAME}' (data + images preserved)..."
  minikube stop -p "$CLUSTER_NAME"
  log_ok "stopped. Resume with: cluster.sh start"
}

cmd_start() {
  log_info "Resuming minikube cluster '${CLUSTER_NAME}'..."
  # Note: --insecure-registry is ignored on resume (only applies at creation
  # time in cmd_up). It's already baked into the cluster config from the
  # initial `up`. No need to pass it here.
  minikube start -p "$CLUSTER_NAME"

  # The registry addon should survive stop/start, but verify it's there.
  if ! kubectl get svc -n kube-system registry >/dev/null 2>&1; then
    log_info "registry addon missing — re-enabling..."
    minikube addons enable registry -p "$CLUSTER_NAME"
    kubectl -n kube-system wait \
      --for=condition=ready pod \
      -l kubernetes.io/minikube-addons=registry \
      --timeout=5m 2>/dev/null || true
  fi

  # Restart the registry port-forward.
  start_registry_forward

  # Vault dev-mode is in-memory — secrets are lost on pod restart. Re-seed.
  log_info "waiting for Vault to be ready..."
  kubectl -n infra wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=5m

  log_info "re-seeding Vault (dev mode is in-memory)..."
  kubectl -n bootstrap delete job vault-seed --ignore-not-found >/dev/null
  kubectl apply -k k8s/infra/jobs/03-vault-seed
  kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/vault-seed

  log_info "restarting apps so they re-read Vault..."
  kubectl -n apps rollout restart deployment
  kubectl -n apps rollout status deployment --timeout=10m

  log_ok "cluster resumed. Check: make k8s-status && make k8s-mysql-status"
}

cmd_tunnel() {
  log_info "Starting minikube tunnel (Ctrl-C to stop)..."
  log_info "This exposes LoadBalancer services at 127.0.0.1 — needed for ingress :80/:443."
  log_info "Keep this running in a terminal while you use the cluster."
  minikube tunnel -p "$CLUSTER_NAME"
}

cmd_registry_forward() {
  start_registry_forward
}

cmd_registry_stop() {
  stop_registry_forward
  log_ok "registry forward stopped"
}

cmd_status() {
  minikube status -p "$CLUSTER_NAME" || echo "(cluster not running)"
  echo ""
  kubectl get nodes -o wide 2>/dev/null || echo "(kubectl context not set — run: kubectl config use-context $CLUSTER_NAME)"
  echo ""
  echo "Registry addon:"
  kubectl get svc -n kube-system registry 2>/dev/null || echo "  (not enabled)"
  echo ""
  echo "Registry port-forward:"
  if [[ -f "$REGISTRY_FORWARD_PIDFILE" ]]; then
    local pid
    pid=$(cat "$REGISTRY_FORWARD_PIDFILE" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "  running (pid=$pid) — localhost:5000 → kube-system/registry:80"
      if curl -fsS -o /dev/null "http://localhost:5000/v2/" 2>/dev/null; then
        echo "  health: OK (registry API responding)"
      else
        echo "  health: WARNING (localhost:5000 not responding — forward may be stale)"
      fi
    else
      echo "  stale (pid file exists but process is dead — run: cluster.sh registry-forward)"
    fi
  else
    echo "  not running (run: cluster.sh registry-forward)"
  fi
}

case "${1:-}" in
  up)               cmd_up ;;
  down)             cmd_down ;;
  stop)             cmd_stop ;;
  start)            cmd_start ;;
  tunnel)           cmd_tunnel ;;
  registry-forward) cmd_registry_forward ;;
  registry-stop)    cmd_registry_stop ;;
  status)           cmd_status ;;
  *)                usage ;;
esac
```

- [x] **Step 2: Make it executable**

```bash
chmod +x deploy/scripts/cluster.sh
```

- [x] **Step 3: Syntax-check it**

```bash
bash -n deploy/scripts/cluster.sh
```
Expected: no output (exit 0). If there's a syntax error, fix it before continuing.

- [x] **Step 4: Commit**

```bash
git add deploy/scripts/cluster.sh
git commit -m "deploy: add cluster.sh for minikube lifecycle

Replaces k8s/kind/{cluster.yaml,registry.sh,preload-images.sh} with a
single script driving minikube: up/down/stop/start/tunnel/status.
- 4 nodes, docker driver (matches the old kind topology)
- enables minikube registry addon (in-cluster registry + proxy DaemonSet
  on every node — replaces kind's manual registry.sh + hosts.toml)
- manages kubectl port-forward (background PID file) so the host can
  push to localhost:5000 — the addon Service is ClusterIP, not NodePort,
  so the forward is required for host-side docker push
- minikube tunnel for ingress :80/:443 (LoadBalancer service model)
- start (resume) verifies registry addon + re-starts forward + re-seeds
  Vault + bounces apps"
```

---

## Task 3: Rewrite Makefile k8s-cluster + k8s-build targets for minikube

**Files:**
- Modify: `Makefile` (the k8s-cluster-* and k8s-build/k8s-rebuild sections)

- [x] **Step 1: Rewrite the cluster lifecycle targets**

In the Makefile, find the block starting with `K8S_CLUSTER := microecom` and the `.PHONY: k8s-cluster-up k8s-cluster-down k8s-cluster-status k8s-nuke k8s-stop k8s-start` line. Replace the entire block from `K8S_CLUSTER := microecom` through the end of the `k8s-start` target (the `echo "cluster resumed..."` line) with:

```make
# ============================================================================
# Kubernetes (local minikube cluster)
# See docs/superpowers/specs/2026-08-01-deploy-refactor-design.md
# ============================================================================

K8S_CLUSTER := microecom

.PHONY: k8s-cluster-up k8s-cluster-down k8s-cluster-status k8s-nuke k8s-stop k8s-start k8s-tunnel

k8s-cluster-up:
	@deploy/scripts/cluster.sh up

k8s-cluster-down:
	@deploy/scripts/cluster.sh down

k8s-cluster-status:
	@deploy/scripts/cluster.sh status

# Full clean slate: delete the cluster (drops all PVC data + registry images).
# Use k8s-cluster-down for the soft delete; k8s-nuke is the same as down for
# minikube (the registry addon is inside the cluster, so it's wiped with it).
k8s-nuke: k8s-apps-down
	@deploy/scripts/cluster.sh down
	@echo "==> cluster destroyed (full clean slate)"

# Pause the cluster without destroying it. minikube stop freezes the containers;
# all PVC data (MySQL/Mongo/Kafka/Redis/MinIO) and loaded images survive.
# Resume with `make k8s-start` — far faster than a full bootstrap.
k8s-stop:
	@deploy/scripts/cluster.sh stop

# Resume a stopped cluster. Restarts the nodes, waits for infra, RE-SEEDS Vault
# (dev mode is in-memory, so its secrets are lost on pod restart), and bounces
# the apps (which crash-loop on an empty Vault).
k8s-start:
	@deploy/scripts/cluster.sh start

# Start minikube tunnel in the FOREGROUND — exposes LoadBalancer services
# (ingress-nginx) at 127.0.0.1 so the /etc/hosts entries resolve. Run this in a
# SEPARATE terminal; it must stay alive while you use the cluster. Without it,
# http://microecom.local etc. won't connect.
k8s-tunnel:
	@deploy/scripts/cluster.sh tunnel
```

- [x] **Step 2: Rewrite the build targets**

Find the `.PHONY: k8s-build k8s-build-reuse k8s-rebuild` line and the three target bodies (`k8s-build`, `k8s-build-reuse`, `k8s-rebuild`). Replace the whole block with:

```make
.PHONY: k8s-build k8s-build-reuse k8s-rebuild k8s-registry-forward k8s-registry-stop

# Build all service images and push to the minikube registry addon.
# Requires the registry port-forward (started automatically by k8s-cluster-up,
# or run: make k8s-registry-forward). build.sh pushes to localhost:5000.
k8s-build:
	@k8s/images/build.sh

# Bootstrap build path: skip images already in the registry (fast down->bootstrap).
# `make k8s-bootstrap FORCE_BUILD=1` rebuilds everything from scratch instead.
k8s-build-reuse:
	@if [ -n "$(FORCE_BUILD)" ]; then k8s/images/build.sh; else REUSE_EXISTING=1 k8s/images/build.sh; fi

# Rebuild ONE service image + push to registry + rollout restart.
k8s-rebuild:
	@if [ -z "$(svc)" ]; then echo "Usage: make k8s-rebuild svc=NAME"; exit 1; fi
	@SVC=$(svc) SKIP_CORES=1 k8s/images/build.sh
	@kubectl -n apps rollout restart deployment/$(svc)

# Start/stop the registry port-forward (host localhost:5000 → kube-system/registry:80).
# Normally auto-managed by k8s-cluster-up/down/stop/start — these are for manual control.
k8s-registry-forward:
	@deploy/scripts/cluster.sh registry-forward
k8s-registry-stop:
	@deploy/scripts/cluster.sh registry-stop
```

- [x] **Step 3: Update the `k8s-bootstrap` target to include `k8s-tunnel` guidance**

Find the `k8s-bootstrap:` target. Its dependency line is:
```
k8s-bootstrap: k8s-cluster-up k8s-infra k8s-build-reuse k8s-seed k8s-seed-images k8s-apps k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest
```
Keep it as-is (the tunnel is a separate manual step — it must run in the foreground and can't be a make dependency). But update the final echo block at the end of the target to mention the tunnel. Find:

```make
	@echo "  Final step: add these lines to /etc/hosts (one-time):"
	@echo ""
	@echo "    127.0.0.1 microecom.local"
	@echo "    127.0.0.1 api.microecom.local"
	@echo ""
	@echo "  Then verify:"
	@echo "    curl -i http://api.microecom.local/authorization-server/actuator/health/liveness"
	@echo "    open http://microecom.local"
```

Replace with:

```make
	@echo "  Final steps:"
	@echo ""
	@echo "  1. Add these lines to /etc/hosts (one-time):"
	@echo ""
	@echo "       127.0.0.1 microecom.local"
	@echo "       127.0.0.1 api.microecom.local"
	@echo "       127.0.0.1 media.microecom.local"
	@echo "       127.0.0.1 grafana.microecom.local"
	@echo "       127.0.0.1 vm.microecom.local"
	@echo ""
	@echo "  2. Start the minikube tunnel in a SEPARATE terminal (keep it running):"
	@echo ""
	@echo "       make k8s-tunnel"
	@echo ""
	@echo "  3. Verify:"
	@echo "       curl -i http://api.microecom.local/authorization-server/actuator/health/liveness"
	@echo "       open http://microecom.local"
```

- [x] **Step 4: Update the `k9s` target context name**

Find the `k9s:` target. It has a `case` block mapping `ENV` to a context. Find the line:
```
  ""|local) ctx=kind-microecom ;;
```
Replace with:
```
  ""|local) ctx=microecom ;;
```

- [x] **Step 5: Update the `k8s-use` / `k8s-ctx` targets context name**

Find the `k8s-use:` target. It has the same `case` block. Find:
```
  ""|local) ctx=kind-microecom ;;
```
Replace with:
```
  ""|local) ctx=microecom ;;
```

- [x] **Step 6: Update the help text**

Find the help target's Kubernetes section. It currently says "Kubernetes (local kind cluster):". Find that line and replace `kind` with `minikube`:

```
	@echo "Kubernetes (local minikube cluster):"
```

Also add the `k8s-tunnel` and `k8s-registry-forward` targets to the help. After the `make k8s-status` help line, add:
```make
	@echo "  make k8s-tunnel           — start minikube tunnel (separate terminal, for ingress :80/:443)"
	@echo "  make k8s-registry-forward — start registry port-forward (manual; auto-managed by cluster up)"
```

- [x] **Step 7: Verify the Makefile parses**

```bash
make -n k8s-cluster-up
```
Expected: prints the command `deploy/scripts/cluster.sh up` (dry-run, no execution). No errors.

```bash
make -n k8s-tunnel
```
Expected: prints `deploy/scripts/cluster.sh tunnel`.

```bash
make -n k8s-registry-forward
```
Expected: prints `deploy/scripts/cluster.sh registry-forward`.

- [x] **Step 8: Commit**

```bash
git add Makefile
git commit -m "make: switch k8s-cluster + k8s-build targets from kind to minikube

- k8s-cluster-up/down/stop/start/status → deploy/scripts/cluster.sh
- k8s-tunnel new target (minikube tunnel for ingress :80/:443)
- k8s-build/k8s-rebuild: build.sh now pushes to minikube registry addon
  via localhost:5000 port-forward (hardcoded, no auto-discovery)
- k8s-registry-forward/stop: manual control of the port-forward
  (auto-managed by cluster up/down/stop/start)
- k9s + k8s-use context: kind-microecom → microecom
- help text: kind → minikube, add k8s-tunnel line"
```

---

## Task 4: Update `k8s/images/build.sh` — registry endpoint change (5001 → 5000)

**Files:**
- Modify: `k8s/images/build.sh`

The script currently builds images tagged `localhost:5001/<svc>:dev` and pushes to the kind-registry container. The only change needed: replace the hardcoded `localhost:5001` with `localhost:5000` (the minikube registry addon's address, reachable from the host via the `kubectl port-forward` managed by `cluster.sh`). The `docker push` mechanism, `image_in_registry` probe, and `REUSE_EXISTING` logic all stay — they work identically against any HTTP registry endpoint.

Both the host (via port-forward) and pods (via the proxy DaemonSet) use `localhost:5000` — same address, same image reference. No auto-discovery needed.

- [x] **Step 1: Update `build.sh` — change REGISTRY default to localhost:5000**

Edit `k8s/images/build.sh`. Replace the entire file with:

```bash
#!/usr/bin/env bash
# Build images for the local minikube cluster and push to the minikube registry addon.
#
# Usage:
#   k8s/images/build.sh                 # build cores + all services
#   SVC=order-service k8s/images/build.sh   # build cores + one service
#   SVC=cores k8s/images/build.sh           # rebuild cores only
#
# Images are pushed to localhost:5000 (minikube registry addon, reachable from
# the host via kubectl port-forward managed by deploy/scripts/cluster.sh).
# Pods pull them via localhost:5000 (the addon's proxy DaemonSet redirects
# inside every node). Manifests reference localhost:5000/<svc>:dev with
# imagePullPolicy: Always. The inner loop is:
#   make k8s-rebuild svc=order-service   # build + push + rollout restart
set -euo pipefail

TAG="${TAG:-dev}"

# The registry is localhost:5000 — same address on host (via port-forward) and
# pod (via proxy DaemonSet). The REGISTRY env var can override for debugging.
# Prerequisite: `make k8s-cluster-up` (starts the port-forward automatically).
REGISTRY="${REGISTRY:-localhost:5000}"

# Verify the registry is reachable (port-forward is up).
if ! curl -fsS -o /dev/null "http://${REGISTRY}/v2/" 2>/dev/null; then
  echo "ERROR: registry at ${REGISTRY} is not reachable." >&2
  echo "       Run 'make k8s-cluster-up' (starts the port-forward automatically)" >&2
  echo "       or 'make k8s-registry-forward' to start just the forward." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

# When REUSE_EXISTING is set, skip building an image already in the registry.
# Used by `make k8s-build-reuse` (the bootstrap path) so a down->bootstrap cycle
# does not rebuild unchanged images. `make k8s-build` leaves REUSE_EXISTING unset
# = always rebuild. Fails "closed": if the registry probe errors, the image is
# treated as absent and gets built.
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

SERVICES=(
  authorization-server
  gateway
  inventory-service
  product-service
  order-service
  payment-service
  orchestrator-service
  bff-service
)

build_cores() {
  reuse_or_build "maven-cores" && return 0
  echo "==> building cores base image"
  docker build \
    -f k8s/images/Dockerfile.cores \
    -t "${REGISTRY}/maven-cores:${TAG}" \
    .
  docker push "${REGISTRY}/maven-cores:${TAG}"
}

build_service() {
  local svc="$1"
  reuse_or_build "${svc}" && return 0
  echo "==> building ${svc}"
  docker build \
    -f k8s/images/Dockerfile.jvm \
    --build-arg "SERVICE=${svc}" \
    --build-arg "CORES_IMAGE=${REGISTRY}/maven-cores:${TAG}" \
    -t "${REGISTRY}/${svc}:${TAG}" \
    .
  docker push "${REGISTRY}/${svc}:${TAG}"
}

# Always rebuild cores first unless explicitly skipped (cores changes are rare,
# but service builds depend on the cores image existing in the registry).
if [ "${SVC:-}" = "cores" ]; then
  build_cores
  exit 0
fi

if [ -z "${SKIP_CORES:-}" ]; then
  build_cores
fi

build_frontend() {
  reuse_or_build "frontend" && return 0
  echo "==> building frontend"
  # VITE_API_BASE_URL is inlined at build time (Vite compiles env vars in).
  #   - local/k8s (var UNSET): defaults to http://api.microecom.local (nginx host).
  #   - AWS (var set to ""): kept empty → the SPA issues RELATIVE calls
  #     (fetch('/bff-service/v1/…')) and is served same-origin behind the ALB.
  # The dash (no colon) is load-bearing: ${VAR-default} only falls back when the
  # var is UNSET, so an intentional empty value from AWS survives. ${VAR:-default}
  # would clobber the empty string back to the local host.
  docker build \
    -f frontend/Dockerfile \
    --build-arg "VITE_API_BASE_URL=${VITE_API_BASE_URL-http://api.microecom.local}" \
    -t "${REGISTRY}/frontend:${TAG}" \
    frontend
  docker push "${REGISTRY}/frontend:${TAG}"
}

build_mock_paypal() {
  reuse_or_build "mock-paypal-service" && return 0
  echo "==> building mock-paypal-service (Java 25, standalone Dockerfile)"
  docker build \
    -f mock-paypal-service/Dockerfile \
    -t "${REGISTRY}/mock-paypal-service:${TAG}" \
    mock-paypal-service
  docker push "${REGISTRY}/mock-paypal-service:${TAG}"
}

if [ -n "${SVC:-}" ]; then
  if [ "$SVC" = "frontend" ]; then
    build_frontend
  elif [ "$SVC" = "mock-paypal-service" ]; then
    build_mock_paypal
  else
    build_service "$SVC"
  fi
else
  for svc in "${SERVICES[@]}"; do
    build_service "$svc"
  done
  build_frontend
  build_mock_paypal
fi
```

- [x] **Step 2: Syntax-check it**

```bash
bash -n k8s/images/build.sh
```
Expected: no output (exit 0).

- [x] **Step 3: Verify the registry is reachable via the port-forward**

The `image_in_registry` function does `curl http://${REGISTRY}/v2/$1/manifests/$2`. With `REGISTRY=localhost:5000`, this queries the addon's registry through the port-forward. Confirm the registry API is reachable (requires the cluster to be up + the port-forward running):

```bash
curl -s "http://localhost:5000/v2/_catalog"
```
Expected: `{"repositories":[]}` (empty catalog — no images pushed yet). If you get a connection error, the port-forward isn't running — run `make k8s-cluster-up` (or `make k8s-registry-forward` to start just the forward).

- [x] **Step 4: Commit**

```bash
git add k8s/images/build.sh
git commit -m "k8s/images: build.sh — localhost:5001 (kind) → localhost:5000 (minikube registry addon)

REGISTRY is now localhost:5000 — same address on host (via kubectl
port-forward managed by cluster.sh) and pod (via the addon's proxy
DaemonSet). No auto-discovery needed: the port-forward makes localhost:5000
reachable from the host. The docker push + image_in_registry probe
mechanism is unchanged. Added a startup check that verifies the registry
is reachable before building."
```

---

## Task 5: Update the 10 service `deployment.yaml` image refs + pullPolicy

**Files:**
- Modify: `k8s/apps/base/{authorization-server,bff-service,frontend,gateway,inventory-service,mock-paypal-service,orchestrator-service,order-service,payment-service,product-service}/deployment.yaml`

Each file has `image: localhost:5001/<svc>:dev` and `imagePullPolicy: Always`. Change the registry port from 5001 to 5000 (the minikube registry addon's internal address). `imagePullPolicy: Always` stays as-is — the spec's Q4-B choice ensures each pod restart pulls the latest `:dev` tag from the local registry.

- [x] **Step 1: Use sed to rewrite all 10 files at once**

```bash
for f in k8s/apps/base/*/deployment.yaml; do
  sed -i '' 's|localhost:5001/|localhost:5000/|g' "$f"
done
```

(Note: `sed -i ''` is macOS syntax. On Linux use `sed -i` without the empty string.)

- [x] **Step 2: Verify no `localhost:5001` references remain in base manifests**

```bash
grep -rn 'localhost:5001' k8s/apps/base/
```
Expected: no output (all replaced).

- [x] **Step 3: Verify the image refs look correct**

```bash
grep -rn 'image:' k8s/apps/base/*/deployment.yaml | grep -v '#'
```
Expected output (10 lines, each `image: localhost:5000/<svc>:dev`):
```
k8s/apps/base/authorization-server/deployment.yaml:20:          image: localhost:5000/authorization-server:dev
k8s/apps/base/bff-service/deployment.yaml:17:          image: localhost:5000/bff-service:dev
k8s/apps/base/frontend/deployment.yaml:21:          image: localhost:5000/frontend:dev
k8s/apps/base/gateway/deployment.yaml:21:          image: localhost:5000/gateway:dev
k8s/apps/base/inventory-service/deployment.yaml:17:          image: localhost:5000/inventory-service:dev
k8s/apps/base/mock-paypal-service/deployment.yaml:17:          image: localhost:5000/mock-paypal-service:dev
k8s/apps/base/orchestrator-service/deployment.yaml:17:          image: localhost:5000/orchestrator-service:dev
k8s/apps/base/order-service/deployment.yaml:17:          image: localhost:5000/order-service:dev
k8s/apps/base/payment-service/deployment.yaml:17:          image: localhost:5000/payment-service:dev
k8s/apps/base/product-service/deployment.yaml:17:          image: localhost:5000/product-service:dev
```

- [x] **Step 4: Verify the pullPolicy**

```bash
grep -rn 'imagePullPolicy' k8s/apps/base/*/deployment.yaml
```
Expected: 10 lines, each `imagePullPolicy: Always` (unchanged — the spec's Q4-B choice).

- [x] **Step 5: Commit**

```bash
git add k8s/apps/base/*/deployment.yaml
git commit -m "k8s/apps: image refs localhost:5001 → localhost:5000 (minikube registry addon)

The registry port changes from 5001 (kind-registry container) to 5000
(minikube registry addon's internal address). imagePullPolicy: Always
stays as-is — the spec's Q4-B choice ensures each pod restart pulls the
latest :dev tag from the local registry. The addon's proxy inside each
node redirects localhost:5000 to the in-cluster registry service."
```

---

## Task 6: Switch ingress-nginx from hostPort+ClusterIP to LoadBalancer

**Files:**
- Modify: `k8s/infra/values/ingress-nginx.yaml`

minikube's docker driver doesn't map arbitrary pod hostPorts to the host (unlike kind's `extraPortMappings`). `minikube tunnel` exposes LoadBalancer services at `127.0.0.1`, so switching ingress-nginx to `type: LoadBalancer` + running the tunnel is the correct minikube pattern for :80/:443.

- [x] **Step 1: Rewrite `ingress-nginx.yaml`**

Replace the entire file with:

```yaml
controller:
  # minikube: the Service is LoadBalancer. `minikube tunnel` (run separately)
  # assigns 127.0.0.1 as the EXTERNAL-IP, so the /etc/hosts entries
  # (microecom.local etc.) resolve to the ingress controller on :80/:443.
  # The tunnel must stay running while you use the cluster.
  #
  # (Was: ClusterIP + hostPort for kind, where extraPortMappings in cluster.yaml
  #  bound :80/:443 to the host. minikube's docker driver doesn't map pod
  #  hostPorts to the host, so LoadBalancer + tunnel is the minikube equivalent.)
  service:
    type: LoadBalancer
  # watchIngressWithoutClass so the nginx controller picks up the per-service
  # ingresses in k8s/apps/base/*/ingress.yaml (which declare no ingressClassName
  # — they rely on the controller watching all ingresses).
  watchIngressWithoutClass: true
```

- [x] **Step 2: Verify the file**

```bash
cat k8s/infra/values/ingress-nginx.yaml
```
Expected: the content above.

- [x] **Step 3: Commit**

```bash
git add k8s/infra/values/ingress-nginx.yaml
git commit -m "k8s/infra: ingress-nginx ClusterIP+hostPort → LoadBalancer (minikube)

minikube's docker driver doesn't map pod hostPorts to the host (kind did via
extraPortMappings). The minikube pattern is LoadBalancer + 'minikube tunnel',
which assigns 127.0.0.1 as the EXTERNAL-IP so /etc/hosts entries resolve.
Removed: hostPort block, nodeSelector (ingress-ready), control-plane toleration
— none apply to minikube (no node labels, single schedulable surface)."
```

---

## Task 7: Delete the kind config files

**Files:**
- Delete: `k8s/kind/cluster.yaml`
- Delete: `k8s/kind/registry.sh`
- Delete: `k8s/kind/preload-images.sh`
- Delete: `k8s/kind/` (directory)

These are superseded by `deploy/scripts/cluster.sh`. Verify nothing references them first.

- [x] **Step 1: Confirm nothing references the kind files anymore**

```bash
grep -rn 'k8s/kind/' Makefile scripts/ k8s/ 2>/dev/null
```
Expected: no output (the Makefile was rewritten in Task 3 to call `deploy/scripts/cluster.sh`). If any references remain, fix them before deleting.

- [x] **Step 2: Delete the files**

```bash
git rm -r k8s/kind/
```

- [x] **Step 3: Commit**

```bash
git commit -m "k8s: remove kind/ (cluster.yaml, registry.sh, preload-images.sh)

Superseded by deploy/scripts/cluster.sh (minikube lifecycle). The kind-specific
containerd hosts.toml registry wiring, extraPortMappings, and node-image
preload are all minikube-addon or minikube-tunnel concerns now."
```

---

## Task 8: End-to-end verification on minikube

This is the critical verification that the migration works. It brings up the full stack on minikube and confirms the storefront + gateway respond.

**Prerequisites:** `make k8s-down` has been run (no existing cluster), Docker is running.

- [x] **Step 1: Start the minikube cluster**

```bash
make k8s-cluster-up
```
Expected: `deploy/scripts/cluster.sh up` runs, minikube starts 4 nodes, enables the registry addon, starts the registry port-forward (localhost:5000 → kube-system/registry:80), and prints "minikube cluster 'microecom' is up" + the kubectl context.

- [x] **Step 2: Verify the cluster is healthy**

```bash
make k8s-cluster-status
```
Expected: minikube status shows the cluster Running, `kubectl get nodes` shows 4 nodes all `Ready`, the registry addon Service is listed, and the registry port-forward shows "running" with "health: OK".

- [x] **Step 3: Deploy infra (Helm charts + stateful manifests)**

```bash
make k8s-infra
```
Expected: `k8s/infra/install.sh` runs. Helm installs ingress-nginx (now LoadBalancer), metrics-server, VictoriaMetrics, grafana, kube-state-metrics, vault. The plain manifests apply mysql, mongodb, redis, kafka, minio, schema-registry, kafka-connect. MySQL replication configures. Ends with "infra install complete".

This step may take 10-15 minutes on a cold start (pulling the Confluent cp-* images).

- [x] **Step 4: Start the minikube tunnel** — *no longer a separate terminal.* `cluster.sh`
      now runs it in the background with a PID file (`deploy/.run/tunnel.pid`), started
      best-effort by `k8s-cluster-up`/`k8s-start` and killed by `k8s-down`/`k8s-stop`.

Binding :80/:443 needs root, and macOS sudo caches **per-tty**, so prime it in the same shell:
```bash
sudo -v && make k8s-tunnel     # make k8s-tunnel-stop to stop it
```
Expected: `minikube tunnel` starts, prompts for sudo password (it binds :80/:443 on 127.0.0.1), then runs in the foreground. Leave this terminal open.

Verify the ingress-nginx LoadBalancer got an EXTERNAL-IP (back in the first terminal):
```bash
kubectl -n infra get svc ingress-nginx-controller
```
Expected: the `EXTERNAL-IP` column shows `127.0.0.1` (or `localhost`). If it shows `<pending>`, the tunnel isn't forwarding yet — wait 30s and re-check.

- [x] **Step 5: Verify /etc/hosts resolves**

```bash
grep microecom /etc/hosts
```
Expected (if not present, add them — needs sudo):
```
127.0.0.1 microecom.local
127.0.0.1 api.microecom.local
127.0.0.1 media.microecom.local
127.0.0.1 grafana.microecom.local
127.0.0.1 vm.microecom.local
```

- [x] **Step 6: Verify ingress-nginx responds through the tunnel** — *verified via
      port-forward to the controller, which returns `404` from nginx for an unknown host. This
      proves the LoadBalancer + ingress path; it does NOT prove the tunnel (see Step 4).*

```bash
curl -s -o /dev/null -w "%{http_code}" http://microecom.local
```
Expected: `404` (nginx responds, no ingress rule for `/` yet because apps aren't deployed — but a 404 from nginx proves the tunnel + LoadBalancer path works). If you get `000` (connection failed), the tunnel isn't working — check Step 4.

- [x] **Step 7: Build + push all service images**

```bash
make k8s-build
```
Expected: builds maven-cores + 8 services + frontend + mock-paypal, pushes each to the registry addon via `docker push localhost:5000/<svc>:dev`. This takes several minutes (Maven build + Docker builds).

Verify images are in the registry:
```bash
curl -s http://localhost:5000/v2/_catalog | python3 -m json.tool
```
Expected: lists `maven-cores`, `authorization-server`, `gateway`, ..., `mock-paypal-service` in the `repositories` array.

- [x] **Step 8: Seed pre-apps data (mongo, vault, minio, kafka-connect)**

```bash
make k8s-seed
```
Expected: applies the 4 bootstrap Jobs (mongo-seed, vault-seed, minio-bootstrap, kafka-connect-register), waits for each to complete. Prints "k8s-seed complete".

- [x] **Step 9: Seed product images**

```bash
make k8s-seed-images
```
Expected: uploads the placeholder/real product images to MinIO. Prints completion.

- [x] **Step 10: Deploy the apps**

```bash
make k8s-apps
```
Expected: creates the `app-secrets` Secret, applies `k8s/apps/overlays/local`, waits for all 11 deployments to roll out. Prints rollout status.

- [x] **Step 11: Seed MySQL + inventory (after apps create schema via ddl-auto)**

```bash
make k8s-seed-mysql
make k8s-seed-inventory
make k8s-seed-perftest
```
Expected: each seeds its data, waits for the Job to complete.

- [x] **Step 12: Verify the full stack is up**

```bash
make k8s-status
```
Expected: 4 nodes Ready, infra pods all Running (mysql, mongodb, kafka, redis, minio, vault, schema-registry, kafka-connect, ingress-nginx, metrics-server, VM, grafana, kube-state-metrics), bootstrap jobs Complete, all 11 app pods Running + Ready.

- [x] **Step 13: Verify the storefront + gateway respond through the tunnel** — *storefront
      200 and product browse 200 with 30 products, both via port-forward + `Host:` header. Note the
      gateway-actuator sub-check in this step is wrong; see the acceptance criteria.*

```bash
# Gateway health (PERMIT_ALL — no auth needed)
curl -i http://api.microecom.local/authorization-server/actuator/health/liveness
```
Expected: HTTP 200, body contains `"status":"UP"`.

```bash
# Storefront loads (the frontend Ingress serves the SPA at /)
curl -s -o /dev/null -w "%{http_code}" http://microecom.local
```
Expected: `200` (the SPA index.html).

```bash
# Product browse (PERMIT_ALL route through the gateway)
curl -s http://api.microecom.local/product-service/v1/products | head -c 200
```
Expected: JSON response with product data (a `BaseResponse` with products array).

- [x] **Step 14: Verify the inner loop — rebuild one service**

```bash
make k8s-rebuild svc=order-service
```
Expected: builds `order-service:dev`, `docker push localhost:5000/order-service:dev`, `kubectl rollout restart deployment/order-service`. The pod restarts and pulls the new image (imagePullPolicy: Always).

Verify the pod is running the reloaded image:
```bash
kubectl -n apps rollout status deployment/order-service --timeout=5m
```
Expected: `deployment "order-service" successfully rolled out`.

- [x] **Step 15: Verify teardown works**

```bash
make k8s-down
```
Expected: `k8s-apps-down` (deletes the apps overlay), then `deploy/scripts/cluster.sh down` (minikube delete). Prints "cluster destroyed".

Stop the tunnel in the other terminal (Ctrl-C).

- [x] **Step 16: Commit any verification fixes**

If any of the above steps revealed a bug (e.g. a missed `localhost:5001` reference, a tunnel issue), fix it and commit. If everything passed with no fixes, skip this step.

```bash
git add -A
git commit -m "fix: minikube migration verification fixes"  # only if changes were needed
```

---

## Task 9: Update `k8s/CLAUDE.md` — mark kind scars as historical

**Files:**
- Modify: `k8s/CLAUDE.md`

The scars about kind's `containerdConfigPatches`, `hosts.toml`, `extraPortMappings`, and `kind-registry` are now historical (kind is gone). Add a note at the top of the Known scars section so future readers don't apply kind-specific fixes.

- [x] **Step 1: Add a migration note at the top of the Known scars section**

In `k8s/CLAUDE.md`, find the line `## Known scars (rough edges & hard-won lessons)`. Immediately after it, insert:

```markdown
> **Migration note (2026-08-01):** The local cluster migrated from **kind →
> minikube**. Scars below that reference `kind`, `kindest/node`,
> `containerdConfigPatches`, `registry.sh`, `hosts.toml`,
> `extraPortMappings`, or the `kind-registry` container are **historical** —
> they document debugging that happened on kind and no longer apply. The
> current cluster lifecycle is `deploy/scripts/cluster.sh` (minikube). Images
> are pushed to the minikube registry addon (`docker push localhost:5000/<svc>:dev`);
> pods pull via `localhost:5000` (the addon's proxy DaemonSet on every node);
> ingress uses LoadBalancer + `minikube tunnel` (not hostPort). Keep the scars
> for the lessons they teach (verify before asserting, don't trust garbled
> output, etc.) but do not re-apply kind-specific config.
```

- [x] **Step 2: Commit**

```bash
git add k8s/CLAUDE.md
git commit -m "k8s/CLAUDE.md: mark kind scars as historical after minikube migration

The kind-specific scars (containerdConfigPatches, hosts.toml,
extraPortMappings, kind-registry) no longer apply. Added a migration note at
the top of the scars section so future readers don't re-apply kind fixes."
```

---

## Task 10: Final commit — update `k8s/README.md` to reflect minikube

**Files:**
- Modify: `k8s/README.md`

The README still says "kind cluster" and references `make k8s-bootstrap` with kind. Update it.

- [x] **Step 1: Update the one-shot + layout sections**

In `k8s/README.md`, find:
```
## One-shot

    make k8s-bootstrap

Brings up the kind cluster, infra (MySQL, Mongo, Redis, Kafka, schema-registry,
```
Replace `kind cluster` → `minikube cluster` and add the tunnel note. Replace with:

```
## One-shot

    make k8s-bootstrap

Brings up the minikube cluster, infra (MySQL, Mongo, Redis, Kafka, schema-registry,
```

Find the end of that paragraph (the line ending with `Idempotent — safe to re-run.`) and after it add:

```

**Then start the minikube tunnel in a separate terminal** (required for
ingress :80/:443 — the tunnel exposes the ingress-nginx LoadBalancer at
127.0.0.1):

    make k8s-tunnel
```

- [x] **Step 2: Update the Layout section**

Find:
```
 ├── kind/                  — cluster.yaml + local registry shim
```
Replace with:
```
 ├── (kind/ removed — now deploy/scripts/cluster.sh drives minikube)
```

- [x] **Step 3: Update the AWS portability note if it mentions kind**

Search for any remaining `kind` references:
```bash
grep -n 'kind' k8s/README.md
```
Replace any that refer to the local cluster (not "kind" as in "a kind of") with `minikube`.

- [x] **Step 4: Commit**

```bash
git add k8s/README.md
git commit -m "k8s/README: update kind → minikube, add tunnel step

The one-shot + layout sections now reflect the minikube cluster + tunnel
pattern. kind/ directory is gone (deploy/scripts/cluster.sh replaces it)."
```

---

## Plan 1 complete — acceptance criteria

All of the following must be true:

- [x] `deploy/` directory tree exists with README + `scripts/cluster.sh` + `scripts/lib/colors.sh`
- [x] `make k8s-cluster-up` starts a 4-node minikube cluster + registry addon + port-forward
- [x] `make k8s-tunnel` exposes ingress at 127.0.0.1 — verified live on 2026-08-01 through the
      real :80 path (no port-forward): storefront 200, `product-service/v1/products` 200 with all
      30 seeded products, `bff-service/v1/products/{id}` 200, `media.microecom.local` image 200,
      grafana 302. Runs in the **background** now, not a separate terminal.
- [x] `make k8s-infra` deploys all infra on minikube (ingress-nginx as LoadBalancer)
- [x] `make k8s-build` builds + pushes all images to the registry addon (`localhost:5000`)
- [x] `make k8s-apps` deploys all 11 services with `image: localhost:5000/<svc>:dev` + `imagePullPolicy: Always`
- [x] Storefront (`http://microecom.local`) returns 200 — *verified via port-forward to
      `svc/ingress-nginx-controller` with `Host: microecom.local`; the ingress rule is proven, the
      tunnel transport in front of it is not (see the unticked tunnel box above).*
- [x] ~~Gateway health (`http://api.microecom.local/authorization-server/actuator/health/liveness`)
      returns 200 UP~~ — **WRONG CRITERION, do not chase a 200 here.** This path returns **403**,
      which is the *designed* behaviour: `CLAUDE.md` states the gateway intentionally does not
      route `/actuator/**`, actuator listens on a **separate management port** (authorization-server
      19091, gateway 19093 — not 9091), and `/actuator` has no entry in `docker/api_role.json`, so
      the gateway denies it. Replaced by the criterion below.
- [x] **Actuator health is reachable on each service's management port, NOT through the gateway** —
      authorization-server `:19091` and gateway `:19093` both return `{"status":"UP"}` for
      liveness and readiness.
- [x] Product browse (`http://api.microecom.local/product-service/v1/products`) returns product
      JSON — 200 with all 30 seeded products incl. MinIO image URLs.
- [x] `make k8s-rebuild svc=order-service` rebuilds + pushes + restarts the pod
- [x] `make k8s-down` tears down cleanly (stops port-forward + tunnel + deletes cluster) —
      exercised 2026-08-01. All 30 app resources deleted, all 4 node containers removed, 0
      minikube profiles remain, both PID files cleared (only the `.log` files survive in
      `deploy/.run/`), `:80` free, no orphaned tunnel or port-forward process.
- [x] `k8s/kind/` directory is deleted
- [x] ~~No `localhost:5001` references remain anywhere in `k8s/` or `deploy/`~~ — **OBSOLETE, do
      not enforce.** Superseded by the implementation deviation at the top of this plan: the host
      pushes via `localhost:5001` (port-forward) and pods pull via `localhost:5000` (registry-proxy
      DaemonSet). Both refer to the same registry. The real criterion is the one below.
- [x] **Pod-side manifests use `localhost:5000`; host-side build tooling uses `localhost:5001`**
- [x] `k8s/CLAUDE.md` + `k8s/README.md` reflect minikube

Verify the corrected registry-split criterion:
```bash
# pod-side: must all be :5000
grep -rn 'localhost:50' k8s/apps/base/ k8s/apps/overlays/
# host-side: must be :5001
grep -n 'REGISTRY' k8s/images/build.sh
```
Expected: base + overlay manifests on `5000`, `build.sh` defaulting to `5001`.

---

## What's next (Plan 2)

Once this plan is verified, Plan 2 (Helm chart) converts `k8s/infra/manifests/*.yaml` + `k8s/infra/install.sh` → the `deploy/charts/microecom/charts/infra/` subchart, then `k8s/apps/base/*/` + `k8s/apps/overlays/` → the `charts/apps/` subchart. The minikube cluster + registry port-forward mechanism from this plan is the stable foundation Plan 2 builds on.
