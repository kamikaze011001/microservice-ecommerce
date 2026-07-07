# App ↔ Storybook consistency loop — Phase 2: the agent pipeline

**Date:** 2026-07-07
**Branch:** `feat/storybook-consistency-loop-phase2`
**Status:** Approved design — ready for implementation planning
**Parent design:** [`2026-07-07-storybook-consistency-loop-design.md`](2026-07-07-storybook-consistency-loop-design.md)
**Depends on:** Phase 1 (the hard gate) — merged in PR #26.

## Problem

Phase 1 shipped the **deterministic verification substrate** (`frontend/scripts/check-consistency.sh`)
and wired it into CI. That closes the loop on **objective** drift — hard-coded hex, hand-rolled
`<button>/<input>/<select>`, missing stories, and (via the Storybook test-runner) render/a11y drift.

But two things are still open-loop:

1. **Subjective consistency** — stamp-vs-badge, `--spot` for CTAs, hard-offset shadows, copy voice.
   No regex can measure these; they drift silently past the gate.
2. **The fix is still manual** — when drift is found, a human writes the correction. There is no agent
   that proposes the fix and packages it for review.

Phase 2 closes both: a **four-role agent pipeline** that proposes consistency fixes as a **PR for human
review**, with a **blind reviewer + rubric** owning the subjective truth the hard gate cannot. Per the
parent design, Phase 2 is **run manually first** to prove it before any automation (Phase 3).

## Goals

1. Build the `/consistency-loop` skill: **implementer → hard gate → blind reviewer → approver → PR**,
   expressed in Claude Code subagent mechanics.
2. Author the **rubric** (`.claude/skills/consistency-loop/rubric.md`) derived from
   `frontend/src/design-system/foundations/*.mdx` + `guides/CopyVoice.mdx`, so the reviewer grades
   against *this project's* documented design intent, not generic taste.
3. **Prove it manually** on one real inconsistency and merge the resulting PR.
4. Reuse Phase 1's `check-consistency.sh` and the existing `/design-kit` skill unchanged — no new SSOT.

## Non-goals (deferred to Phase 3 / later, per parent design)

- **No unattended triggers.** On-push GitHub Action + nightly `claude -p` are **Phase 3**.
- **No `/loop` + `/goal` native automation.** The single manual run stands in for the automated inner
  loop in this phase.
- **No visual-regression snapshots.** Optional later CI-only phase.
- **No auto-merge, no app re-skin, no new SSOT.** Every path ends at a PR a human merges.

## Architecture — one manual pass

The main Claude Code session is a **thin orchestrator + approver**. It dispatches **separate subagents**
for the implementer and the blind reviewer (chosen for the cleanest role separation), and runs the hard
gate itself via `Bash`. The blind reviewer is a **fresh subagent, never a `fork`** — a fork inherits the
implementer's reasoning and destroys the blindness.

```
USER: /consistency-loop            (main session = ORCHESTRATOR + APPROVER)
  │
  ├─ ① dispatch IMPLEMENTER subagent (fresh, general-purpose)
  │       context: /design-kit (SSOT) + a scope (target files / "scan for drift")
  │       returns: a diff (edits toward consistency) — NOT committed yet
  │
  ├─ ② HARD GATE  ★ runs FIRST, in the orchestrator via Bash
  │       cd frontend && ./scripts/check-consistency.sh
  │       fail → loop back to ① with the gate output, cap 3× → escalate
  │       pass ▼
  │
  ├─ ③ dispatch BLIND REVIEWER subagent (FRESH, NOT a fork)
  │       sees ONLY: the diff + the SSOT (foundations/*.mdx) + rubric.md
  │       does NOT see: the implementer's reasoning or this conversation
  │       returns: findings {blocking | advisory}, does NOT decide
  │
  └─ ④ APPROVER (orchestrator decides)
          no blocking      → gh pr create        (human merges)
          blocking, <cap   → back to ① with findings
          stuck at cap     → gh pr create --draft, label needs-human
```

**Two truths, deliberately split.** The **hard gate (②)** owns objective consistency (lint, coverage,
render). The **blind reviewer + rubric (③)** own subjective consistency. Both are required — three LLMs
agreeing can still be confidently wrong, so the deterministic gate keeps the loop honest.

**Gate first.** No LLM review is spent on code that does not even lint or is missing a story.

**Inner loop is orchestrator-driven dispatch, not `/goal`.** Because the implementer is a subagent, it
runs to completion and returns a diff; the orchestrator then runs the gate and decides whether to
re-dispatch. `/goal` (which gates the *main session's* stopping) fits a self-implementing session, not
this separated-subagent model, so it is not used here.

## The rubric (`.claude/skills/consistency-loop/rubric.md`)

Hand-authored from `foundations/*.mdx` + `guides/CopyVoice.mdx`. It is the **only** judgment context the
blind reviewer receives, alongside the diff and the foundations files themselves. Each item is a concrete
pass/fail the reviewer applies to the diff, tagged **blocking** (a documented hard rule) or **advisory**
(taste nudge).

| # | Rubric check | Source | Severity |
|---|---|---|---|
| 1 | **Stamps, not badges** — status (PAID/PROCESSING/CANCELED) uses `<BStamp>`, never a rounded pill/badge | Identity, SignatureDetails | blocking |
| 2 | **Spot discipline** — `--spot` for *every* CTA/focus/alert; `--stamp-red` for stamps + validation borders only, **never a CTA**; no 4th colour without token + ADR | Color | blocking |
| 3 | **Shadow language** — hard offset only, no blur/opacity; correct rung of the shadow ladder | BordersShadows | blocking |
| 4 | **Primitive intent** — reused a `B*` primitive rather than re-implementing its look inline (catches what survives the gate's raw-element scan) | Identity | blocking |
| 5 | **Signature details in place** — misregistration hover on card titles, ±0.5° sticker rotation, `<BCropmarks>` over `<hr>`, marginalia numerals where the layout calls for them | SignatureDetails | advisory |
| 6 | **Story completeness** — a touched component's story shows all its variants/states (the gate only checks the story *exists*) | Components guide | advisory |
| 7 | **Copy voice** — printer-shop deadpan; present-tense declarative; Title Case for CTAs/stamps; mono for IDs/prices/timestamps; no "Oops!/Whoops!"; uses the copy bank | CopyVoice | advisory |

**Decision rule handed to the approver:** any **blocking** finding → back to the implementer (within the
3× cap); only **advisory** findings → the PR proceeds with them noted in the description. The reviewer
*reports*; the approver *decides*.

## Termination & outputs

The #1 failure mode of an agent loop is no stop condition. Therefore:

- Implementer ↔ gate ↔ reviewer is capped at **3 passes**.
- **Go** (gate green, no blocking findings) → `gh pr create`; advisory findings listed in the body; human merges.
- **Stuck** (still failing on the 3rd pass) → `gh pr create --draft` labelled **`needs-human`** — a real,
  reviewable artifact, never a silent grind. The `needs-human` label is created in the repo once.
- **Never auto-merge.** Every path ends at a PR a human merges.

## Manual proof (the Phase 2 acceptance run)

Phase 1 already blocks every objective drift, so the tree is clean under the gate. During planning we hunt
the app for one **real** inconsistency that survives the gate — almost certainly a **subjective** one (a
status rendered as a plain label instead of `<BStamp>`, a `--stamp-red`/`--spot` misuse, or off copy
voice). This is ideal: it exercises the blind reviewer + rubric — the exact part of the pipeline Phase 1
never tested.

Acceptance: run `/consistency-loop` against that drift once and observe the full pass —
implementer edits → gate green → reviewer flags the issue against the rubric → approver opens a PR — then
merge that PR as the proof the loop works end to end.

## Artifacts this phase produces

- `.claude/skills/consistency-loop/SKILL.md` — the four-role orchestrator.
- `.claude/skills/consistency-loop/rubric.md` — the blind reviewer's rubric.
- The `needs-human` GitHub label (created once).
- One merged PR from a real manual run (the proof).
- A `docs/adr/` entry recording the pipeline decision; a `frontend/CLAUDE.md` note pointing at the loop.

## What does NOT change

- Phase 1's `check-consistency.sh`, the CI wiring, and the Storybook test-runner job.
- The `/design-kit` skill (reused as-is for the implementer's context).
- The design system, `tokens.css`, and every component's markup/styles/behavior.

## Success criteria

- `/consistency-loop` run manually against one seeded/real drift: the implementer fixes it, the hard gate
  goes green, a **fresh** blind-reviewer subagent produces rubric findings, and the approver opens a PR —
  capped at 3 passes with a `needs-human` draft-PR escape hatch on the 3rd failure.
- The reviewer subagent demonstrably has no access to the implementer's reasoning (fresh context, not a fork).
- A blocking rubric violation sends the loop back to the implementer; an advisory-only result lets the PR proceed.
- No path auto-merges; every run ends at a PR (ready or draft+`needs-human`).
- Phase 1's gate and CI behaviour are unchanged.

## Open questions (resolve during planning)

- Which subagent type for the implementer and reviewer (`general-purpose` vs a custom agent definition),
  and how the diff is passed to the reviewer (uncommitted working tree vs a temp commit vs a `.diff` file).
- Exactly how the orchestrator captures "the diff" for the reviewer without leaking implementer chatter.
- The concrete real-drift target for the manual proof (identified during planning by scanning the app).
- Whether the rubric file is duplicated content or references the `foundations/*.mdx` by path (DRY vs
  self-contained reviewer context).
- ADR number/location and the exact `frontend/CLAUDE.md` pointer wording.
