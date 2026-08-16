# HANDOFF

**Updated:** 2026-08-16 · **Branch:** `main` (clean) · **Last:** PR #59 merged (`ebfd134`)

## Current goal

**The deploy refactor is COMPLETE.** All eight phases merged. There is no in-flight
workstream — the next task starts fresh from `main`.

## Done (Phase 8, the final one)

- 142 files deleted, 36 relocated with history preserved. `k8s/`, `docker/vault-configs/`,
  `scripts/seed/`, `scripts/aws/seed-*.sh`, `docker/ecommerce.sql` + 3 seed JSON are gone.
- One path per concern: `deploy/secrets/`, `deploy/seed/`, the Helm umbrella chart, and
  `make <verb> ENV=<env>` as the single command dialect.
- The k8s Helm cut-over is **proven live** by a from-scratch `make bootstrap ENV=k8s`
  (exit 0, 10/10 pods, 30 products). Six real bugs were found and fixed getting there.
- Verified on `main` after the squash-merge: all seven suites green, both live paths serving.

## In progress — nothing

## Next, if picking something up

Ranked by how much they'll bite:

1. **`ENV=aws` has never been deployed** — five consecutive phases shipped an unexercised
   transport. Everything AWS rests on offline equivalence, and Phase 8 showed precisely what
   that cannot catch. Folding AWS infra into the chart is blocked on a release-name decision
   — see [[0005-aws-infra-stays-outside-the-umbrella-chart]].
2. The `kind`→minikube doc drift in the HTML teaching pages under `docs/`.

Closed on `fix/phase8-followups` (2026-08-16): `make down` now stops MinIO too (F2,
`scripts/infra/down.sh` adds `minio.yml`); `scripts/aws/up-all.sh` now confirms before a
billed EKS apply (F3); the two HTML teaching pages describing the deleted kustomize `k8s/`
tree were rewritten (F4); `make up`/`make bootstrap` now heal stale Eureka registrations
after a host IP change (F5, `scripts/lib/eureka.sh` + `scripts/services/start.sh`).

## Settled decisions

- [[0003-deploy-refactor-helm-umbrella-three-envs]] — the refactor's shape.
- [[0004-canonical-secrets-resolve-transport-split]] — pure resolver + separate seeder.
- [[0005-aws-infra-stays-outside-the-umbrella-chart]] — and why repointing it is a trap.
- Four oracles are **frozen**: their sources are deleted, so a failure means the chart or
  renderer changed, never that the fixture is stale. Never regenerate them.

## Context to load

- `deploy/README.md` — usage, Verification status, losses, known gaps
- `deploy/CLAUDE.md` — the 19 migrated SCARs (paths may be gone; the traps are current)
- `docs/superpowers/specs/2026-08-14-cleanup-cutover-design.md` and its plan
- `.claude/memory/sessions/2026-08-16.md` — what Phase 8 actually cost and why

## Blocked

Nothing. Two operations are **human-gated** in this environment and always will be:
`git rm`/`rm` and writes to `deploy/.env*`. Ask; do not work around them.
