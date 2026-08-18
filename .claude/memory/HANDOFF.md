# HANDOFF

**Updated:** 2026-08-17 · **Branch:** `main` (clean) · **Last:** PR #61 merged (`a9014a4`)

## Current goal

No in-flight workstream. The deploy refactor and both rounds of its follow-ups are merged;
the next task starts fresh from `main`.

## Done recently

- **PR #59** — the deploy refactor's final phase: 142 files deleted, one path per concern,
  `make <verb> ENV=<env>` as the single command dialect.
- **PR #60** — four gaps Phase 8 had recorded and deferred: `make down` stops MinIO (so a real
  cold start is possible), `make up` heals stale Eureka registrations, `up-all.sh` confirms
  before a billed apply, two teaching pages rewritten.
- **PR #61** — hardened the freshness check PR #60 introduced: one function instead of a
  test-only copy plus an inline duplicate, and membership instead of equality
  ([[0006-staleness-is-membership-not-equality]]).

## In progress — nothing

## Next, if picking something up

1. **`ENV=aws` has never been deployed** — six consecutive phases shipped an unexercised
   transport. Everything AWS rests on offline equivalence, and Phase 8 showed exactly what
   that cannot catch (three release-breaking bugs invisible to `helm template`). Folding AWS
   infra into the chart is blocked on a release-name decision — see
   [[0005-aws-infra-stays-outside-the-umbrella-chart]]. Needs real spend and can only be
   verified by running it.
2. **`kind`→minikube drift** in `docs/k8s-architecture.html` and `docs/k8s-eli5.html` (~22
   mentions). Pure docs. Task 5 of PR #60 rewrote the very card saying "kind builds a whole
   toy city" and left the term.
3. Two non-blocking nits recorded in PR #61: `eureka-test.sh` case 7's comment uses
   pre-rename wording; a whitespace-only `HOST_IP_OVERRIDE` returns 0 while printing nothing,
   contradicting its own contract but unreachable in production.

## Settled decisions

- [[0003-deploy-refactor-helm-umbrella-three-envs]] — the refactor's shape.
- [[0004-canonical-secrets-resolve-transport-split]] — pure resolver + separate seeder.
- [[0005-aws-infra-stays-outside-the-umbrella-chart]] — and why repointing it is a trap.
- [[0006-staleness-is-membership-not-equality]] — and why tightening it back is a trap.
- Four oracles are **frozen**: their sources are deleted, so a failure means the chart or
  renderer changed, never that the fixture is stale. Never regenerate them.

## Context to load

- `deploy/README.md` — usage, Verification status, known gaps (now empty; see
  [[a-gaps-registry-decays-through-success]] for why that section needs an owner)
- `deploy/CLAUDE.md` — the 19 migrated SCARs (paths may be gone; the traps are current)
- `.claude/memory/sessions/2026-08-17.md` — what the two follow-up PRs cost and why

## Blocked

Nothing. Two operations are **human-gated** in this environment and always will be:
`git rm`/`rm` and writes to `deploy/.env*`. Ask; do not work around them.
