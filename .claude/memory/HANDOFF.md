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
**Plan 1 is functionally complete and committed. One step remains, and it needs the user.**

1. **NEEDS THE USER:** `make k8s-tunnel` in a separate terminal — binds :80/:443, prompts for
   sudo, must stay alive. `ingress-nginx-controller` sits at `EXTERNAL-IP <pending>` until it
   runs (confirmed this session). This is the *only* unverified path.
2. Once the tunnel is up, verify the 4 remaining Plan 1 checkboxes (lines ~1080/1094/1108/1165
   and the acceptance criteria): `/etc/hosts` resolves, ingress returns 404 from nginx,
   `http://microecom.local` returns 200, `http://api.microecom.local/...` serves gateway health
   + product JSON.
3. Also still unticked: `make k8s-down` tears down cleanly (not exercised — the cluster was
   deliberately left running for the tunnel check).
4. Then Plan 2 (Helm chart).

## Verified this session (full E2E, cluster still running)
- Infra all Running; `schema-registry` + `kafka-exporter` healthy = functional proof of the two
  `install.sh` fixes (both crash without them).
- 11 images pushed, confirmed by reading the registry catalog rather than trusting exit 0.
- All 4 seed jobs + mysql/inventory/images/perftest seeds completed (`uploaded=30 missing=0`).
- All 10 app pods 1/1, 0 restarts — the node over-subscription did **not** bite.
- **Via port-forward (bypassing the tunnel):** product browse returns 200 with all 30 seeded
  products incl. MinIO image URLs; frontend returns 200; gateway liveness + readiness both UP on
  the management port (19093 — **not** 9091, and the gateway deliberately does not route
  `/actuator/**`, so a 404 on :6868 is correct, not a failure).
- Inner loop: `make k8s-rebuild svc=order-service` rebuilt, pushed and rolled a new pod cleanly.

## Settled decisions
- **All work is committed** — 12 commits on `feat/aws-live-deploy` (`e041fe2..aa7bcce`), working
  tree clean. This reverses the previous handoff's warning.
- `deploy/` empty dirs carry `.gitkeep`; the plan verified the tree with `find -type d`, which
  does not catch that git cannot track empty directories.
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
