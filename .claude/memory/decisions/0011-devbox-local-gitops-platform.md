---
name: 0011-devbox-local-gitops-platform
description: Devbox = local IDP — Gitea env repo + Argo CD per-service Applications; assemble OSS, phased 1–6, learning-first
metadata: { type: decision, date: 2026-10-09 }
---
The devbox is a local internal developer platform. Each dev gets a personal
`prod-like` env on their own laptop, and every deploy or rollback is a git
commit. It was settled in a grilling session (Q1–Q26):

- **Customer and goal:** a hypothetical team of 3–10 devs, one laptop each. Learning comes first, but each piece must earn daily use. Claude implements, the user reviews, and there is one HTML teaching page per phase under `docs/platform/`.
- **Assemble, don't build:**
  - Argo CD for topology, sync, history and rollback.
  - Gitea, the Joxit registry UI and Grafana.
  - A small Spring Boot `devbox-portal` (phase 5).
  - Backstage only later.
- **Truth:** the `devbox/env-config` repo in in-cluster Gitea holds versions and config (the WHAT). The chart (the HOW) comes from `devbox/microecom@devbox`, which is the current branch force-pushed by `make devbox-push`. GitHub is never written by deploys.
- **Shape:**
  - An ApplicationSet with a git files generator over `envs/*/services/*.yaml` creates one Application per (env, service).
  - The chart gets `onlyService` plus a per-service `image.tag`.
  - Auto-sync + selfHeal + prune everywhere.
  - Apps only: infra stays on `make`.
- **Versions (phase 2):**
  - Each service gets its own tag from its git commit; builds with uncommitted changes get `<sha>-dirty-<MMDD-HHMM>`.
  - `devbox-ship` = build → push → commit → sync; `devbox-deploy svc= tag=` pins an older one.
  - Registry cleanup never deletes a tag an env still references.
- **Envs:** phase 1 runs one env at a time in `apps`. Phase 3 adds per-env isolation (database names, topic prefixes, connectors, Vault paths), because two envs on shared Kafka topics would steal events (same group) or double-process them (different groups).
- **Config:** non-secret config goes in the env repo (history + rollback). Secrets stay in Vault and never go in git.
- **Phases:**
  1. GitOps core
  2. Versions
  3. Env config + isolation
  4. Perf (k6 → VictoriaMetrics, tagged with versions)
  5. Portal
  6. API tests (Bruno)

**Why:** the wishlist (visualization, rollback, history, image versions) is mostly what GitOps plus existing OSS already provide. A custom UI would rebuild Argo CD badly. A local Gitea keeps experiment commits off GitHub. Per-service Applications are what make "roll back one service" possible.

**How to apply:**
- `make devbox-up` is opt-in. `k8s-bootstrap-helm` stays the default, and the two must not own the same apps (`devbox.sh apps` refuses).
- Any chart change must keep `render-test.sh`'s devbox section green: the 10 per-service renders must equal the umbrella render.
- Related: [[0003-deploy-refactor-helm-umbrella-three-envs]], [[0009-kafka-consumer-scaling-design]].
