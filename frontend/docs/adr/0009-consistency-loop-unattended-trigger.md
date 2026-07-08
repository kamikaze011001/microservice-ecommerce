# 0009 — Consistency loop: the unattended trigger (gated)

**Status:** Accepted
**Date:** 2026-07-08

## Context

Phase 1 shipped the deterministic hard gate (`pnpm check:consistency`, in CI) and Phase 2 the
`/consistency-loop` four-role agent pipeline (implementer → hard gate → blind reviewer → approver →
PR), proven with one manual run. Both are on `main`.

The pipeline still has one ignition: a human typing `/consistency-loop` in an open Claude Code
session. `/loop` and `/goal` only work while a session is open; a truly unattended run needs a
different ignition (headless `claude -p` in CI). We want that ignition without duplicating the skill
or the gate — and without committing a solo learning repo to permanent billed nightly runs.

## Decision

Add a standalone workflow `.github/workflows/frontend-consistency-loop.yml` that runs the existing
`/consistency-loop` via `anthropics/claude-code-action@v1`, shipped **complete but with recurring
spend gated**: a live `workflow_dispatch` button + a commented-out nightly `schedule:`.

- **Standalone workflow, not an extension of `frontend.yml`.** The loop writes code and opens PRs and
  needs `contents:/pull-requests: write` + (when hot) an API-key secret; `frontend.yml`'s jobs are
  read-only and run on every PR. Different responsibilities, different file.
- **Gated activation.** `frontend.yml` already blocks objective drift on every PR, so an unattended
  trigger only adds value for subjective drift — not enough to justify permanent billed runs. Going
  hot is one secret + one uncomment, documented in `frontend/docs/consistency-loop-automation.md`.
- **Default `GITHUB_TOKEN`, no PAT.** Sufficient to open a PR. Its recursion prevention means bot PRs
  skip `frontend.yml` CI (re-run manually) — an accepted tradeoff to avoid PAT complexity.
- **No auto-merge is structural.** GitHub has no merge-only scope; the workflow simply never calls
  `gh pr merge`, backed by branch protection on `main`. Every run ends at a human-merged PR.
- **Recursion-safe.** Triggers only on `workflow_dispatch`/`schedule`, never `push`/`pull_request`.

## Alternatives considered

| Option                                          | Why not                                                                                                                                         |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Both triggers hot now (parent-design default)   | Permanent billed runs + a merge-capable secret on a solo repo, for drift `frontend.yml` mostly already catches; needs nightly dedup work first. |
| Extend `frontend.yml` with a loop job           | Mixes a PR-opening, secret-bearing, write-scoped job into read-only PR jobs that must never run the loop — a footgun.                           |
| Local Claude Code cron (`CronCreate`)           | Only fires while your machine is up; it just schedules a session, which is not the unattended-cloud path Phase 3 exists to build.               |
| PAT / GitHub App token so bot PRs re-trigger CI | Reintroduces recursion risk and a broader secret; not worth it — humans re-run CI on the reviewed PR.                                           |

## Consequences

- **Positive:** the unattended ignition exists and is demonstrable via one button press with zero
  recurring spend; going hot is a documented one-secret/one-uncomment flip; no change to the skill,
  rubric, gate, or `frontend.yml`.
- **Negative / accepted:** the nightly cadence is never exercised until someone opts in; bot PRs skip
  `frontend.yml` CI; whether the `Task` subagent tool works headlessly is unverified until the first
  `workflow_dispatch` run (risk R1 in the design), and no degraded inline-reviewer fallback is
  pre-built.
