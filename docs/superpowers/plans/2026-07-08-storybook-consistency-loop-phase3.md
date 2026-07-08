# Consistency Loop Phase 3 — Unattended Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone GitHub Actions workflow that runs the existing `/consistency-loop` skill headlessly, shipped complete but with recurring spend gated (live `workflow_dispatch`, commented `schedule:`), plus the docs to operate it.

**Architecture:** Pure ignition + documentation. One new workflow file invokes `anthropics/claude-code-action@v1` to run `/consistency-loop`; a runbook, an ADR, and a `frontend/CLAUDE.md` pointer document how to operate and later take it hot. Nothing about the skill, rubric, hard gate, or `frontend.yml` changes.

**Tech Stack:** GitHub Actions, `anthropics/claude-code-action@v1`, Docker-based `actionlint` for verification, Markdown docs.

## Global Constraints

- **Byte-for-byte unchanged:** `.claude/skills/consistency-loop/**`, `frontend/scripts/check-consistency.sh`, `.github/workflows/frontend.yml`, the design system, and all app code. Phase 3 touches only the 4 new/modified artifacts below.
- **Never auto-merge:** the workflow MUST NOT contain `gh pr merge` (or any merge invocation). The guarantee is structural — the workflow only ever opens a PR.
- **Gated activation:** `workflow_dispatch` is LIVE; `schedule:` is present but COMMENTED OUT. No `ANTHROPIC_API_KEY` secret is required to land Phase 3.
- **No recursion:** the workflow triggers ONLY on `workflow_dispatch`/`schedule` — never `push` or `pull_request`.
- **Permissions floor:** `permissions:` limited to `contents: write` + `pull-requests: write`. No PAT / GitHub App token.
- **Branch:** all work on `feat/storybook-consistency-loop-phase3` (already created off `main`; the spec is already committed there at `6fcdff2`).
- **ADR house style:** follow `frontend/docs/adr/0000-template.md` (as `0008` does).

---

### Task 1: The unattended workflow

**Files:**
- Create: `.github/workflows/frontend-consistency-loop.yml`

**Interfaces:**
- Consumes: the existing `/consistency-loop` skill (`.claude/skills/consistency-loop/SKILL.md`) — invoked verbatim as a slash command via the action's `prompt:` input. No code interface; the contract is the skill name and its optional scope argument.
- Produces: a workflow named `frontend-consistency-loop` with a `workflow_dispatch` input `scope` (string, default `"scan frontend/src for drift"`). Referenced by name in Task 2 (runbook) and Task 3 (ADR + CLAUDE.md pointer).

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/frontend-consistency-loop.yml` with exactly this content:

```yaml
name: frontend-consistency-loop

# Unattended ignition for the /consistency-loop skill (Phase 3).
# The manual "Run workflow" button is LIVE. The nightly cron is intentionally
# COMMENTED OUT — see frontend/docs/consistency-loop-automation.md for how to
# take it hot (add the ANTHROPIC_API_KEY secret, then uncomment the schedule).
on:
  workflow_dispatch:
    inputs:
      scope:
        description: "Scope passed to /consistency-loop"
        required: false
        default: "scan frontend/src for drift"
  # schedule:
  #   - cron: "0 7 * * *"   # 07:00 UTC nightly; requires the ANTHROPIC_API_KEY secret

# Never auto-merge: this workflow only ever OPENS a PR. The guarantee is
# structural — it never calls `gh pr merge` — backed by branch protection on main.
permissions:
  contents: write
  pull-requests: write

# One loop at a time; do not cancel a run mid-pipeline (it may be mid-PR).
concurrency:
  group: consistency-loop
  cancel-in-progress: false

jobs:
  consistency-loop:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run /consistency-loop headlessly
        uses: anthropics/claude-code-action@v1
        with:
          # Unset in the gated build — a run without it fails fast with a clear
          # "no auth" error. Setting this secret is step 1 of going hot.
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: "/consistency-loop ${{ inputs.scope || 'scan frontend/src for drift' }}"
          claude_args: '--allowedTools "Edit,Bash,Task,Read,Glob,Grep"'
```

- [ ] **Step 2: Lint the workflow with actionlint (Docker)**

Run:
```bash
docker run --rm -v "$PWD":/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/frontend-consistency-loop.yml
```
Expected: exit code 0, no output (actionlint prints nothing when clean). First run pulls the image.

If Docker/network is unavailable, fall back to a YAML syntax parse:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/frontend-consistency-loop.yml')); print('yaml ok')"
```
Expected: `yaml ok`.

- [ ] **Step 3: Assert the structural guarantees**

Run each check; every line must print `ok`:
```bash
f=.github/workflows/frontend-consistency-loop.yml
grep -q 'workflow_dispatch:' "$f" && echo "ok dispatch-live"
! grep -qE '^[[:space:]]*schedule:' "$f" && echo "ok schedule-commented"
grep -q '# schedule:' "$f" && echo "ok schedule-present"
! grep -qE '^[[:space:]]*(push|pull_request):' "$f" && echo "ok no-push-pr-trigger"
grep -q 'contents: write' "$f" && grep -q 'pull-requests: write' "$f" && echo "ok permissions"
! grep -qi 'pr merge' "$f" && echo "ok no-auto-merge"
grep -q 'anthropics/claude-code-action@v1' "$f" && echo "ok action-pinned"
```
Expected: `ok dispatch-live`, `ok schedule-commented`, `ok schedule-present`, `ok no-push-pr-trigger`, `ok permissions`, `ok no-auto-merge`, `ok action-pinned`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/frontend-consistency-loop.yml
git commit -m "feat(frontend): unattended /consistency-loop workflow (gated) — Phase 3

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: The operations runbook

**Files:**
- Create: `frontend/docs/consistency-loop-automation.md`

**Interfaces:**
- Consumes: the workflow file name `.github/workflows/frontend-consistency-loop.yml` from Task 1.
- Produces: the runbook path `frontend/docs/consistency-loop-automation.md`, referenced by Task 1's inline comments and by Task 3 (ADR + CLAUDE.md pointer).

- [ ] **Step 1: Create the runbook**

Create `frontend/docs/consistency-loop-automation.md` with exactly this content:

````markdown
# Consistency loop — unattended automation (runbook)

`.github/workflows/frontend-consistency-loop.yml` runs the `/consistency-loop` skill headlessly, so
app↔Storybook drift can be swept without an open Claude Code session. This is **Phase 3** of the
consistency loop (see `docs/superpowers/specs/2026-07-08-storybook-consistency-loop-phase3-design.md`).

## Current state: gated

The workflow ships **complete but with recurring spend gated**:

- **`workflow_dispatch` (the "Run workflow" button) is LIVE** — the demonstrable path.
- **The nightly `schedule:` cron is COMMENTED OUT.**
- **No `ANTHROPIC_API_KEY` secret is set** — a run without it fails fast with a clear "no auth" error.

So merging this workflow costs nothing and cannot run on Anthropic's dime until you opt in.

## How to run it now (manual, needs the secret)

1. Add repo secret **`ANTHROPIC_API_KEY`** (or use `claude_code_oauth_token`) under
   *Settings → Secrets and variables → Actions*.
2. *Actions → frontend-consistency-loop → Run workflow*. Optionally set `scope` (default:
   `scan frontend/src for drift`).
3. The run dispatches the four-role pipeline (implementer → hard gate → blind reviewer → approver)
   and, if it finds drift, opens a `consistency/*` PR for you to review and merge.

## How to take the nightly cron hot

1. Ensure the `ANTHROPIC_API_KEY` secret is set (above).
2. In `.github/workflows/frontend-consistency-loop.yml`, uncomment the `schedule:` block:
   ```yaml
   schedule:
     - cron: "0 7 * * *"   # 07:00 UTC nightly
   ```
3. Commit. The sweep now runs nightly and opens a PR only when it finds drift.

> **Before going nightly, add dedup.** A nightly full sweep re-opens the *same* advisory PR until the
> drift is fixed. Building "only open a PR when the drift is new" is deferred until the cron is hot
> (it is out of scope for the gated Phase 3). Without it, expect duplicate PRs.

## Guarantees & tradeoffs

- **Never auto-merges.** The workflow only ever calls `gh pr create`, never `gh pr merge`. GitHub has
  no merge-only permission, so this is enforced structurally (what the workflow does) + branch
  protection on `main`, not by token scope. Every run ends at a PR a human merges.
- **Cannot chase its own tail.** It triggers only on `workflow_dispatch`/`schedule`, never on
  `push`/`pull_request`. Belt-and-braces: PRs opened with the default `GITHUB_TOKEN` do not trigger
  further `push`/`pull_request` runs (GitHub built-in recursion prevention).
- **Tradeoff — bot PRs skip `frontend.yml` CI.** Because of that same recursion prevention, the
  corrective PR does not auto-trigger the `verify`/`storybook` jobs. Re-run them manually from the PR
  if you want CI on the bot's changes. This keeps the workflow off PAT/GitHub-App-token complexity.

## Known caveat — headless subagents (R1)

The skill dispatches *separate* subagents for the implementer and the **fresh blind reviewer** (never
a fork) via the `Task` tool. Whether `Task` works inside the headless action is undocumented. **The
first `workflow_dispatch` run is the smoke test:**

- If it works → the pipeline runs faithfully, blindness intact.
- If it does not → the unattended path needs a degraded inline-reviewer mode (a documented
  limitation; human PR review is the compensating control). That fallback is intentionally **not**
  pre-built — it is only worth building if this smoke test fails.
````

- [ ] **Step 2: Verify the runbook exists and cross-links resolve**

Run; every line must print `ok`:
```bash
f=frontend/docs/consistency-loop-automation.md
test -f "$f" && echo "ok exists"
grep -q 'frontend-consistency-loop.yml' "$f" && echo "ok links-workflow"
grep -q 'gh pr merge' "$f" && echo "ok mentions-no-merge-rule"
grep -qi 'R1' "$f" && echo "ok documents-r1"
```
Expected: `ok exists`, `ok links-workflow`, `ok mentions-no-merge-rule`, `ok documents-r1`.

- [ ] **Step 3: Commit**

```bash
git add frontend/docs/consistency-loop-automation.md
git commit -m "docs(frontend): runbook for the unattended consistency loop — Phase 3

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: ADR 0009 + CLAUDE.md pointer + whole-branch verification

**Files:**
- Create: `frontend/docs/adr/0009-consistency-loop-unattended-trigger.md`
- Modify: `frontend/CLAUDE.md` (add one bullet under "Design system", after the existing "Consistency loop:" bullet at lines 55–57)

**Interfaces:**
- Consumes: the workflow path (Task 1) and the runbook path (Task 2).
- Produces: the final documented, cross-linked Phase 3 artifact set. No downstream tasks.

- [ ] **Step 1: Create ADR 0009**

Create `frontend/docs/adr/0009-consistency-loop-unattended-trigger.md` with exactly this content:

```markdown
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

| Option | Why not |
| ------ | ------- |
| Both triggers hot now (parent-design default) | Permanent billed runs + a merge-capable secret on a solo repo, for drift `frontend.yml` mostly already catches; needs nightly dedup work first. |
| Extend `frontend.yml` with a loop job | Mixes a PR-opening, secret-bearing, write-scoped job into read-only PR jobs that must never run the loop — a footgun. |
| Local Claude Code cron (`CronCreate`) | Only fires while your machine is up; it just schedules a session, which is not the unattended-cloud path Phase 3 exists to build. |
| PAT / GitHub App token so bot PRs re-trigger CI | Reintroduces recursion risk and a broader secret; not worth it — humans re-run CI on the reviewed PR. |

## Consequences

- **Positive:** the unattended ignition exists and is demonstrable via one button press with zero
  recurring spend; going hot is a documented one-secret/one-uncomment flip; no change to the skill,
  rubric, gate, or `frontend.yml`.
- **Negative / accepted:** the nightly cadence is never exercised until someone opts in; bot PRs skip
  `frontend.yml` CI; whether the `Task` subagent tool works headlessly is unverified until the first
  `workflow_dispatch` run (risk R1 in the design), and no degraded inline-reviewer fallback is
  pre-built.
```

- [ ] **Step 2: Add the CLAUDE.md pointer**

In `frontend/CLAUDE.md`, find the existing bullet (lines 55–57):
```markdown
- **Consistency loop:** `/consistency-loop` proposes app↔Storybook consistency fixes as a
  reviewed PR (four-role agent pipeline; hard gate = `pnpm check:consistency`). See
  `docs/adr/0008-consistency-loop-agent-pipeline.md`.
```
Insert this new bullet immediately after it:
```markdown
- **Consistency loop automation:** `.github/workflows/frontend-consistency-loop.yml` runs
  `/consistency-loop` unattended — manual `workflow_dispatch` now, nightly cron gated. Runbook +
  how to take it hot: `frontend/docs/consistency-loop-automation.md`. See
  `docs/adr/0009-consistency-loop-unattended-trigger.md`.
```

- [ ] **Step 3: Verify cross-links and the "unchanged files" guarantee**

Run; every line must print `ok`:
```bash
# ADR + pointer exist and cross-link
test -f frontend/docs/adr/0009-consistency-loop-unattended-trigger.md && echo "ok adr-exists"
grep -q '0009-consistency-loop-unattended-trigger' frontend/CLAUDE.md && echo "ok claude-links-adr"
grep -q 'frontend-consistency-loop.yml' frontend/CLAUDE.md && echo "ok claude-links-workflow"
grep -q 'consistency-loop-automation.md' frontend/CLAUDE.md && echo "ok claude-links-runbook"
grep -q 'consistency-loop-automation.md' frontend/docs/adr/0009-consistency-loop-unattended-trigger.md && echo "ok adr-links-runbook"

# Global constraint: skill / gate / frontend.yml byte-for-byte unchanged on this branch
test -z "$(git diff --name-only main...HEAD -- .claude/skills/consistency-loop frontend/scripts/check-consistency.sh .github/workflows/frontend.yml)" && echo "ok untouched-core"
```
Expected: `ok adr-exists`, `ok claude-links-adr`, `ok claude-links-workflow`, `ok claude-links-runbook`, `ok adr-links-runbook`, `ok untouched-core`.

- [ ] **Step 4: Confirm the full Phase 3 diff is exactly the intended files**

Run:
```bash
git diff --name-only main...HEAD
```
Expected exactly these five paths (spec from `6fcdff2` + the four Phase 3 artifacts):
```
.github/workflows/frontend-consistency-loop.yml
docs/superpowers/specs/2026-07-08-storybook-consistency-loop-phase3-design.md
frontend/CLAUDE.md
frontend/docs/adr/0009-consistency-loop-unattended-trigger.md
frontend/docs/consistency-loop-automation.md
```

- [ ] **Step 5: Commit**

```bash
git add frontend/docs/adr/0009-consistency-loop-unattended-trigger.md frontend/CLAUDE.md
git commit -m "docs(frontend): ADR 0009 + CLAUDE.md pointer for unattended loop — Phase 3

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Done criteria (whole plan)

- `actionlint` (or YAML parse fallback) clean on the new workflow; all structural greps pass.
- `workflow_dispatch` live, `schedule:` present-but-commented, no `push`/`pull_request` trigger, `permissions` limited to `contents:`/`pull-requests: write`, no `gh pr merge`.
- Runbook, ADR 0009, and the `frontend/CLAUDE.md` pointer all exist and cross-link.
- `git diff main...HEAD` shows only the five intended paths; `.claude/skills/consistency-loop/**`, `check-consistency.sh`, and `frontend.yml` are untouched.
- **Not a hard gate (documented, R1):** the first `workflow_dispatch` run with a secret set either opens a `consistency/*` PR with blind-reviewer findings intact (never merged), or surfaces the subagent limitation in the run log. Both are a pass; only a silent or self-merging run is a failure.
