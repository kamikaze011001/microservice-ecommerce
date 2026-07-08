# HANDOFF — microservice-ecommerce — 2026-07-08

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first — write it so anyone grasps "where we are, what's next" in 10 seconds.

## Current goal
Frontend app↔Storybook consistency loop is **fully shipped** (all 3 phases merged to `main`).
No active workstream in flight. Next real work is operational: take the unattended trigger
hot and run the R1 smoke test.

## Done (settled, do not redo)
- **Phase 1 (hard gate) — MERGED (#26-era).** `pnpm check:consistency` + CI `storybook` axe job;
  16 a11y failures fixed strict; 58/58 stories green.
- **Phase 2 (/consistency-loop pipeline) — MERGED (#27).** Four-role agent skill at
  `.claude/skills/consistency-loop/`, ADR 0008. Always ends at a human-merged PR.
- **Phase 3 (unattended ignition + docs) — MERGED (#28, HEAD 6392932).**
  `.github/workflows/frontend-consistency-loop.yml` runs `/consistency-loop` via
  `anthropics/claude-code-action@v1`. `workflow_dispatch` LIVE, nightly `schedule:` cron
  COMMENTED. Runbook `frontend/docs/consistency-loop-automation.md`, ADR 0009, `frontend/CLAUDE.md`
  pointer. Changes NOTHING about skill/rubric/gate/`frontend.yml` (verified `untouched-core`).
- **AddressForm → primitives migration — MERGED (#29, HEAD 53e63a0).** Demo of `/goal`'s
  iterate-until-green loop turned into a real fix: `AddressForm.vue` six `<input>`→`BInput`,
  submit `<button>`→`BButton`; `consistency-baseline.json` entry 7→0. Widened
  `BInput.modelValue` to optional `string` (vee-validate `defineField` refs are
  `string | undefined`). Dropped `maxlength="2"` on country (zod `/^[A-Z]{2}$/` still enforces
  ISO-2). 183 tests green. Branched off `main`, independent of Phase 3.

## In progress / Next steps
- **R1 smoke test (the one open unknown) — NOT YET RUN.** Whether the `Task` subagent tool works
  headlessly inside the action is UNVERIFIED. To run it: add the `ANTHROPIC_API_KEY` repo secret,
  then trigger the workflow via `workflow_dispatch`. Pass = opens a `consistency/*` PR with blind
  findings intact, or logs the subagent limitation. Fail (self-merge or silent) = build the
  deferred degraded inline-reviewer mode (NOT pre-built — YAGNI).
- **Before going nightly:** add PR dedup ("only open when drift is new") — a full sweep re-opens
  the same advisory PR otherwise. Out of scope for Phase 3; documented in the runbook.
- **Optional follow-up:** add a `maxlength` prop to `BInput` if the country-field raw char cap is
  wanted back (validation already covers it; deferred as YAGNI).

## Known rough edges (deferred, logged, not blocking)
- Bot PRs skip `frontend.yml` CI (default-`GITHUB_TOKEN` recursion prevention) — accepted
  tradeoff to avoid PAT/GitHub-App complexity; re-run CI manually on the bot PR.
- Phase 1 hex-regex false-positives on non-color hex-shaped tokens (`url(#id)`, `#123`, SHAs).

## Settled decisions + rationale
- [[0001-in-repo-memory-alongside-untouched-claude-md]] — CLAUDE.md stays SSOT; memory lifecycle is additive.
- ADR 0008 — /consistency-loop four-role agent pipeline (Phase 2).
- ADR 0009 — unattended trigger, build-complete/gate-the-spend (Phase 3).

## Context to Load (paths only, do NOT paste contents)
- `frontend/docs/consistency-loop-automation.md` — runbook (how to take it hot, R1 triage)
- `docs/adr/0008-consistency-loop-agent-pipeline.md`, `docs/adr/0009-consistency-loop-unattended-trigger.md`
- `.claude/skills/consistency-loop/` — the Phase 2 skill (orchestrator/implementer/blind-reviewer/approver)

## Blocked / Needs user input
- None. Consistency loop fully merged. Awaiting a decision to take the trigger hot (set
  `ANTHROPIC_API_KEY`) and run the R1 smoke test.
