# App ↔ Storybook consistency loop — Phase 3: the unattended trigger

**Date:** 2026-07-08
**Branch:** `feat/storybook-consistency-loop-phase3`
**Status:** Approved design — ready for implementation planning
**Parent design:** [`2026-07-07-storybook-consistency-loop-design.md`](2026-07-07-storybook-consistency-loop-design.md) (Phase 3 = "the triggers")

## Problem

Phase 1 shipped the deterministic hard gate (`pnpm check:consistency`, wired into CI). Phase 2
shipped the `/consistency-loop` four-role agent pipeline (implementer → hard gate → blind reviewer →
approver → PR), proven with one **manual** run. Both are merged to `main`.

The pipeline still has exactly one ignition: a human typing `/consistency-loop` in an open Claude
Code session. The parent design's "honest boundary" (its lines 174–184) names the gap — `/loop` and
`/goal` only work while a session is open; a truly **unattended** run needs a different ignition
(headless `claude -p` in CI). Phase 3 builds that ignition **without duplicating the skill or the
gate** — same `/consistency-loop`, new trigger.

## What Phase 3 delivers (and what it deliberately does not)

Phase 3 is **pure ignition + documentation**. It adds a GitHub Actions workflow that runs the
existing Phase-2 skill headlessly, plus the docs to operate it. It changes **nothing** about the
skill, the rubric, the hard gate, or the existing `frontend.yml`.

### Activation decision: build complete, gate the spend

The parent design specced two hot triggers (on-push-to-main + nightly cron). We ship the **complete,
real mechanism** but **gate the recurring spend**, because:

- The existing `frontend.yml` already runs `check:consistency` on **every PR**, so *objective* drift
  cannot reach `main`. An unattended trigger only ever catches *subjective* drift (the blind-reviewer
  layer) — narrower value that does not justify permanent billed runs on a solo repo.
- A billed `ANTHROPIC_API_KEY` and a nightly LLM sweep are an ongoing cost + secret-management
  commitment. Gating makes going hot **one commit + one secret away**, fully documented, reversible.
- It matches the project's own ethos: *"boring and robust over shiny," "autonomy can be earned
  later,"* human-on-the-loop, never auto-merge.

Concretely: the workflow ships with a live **`workflow_dispatch`** trigger (the "Run workflow"
button) and a **commented-out `schedule:` cron**. The manual button is fully functional and is the
demonstrable acceptance path; the nightly cadence is one uncomment away.

## Architecture

### One standalone workflow — not an extension of `frontend.yml`

`frontend.yml`'s jobs (`verify`, `storybook`) are read-only and run on every PR and push-to-main.
The consistency loop **writes code and opens PRs**, needs `contents: write` + `pull-requests: write`
and (when hot) an API-key secret, and must **never** run on `pull_request`/`push` (it operates on its
own branches). Mixing those responsibilities into one file is a footgun. Phase 3 therefore adds a
separate file: **`.github/workflows/frontend-consistency-loop.yml`**.

### Triggers

```yaml
on:
  workflow_dispatch:
    inputs:
      scope:
        description: "Scope passed to /consistency-loop"
        required: false
        default: "scan frontend/src for drift"
  # schedule:                     # ← flip on per docs/consistency-loop-automation.md
  #   - cron: "0 7 * * *"         #   07:00 UTC nightly; requires the ANTHROPIC_API_KEY secret
```

- `workflow_dispatch` with an optional `scope` input (defaults to the skill's own default scope).
  This is the live, demonstrable path.
- `schedule:` present but commented, annotated with a pointer to the runbook.

### The ignition step

Uses the official **`anthropics/claude-code-action@v1`**. On non-mention events it auto-detects
"automation mode" and runs the **`prompt:`** input:

```yaml
permissions:
  contents: write
  pull-requests: write
steps:
  - uses: actions/checkout@v4
  - uses: anthropics/claude-code-action@v1
    with:
      anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}   # unset in the gated build
      prompt: "/consistency-loop ${{ inputs.scope || 'scan frontend/src for drift' }}"
      claude_args: '--allowedTools "Edit,Bash,Task,Read,Glob,Grep"'
```

- **`Task`** is the tool that dispatches the implementer and the fresh blind-reviewer subagents — the
  Phase-2 blindness guarantee depends on it (see Risk R1).
- Auth is `anthropic_api_key` (or `claude_code_oauth_token`). **Neither is set in the gated build**;
  a run without the secret fails fast with a clear "no auth" error, which is the expected gated state.

### Recursion guard (two independent brakes)

The loop opens `consistency/*` branches and PRs; it must never chase its own tail.

1. **Event scoping:** the workflow runs only on `workflow_dispatch`/`schedule`, never on
   `push`/`pull_request`. A bot PR cannot self-trigger it.
2. **Platform recursion prevention:** PRs/pushes made with the default `GITHUB_TOKEN` do **not**
   trigger further `push`/`pull_request` workflow runs (GitHub built-in). Belt-and-braces.

**Accepted tradeoff:** brake 2 also means the bot's corrective PR does **not** auto-trigger
`frontend.yml`'s `verify`/`storybook` jobs. Acceptable — it is a human-reviewed PR; the reviewer
re-runs CI with one click. This keeps Phase 3 off PAT/GitHub-App-token complexity.

### The no-auto-merge guarantee is structural, not a token scope

GitHub has **no merge-only permission** — merging uses the same `contents: write` needed to open a
PR — so "open but cannot merge" is **not** achievable by scoping the token. The guarantee is instead
enforced two ways, both already true in this design:

1. The workflow **never invokes `gh pr merge`** (the skill's `Go` path stops at `gh pr create`).
2. Branch protection on `main` (required review) is the platform backstop.

Every unattended run ends at a PR a human merges — identical to the manual Phase-2 contract.

## Components / artifacts

| Artifact | Responsibility |
|---|---|
| `.github/workflows/frontend-consistency-loop.yml` | The unattended ignition: `workflow_dispatch` (live) + commented `schedule:`, `claude-code-action@v1` running `/consistency-loop`, recursion guard, PR-scoped permissions. |
| `frontend/docs/consistency-loop-automation.md` | Runbook: how to take it hot (add `ANTHROPIC_API_KEY` secret → uncomment `schedule:`), the no-auto-merge/branch-protection note, the recursion tradeoff, and the R1 subagent caveat. |
| `frontend/docs/adr/0009-consistency-loop-unattended-trigger.md` | ADR recording the "build-complete / gate-hot" decision and its alternatives. |
| `frontend/CLAUDE.md` | One-line pointer under "Design system" to the automation workflow + runbook. |

**Unchanged:** the `/consistency-loop` skill, `rubric.md`, `check-consistency.sh`, `frontend.yml`,
the design system, and all app code.

## Risks

**R1 — Headless subagents (`Task`) are undocumented in the action (load-bearing).** The skill
dispatches *separate* subagents for the implementer and the **fresh blind reviewer** (never a fork).
Whether `Task` functions inside the headless action is not documented either way. This is precisely
why the gated/demonstrable build is correct: **the first `workflow_dispatch` run is the smoke test.**
- If `Task` works → the pipeline runs faithfully, blindness intact.
- If it does not → we have found it on a manual button with zero recurring spend. The recorded
  Phase-3 finding is "the unattended path needs a degraded inline-reviewer mode (documented
  limitation; human PR review is the compensating control)" — **not** a silent nightly cron
  rubber-stamping its own work.

We do **not** pre-build the degraded fallback (YAGNI until the smoke test demands it).

**R2 — Bot PR skips `frontend.yml` CI.** Covered above under the recursion guard; accepted.

## Acceptance criteria

1. `.github/workflows/frontend-consistency-loop.yml` exists, is valid YAML, and passes `actionlint`
   (or an equivalent workflow lint) with: `workflow_dispatch` live, `schedule:` present-but-commented,
   `permissions` limited to `contents: write` + `pull-requests: write`, and no `pull_request`/`push`
   trigger.
2. The workflow does **not** reference `gh pr merge` anywhere.
3. `frontend/docs/consistency-loop-automation.md`, ADR `0009`, and the `frontend/CLAUDE.md` pointer
   all exist and cross-link correctly.
4. `frontend.yml`, `check-consistency.sh`, the skill, and the rubric are **byte-for-byte unchanged**
   (verified by `git diff` scope).
5. **Demonstrable path (documented, not a hard CI gate):** with an `ANTHROPIC_API_KEY` secret set,
   one `workflow_dispatch` run against seeded subjective drift either (a) opens a `consistency/*` PR
   with the blind-reviewer findings intact and never merges it, or (b) surfaces the R1 subagent
   limitation explicitly in the run log. Either outcome is a pass for Phase 3; only a *silent* or
   *self-merging* run is a failure.

## Out of scope (future/optional, per the parent design)

- Turning the nightly cron **hot** (a runbook step, not a code change).
- Nightly **dedup** logic (only open a PR when drift is *new*) — only needed once the cron is hot.
- Visual-regression snapshots (parent design's "Optional / later," CI-only).
- PostToolUse/Stop hooks as an interactive inner loop while editing live.
- A PAT/GitHub-App token so bot PRs re-trigger `frontend.yml` CI.
