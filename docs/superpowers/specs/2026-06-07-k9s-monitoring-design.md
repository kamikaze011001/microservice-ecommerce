# k9s Monitoring Setup — Design Spec

**Date:** 2026-06-07
**Status:** Approved (design)
**Goal:** One command (`make k9s`) opens a k9s terminal UI pre-pointed at a chosen cluster environment, using a config committed to the repo so the setup is shared and reproducible — and switching between the local kind cluster and a future EKS cluster is a single flag.

## Background

The project runs on a local `kind` cluster (context `kind-microecom`, namespaces `apps` / `infra` / `bootstrap`). There is no committed monitoring tooling. k9s is a terminal UI for navigating and managing a Kubernetes cluster (pods, logs, deployments, exec, restart, scale). It is not currently installed and there is no `~/.config/k9s`.

A future EKS deployment is anticipated, so the setup must make switching environments trivial without duplicating config.

## Key decisions

- **Tailored + committed config** (not local-only): the k9s config lives in the repo so it's shared and version-controlled.
- **Full control** (not read-only): the TUI can delete / scale / edit / restart — this matches the active cluster management already in use. The operator accepts that k9s acts live against the cluster.
- **Environment switching = context switching.** Environment differences live in the kube *context*, not in the k9s config. One shared config is pointed at different contexts. (Approach A below.)

## Architecture

k9s separates **how you view** (config: skin, hotkeys, UI prefs — env-agnostic) from **what you view** (the kube context — env-specific). It also keeps per-cluster state automatically under `K9S_CONFIG_DIR/clusters/<context>/<cluster>/`, so each environment remembers its own last namespace/view with no extra work, and `:ctx` switches contexts live inside the TUI.

Therefore: a **single committed config** serves every environment, and the only env-specific input is the context name.

### Components

1. **Install (one-time, explicit).** `brew install k9s` (macOS). The `make k9s` target detects a missing binary and prints the install command rather than auto-installing software.

2. **Committed config dir `k8s/k9s/`:**
   - `config.yaml` — global UI prefs: live auto-refresh on, sensible refresh rate, skin = `microecom`, disable the update-check nag. Env-agnostic.
   - `skins/microecom.yaml` — a readable dark skin (legibility; cosmetic).
   - `hotkeys.yaml` — one-key namespace jumps tuned to this project's layout: e.g. `shift-a` → pods in `apps`, `shift-i` → `infra`, `shift-b` → `bootstrap`. These work on **any** cluster that uses the same namespace names — a reason to keep `apps`/`infra`/`bootstrap` on EKS too.
   - `.gitignore` — exclude k9s-generated state (`clusters/`, `*.log`, screenshots) so only the curated files are tracked.

3. **`make k9s` launcher (Approach A — `ENV` flag):**
   ```
   make k9s            # ENV defaults to local → context kind-microecom
   make k9s ENV=eks    # → context microecom-eks
   ```
   Implementation shape:
   ```
   ENV ?= local
   # map env → context
   local: CTX = kind-microecom
   eks:   CTX = microecom-eks
   k9s: K9S_CONFIG_DIR=$(PWD)/k8s/k9s k9s --context $(CTX) -n apps
   ```
   Guards: error clearly if k9s is not installed (hint: `brew install k9s`) or the target context is unreachable (hint: `make k8s-start` for local; `aws eks update-kubeconfig` for eks). Live context switching with `:ctx` still works regardless.

4. **Docs.** A short "Monitoring with k9s" section in `k8s/README.md`: install, `make k9s [ENV=…]`, the namespace hotkeys, and the one-time EKS step `aws eks update-kubeconfig --name <cluster> --alias microecom-eks`.

## Data flow

`make k9s ENV=<env>` → resolves `<env>` to a context name → launches `k9s` with `K9S_CONFIG_DIR=k8s/k9s` and `--context <ctx> -n apps` → k9s reads the committed skin/hotkeys/prefs and connects to that cluster via the existing kubeconfig credentials (cert for kind, `aws eks get-token` for EKS).

## Error handling

- k9s binary missing → target prints `brew install k9s` and exits non-zero.
- Context not found / cluster unreachable → k9s surfaces the connection error; the target prints an env-appropriate hint.
- Unknown `ENV` value → target fails fast listing valid values (`local`, `eks`).

## Testing / verification

- `make -n k9s` parses and expands the right context per `ENV`.
- `make k9s` (local, cluster up) opens the TUI on `apps`, skin + namespace hotkeys active.
- `bash -n` / file-syntax check on any shell in the target.
- Manual: `:ctx` lists contexts; per-cluster state is written under `k8s/k9s/clusters/` and is git-ignored.

## Known caveats

- **k9s config schema varies by version.** The config directory env var (`K9S_CONFIG_DIR` on current k9s vs older `K9SCONFIG`/`XDG_CONFIG_HOME`) and the `config.yaml` / `hotkeys.yaml` schema shifted around v0.30+. Brew installs current k9s; target the modern layout and **verify the exact env var + schema against the installed version during implementation** rather than assume.
- **Full control is live.** The TUI can mutate the cluster; intentional per the decision above.

## Out of scope (YAGNI)

- Custom k9s plugins / action hotkeys (rollout-restart, port-forward, stern log tail).
- Read-only mode.
- Prometheus / Grafana / a metrics stack — k9s here is the lightweight interactive monitor.
- Per-env config directories — a single shared config + context switching covers it; revisit only if EKS needs a genuinely different skin/hotkeys.
