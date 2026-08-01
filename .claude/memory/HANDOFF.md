# HANDOFF — microservice-ecommerce — 2026-08-01

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first, so write it for a 10-second catch-up.

## Current goal
Finish **Plan 1 (Foundation)** of the deploy refactor: `deploy/` scaffold + kind → minikube
migration, Kustomize manifests left untouched. Then commit it.

Branch: **`feat/aws-live-deploy`** — the user explicitly chose to keep this work here rather
than split off `refactor/deploy-foundation` as the plan suggested, since the changeset also
edits `k8s/apps/overlays/aws/*` and `scripts/aws/gen-aws-overlay.sh`.

> **Correcting the previous handoff:** it claimed "Plan 1 is not started, no `deploy/` directory
> exists, working tree clean." That was **false** — Plan 1 was ~90% implemented but entirely
> uncommitted, so `git log` made it look untouched. Check `git status`, not just the log.

## Done
- **Plan 1 Tasks 1–7, 9, 10 are all implemented** in the working tree: `deploy/` scaffold,
  `cluster.sh`, Makefile rewrite, `build.sh`, 10 deployment image refs, ingress LoadBalancer,
  `k8s/kind/` deleted, `k8s/CLAUDE.md` + `k8s/README.md` updated.
- An earlier E2E run got deep into Task 8 and produced **four fixes not in the plan's file map**,
  all preserved in the tree: kafka-exporter ordering + compacted internal topics
  (`k8s/infra/install.sh`), chown initContainers (`kafka.yaml`, `mongodb.yaml`), and the AWS
  overlay image-name mappings following base 5001 → 5000.
- `cluster.sh` also grew two things the plan never specified: a 20Gi PVC bolted onto the registry
  Deployment, and `apply_node_limits()` via `docker update`.
- **Task 8 steps 1–2 re-verified this session:** 4 nodes Ready, registry Deployment + PVC,
  `registry-proxy` on all 4 nodes, host forward serving `{"repositories":[]}`.
- Static checks pass: `bash -n` on both scripts, `make -n` resolves the new targets, and **both**
  `kubectl kustomize k8s/apps/overlays/{local,aws}` build clean.

## In progress — Next
1. **WAS RUNNING when the session ended:** `make k8s-infra` (Task 8 step 3). Re-check or re-run.
2. **NEEDS THE USER:** `make k8s-tunnel` in a separate terminal — binds :80/:443, prompts for
   sudo, must stay alive. ingress-nginx sits `<pending>` until it runs.
3. Then: `k8s-build` → `k8s-seed` → `k8s-seed-images` → `k8s-apps` → `k8s-seed-{mysql,inventory,perftest}`.
4. **The actual unverified gate (Task 8 steps 12–14):** storefront 200, gateway liveness UP,
   product browse JSON, and `make k8s-rebuild svc=order-service`.
5. Tick the plan checkboxes, then commit the ~40 files in the plan's per-task commit structure.

## Settled decisions
- **Everything is still uncommitted** — zero commits since `e041fe2`. Committing IS the remaining
  task; do not treat the working tree as scratch.
- The **5001-host / 5000-pod registry split is correct**, not a bug. Plan 1's acceptance criterion
  "no `localhost:5001` references remain anywhere" is **obsolete** — do not enforce it.
- Re-running the full E2E before committing was the user's explicit choice this session.

## Context to Load
- `docs/superpowers/plans/2026-08-01-deploy-foundation.md`
- `docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`
- `.claude/memory/conventions/minikube-registry-host-5001-pod-5000.md`
- `.claude/memory/conventions/minikube-hostpath-ignores-fsgroup.md`
- `.claude/memory/conventions/minikube-node-resources-only-apply-at-creation.md`
- `deploy/scripts/cluster.sh`

## Blocked
- Nothing hard-blocked. Two watch-items: node resources are **over-subscribed** (24 CPU/24GB
  requested vs 12/16 available) so OOMKills during app rollout are plausible; and `kubectl`
  v1.36.3 against k8s v1.30.0 emits a version-skew warning (cosmetic so far).
- Still-open questions from the design: minikube tunnel watchdog, gating upstream Helm deps,
  terraform-output resolution for `contexts/aws.yaml`, mongodb-keyfile rotation, where k6 Jobs live.
- Plans 2–7 (Helm chart, canonical secrets/seed, unified scripts, AWS cutover, cleanup) unwritten.
