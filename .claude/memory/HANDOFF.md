# HANDOFF — microservice-ecommerce — 2026-08-07 (evening)

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first, so write it for a 10-second catch-up.

## Current goal
Deploy refactor, phases from `docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`.
**Phases 3 and 4 are merged. This session stood up minikube and paid down the live-verification
debt that had accumulated across Phases 1, 3 and 4.** Next unstarted work is Phase 5.

Branch: **`fix/k8s-infra-connect-timeout`** — 3 commits off main, NOT pushed, no PR yet.
Also on **main**, unpushed: `fc5df39` (memory commit; squash-merge of PR #54 dropped it).

## The cluster is UP and healthy
minikube profile `microecom`, 4 nodes, kubectl context `microecom` (this also cleared the
ambient-context hazard — it used to point at an unrelated Azure AKS cluster).
10/10 app pods 1/1, zero restarts, all 6 bootstrap jobs Completed, catalog serves 30 products.
Apps are on the **kustomize** path (`make k8s-apps`), not Helm — see below.
Compose infra was stopped (`make infra-down`, volumes kept) to free ~5GB for the cluster.

## Done this session
- **Phase 4 k8s leg CLOSED** — the deferred half of PR #54. `make secrets-seed ENV=k8s
  KUBE_CONTEXT=microecom` against the live in-cluster Vault, then old-job write (v1) vs new-seeder
  write (v2) compared on the same backend: **all 11 paths identical, 102 keys, zero differences**
  (cleaner than compose, which dropped 4 `_comment` keys). Then **all 10 services restarted and
  booted** against the canonical secrets — the functional proof, since a missing key is what
  caused the 3 documented crashloops. The comparison was itself validated with a planted decoy
  (detected, named, then removed — asserted 0 occurrences across all current paths).
- **Two real defects found and fixed**, both only findable live:
  - `835c558` — kafka-connect rollout wait 10m → 15m. See
    [[cold-cluster-image-pulls-outgrow-rollout-timeouts]].
  - `5b57c4b` + `3f871bb` — namespace ownership stamps, and the second blocker documented. See
    [[helm-and-kubectl-deploy-paths-are-exclusive]].

## In progress — Next
1. **NEEDS THE USER, still outstanding:** `sudo -v && make k8s-tunnel` (one command, one terminal —
   macOS `tty_tickets` scopes the credential). Nothing is listening on :80 yet. This blocks the
   **4 Phase-1 ingress checkboxes**: `/etc/hosts` resolves (all 5 entries already present),
   ingress 404s from nginx, `http://microecom.local` 200, `http://api.microecom.local/...` serves
   gateway health + product JSON.
2. **Finish the branch** — 3 commits, no PR yet.
3. `make k8s-down` still unticked from Phase 1 (cluster deliberately left running).
4. Then **Phase 5** (seed consolidation). Note its acceptance criterion needs this cluster:
   `make seed ENV=k8s` must produce the same DB state as `k8s-seed` + `-mysql` + `-inventory`.

## Settled decisions
- **Phase 3 Helm path: accepted as documented, NOT verified live** (user's call). Verifying it
  needs a full rebuild the Helm way (`k8s-cluster-up → k8s-infra-helm → k8s-apps-helm`, ~35-40min)
  because the two bring-up paths are mutually exclusive. Phase 6 owns making them coherent.
- A brief self-inflicted outage happened proving that: `k8s-apps-down` + `k8s-apps-helm` aborted,
  apps were down ~4 min, `make k8s-apps` restored them fully.

## Context to Load
- `.claude/memory/conventions/helm-and-kubectl-deploy-paths-are-exclusive.md`
- `.claude/memory/conventions/cold-cluster-image-pulls-outgrow-rollout-timeouts.md`
- `.claude/memory/decisions/0004-canonical-secrets-resolve-transport-split.md`
- `docs/superpowers/specs/2026-08-01-deploy-refactor-design.md` (Phase 5 at line 941)
- `Makefile` (k8s targets from line ~207; `k8s-app-secrets` comment block ~396-450)

## Blocked / watch-items
- The 15m kafka-connect fix was proven *necessary* by measurement, but the re-run had the image
  cached — the value itself was never re-tested cold. A true cold test needs `make k8s-nuke`.
- `rtk` truncated output **twice** this session, including through a shell redirect, and once made
  a successful run look failed. Use `rtk proxy` for anything counted, parsed, or redirected.
- A background-task notification reported **exit 0 for a run that exited 2**. Capture `$?` inside
  the command; don't trust the harness summary.
- The `community-*` docker stack (~1.9GB, unrelated project) is still running alongside the cluster.
