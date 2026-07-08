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
   _Settings → Secrets and variables → Actions_.
2. _Actions → frontend-consistency-loop → Run workflow_. Optionally set `scope` (default:
   `scan frontend/src for drift`).
3. The run dispatches the four-role pipeline (implementer → hard gate → blind reviewer → approver)
   and, if it finds drift, opens a `consistency/*` PR for you to review and merge.

## How to take the nightly cron hot

1. Ensure the `ANTHROPIC_API_KEY` secret is set (above).
2. In `.github/workflows/frontend-consistency-loop.yml`, uncomment the `schedule:` block:
   ```yaml
   schedule:
     - cron: '0 7 * * *' # 07:00 UTC nightly
   ```
3. Commit. The sweep now runs nightly and opens a PR only when it finds drift.

> **Before going nightly, add dedup.** A nightly full sweep re-opens the _same_ advisory PR until the
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

The skill dispatches _separate_ subagents for the implementer and the **fresh blind reviewer** (never
a fork) via the `Task` tool. Whether `Task` works inside the headless action is undocumented. **The
first `workflow_dispatch` run is the smoke test:**

- If it works → the pipeline runs faithfully, blindness intact.
- If it does not → the unattended path needs a degraded inline-reviewer mode (a documented
  limitation; human PR review is the compensating control). That fallback is intentionally **not**
  pre-built — it is only worth building if this smoke test fails.
