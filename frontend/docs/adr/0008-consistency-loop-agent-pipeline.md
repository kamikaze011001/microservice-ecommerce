# 0008 — Consistency loop: the four-role agent pipeline

**Status:** Accepted
**Date:** 2026-07-07

## Context

Phase 1 shipped the deterministic hard gate (`pnpm check:consistency`, wired into CI plus a
Storybook axe job). It closes the loop on **objective** app↔Storybook drift: hard-coded hex,
hand-rolled `<button>/<input>/<select>`, missing stories, render/a11y regressions.

Two things stayed open-loop:

1. **Subjective consistency** — stamp-vs-badge, `--spot`-for-CTAs-only, hard-offset shadows, copy
   voice. No regex measures these; they drift silently past the gate.
2. **The fix was still manual** — when drift was found, a human wrote the correction. Nothing
   proposed the fix and packaged it for review.

We want an owner for subjective consistency without handing an LLM a merge button.

## Decision

Add `/consistency-loop`: a **four-role agent pipeline** — implementer → hard gate → blind
reviewer → approver → PR — run from a thin orchestrator session.

- **Separated subagents.** The orchestrator dispatches a _fresh_ `general-purpose` implementer
  and a _fresh_ read-only `Explore` blind reviewer. It runs the hard gate itself via Bash.
- **Gate first, every iteration.** No LLM review is spent on code that fails `check:consistency`.
- **Blind reviewer, never a fork.** The reviewer sees only the diff + the rubric
  (`.claude/skills/consistency-loop/rubric.md`) + the foundations — never the implementer's
  reasoning. A fork would inherit that reasoning and rubber-stamp, so it is forbidden.
- **Two truths, split on purpose.** The hard gate owns objective consistency; the blind reviewer +
  rubric own subjective consistency. Both are required — agreeing LLMs can still be confidently
  wrong, so the deterministic gate keeps the loop honest.
- **Approver decides, reviewer only reports.** Any `[blocking]` rubric finding routes back to the
  implementer; advisory-only findings let the PR proceed with them noted in the body.
- **Bounded.** The implementer↔gate↔reviewer loop is capped at **3 passes**. On the 3rd failure it
  opens a `--draft` PR labelled `needs-human` — a real reviewable artifact, never a silent grind.
- **Never auto-merge.** Every path ends at a PR a human merges. The human is _on_ the loop.
- **Manual in Phase 2.** Unattended triggers (on-push Action, nightly `claude -p`) are deferred to
  Phase 3; Phase 2 proves the pipeline with one manual run.

## Alternatives considered

| Option                                            | Why not                                                                                                                                                             |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Single self-implementing session gated by `/goal` | The implementer is a subagent that runs to completion and returns a diff; `/goal` gates a session's _own_ stopping, which doesn't fit the separated-subagent model. |
| Blind reviewer as a `fork` of the implementer     | The fork inherits the implementer's reasoning and rubber-stamps its own work — it destroys the blindness the review depends on.                                     |
| Gate after the LLM review                         | Wastes LLM review on code that doesn't lint or is missing a story; the deterministic gate is cheaper and must pass regardless.                                      |
| Auto-merge on green + no findings                 | Removes the human from the loop; three LLMs agreeing can still be confidently wrong. Every run must end at a human-merged PR.                                       |
| Extend the regex gate to cover subjective rules   | Stamp-vs-badge, spot discipline, and copy voice aren't regex-measurable; forcing them into lint yields false positives and still misses intent.                     |

## Consequences

- **Positive:** subjective consistency finally has an owner; every fix arrives as a reviewed PR
  with the gate result and any advisories in the body; the rubric makes the design intent
  (foundations + copy voice) an executable review contract; the loop is bounded and always
  terminates at a reviewable artifact.
- **Negative / accepted:** each run costs subagent tokens (two dispatches per iteration, up to the
  cap); the blindness guarantee depends entirely on the "fresh subagent, never a fork" rule holding
  — if a future edit swaps in a fork, reviews silently degrade to rubber-stamps; the rubric must be
  kept in sync with `foundations/*.mdx` as the design system evolves.
