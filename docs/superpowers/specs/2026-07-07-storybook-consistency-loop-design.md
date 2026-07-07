# App ↔ Storybook consistency loop (loop engineering with Claude Code)

**Date:** 2026-07-07
**Branch:** `feat/storybook-consistency-loop`
**Status:** Approved design — ready for implementation planning

## Problem

The frontend design system is now consolidated into **Storybook as the single source of truth**
(tokens in `frontend/src/styles/tokens.css`, components as co-located `*.stories.ts`, rationale as
`src/design-system/foundations/*.mdx`, and the `/design-kit` skill so agents can query it). See the
[design-system SSOT spec](2026-07-05-design-system-storybook-design.md).

But the SSOT is enforced only by **prose and goodwill**. `frontend/CLAUDE.md` and `/design-kit` say
"never hard-code a hex," "reuse the `B*` primitives," "stamps for status, not badges" — yet **nothing
mechanically produces a pass/fail**. So the app and Storybook are free to drift apart, and the only loop
that catches drift today is *a human notices in review, or nobody ever does*. That is the slowest, least
reliable loop that can exist — an **open loop** held together by discipline.

This is a **loop-latency problem**. We want to close the loop: a tight, mostly-automated cycle that keeps
the running app consistent with the Storybook SSOT, built to run natively on **Claude Code**.

## What "loop engineering" means here (framing)

Three senses of the term converge on the same cycle — **gather context → act → verify → repeat** — seen
from different actors:

- **DevEx feedback loops** — put each check at the earliest/cheapest layer that can catch it ("shift left").
- **AI-agent loops** (Willison's "an agent runs tools in a loop"; swyx's "loopcraft: stacking loops";
  LangChain's "art of loop engineering") — the craft is *designing the tools + loop*, not just the prompt.
- **Claude Code's agentic loop** (Anthropic) — gather context → take action → verify results → repeat.

The unifying thesis, from Anthropic's Claude Code best-practices doc:

> *"Claude stops when the work looks done. Give Claude something that produces a pass or fail, and the loop
> closes on its own."*

Our SSOT rules currently produce no pass/fail, so "looks done" is the only signal — and it drifts. The
whole design is: **manufacture a pass/fail for consistency, then stack loops around it.**

## Goals

1. Build a **deterministic verification substrate** (`check-consistency.sh`) that turns the SSOT rules into
   machine pass/fail for the four drifts below.
2. Wrap it in a **four-role agent pipeline** (implementer → hard gate → blind reviewer → approver) that
   proposes fixes as a **PR for human review** (human *on* the loop).
3. Express the loop **natively in Claude Code** using `/goal` (inner verify loop) and `/loop` (supervised
   sweep), degrading gracefully to headless `claude -p` for unattended triggers (on-push + nightly).
4. Reuse the existing `/design-kit` skill as the implementer's SSOT context — no new SSOT.

## Non-goals

- **No new SSOT, no app re-skin.** The design system and every component stay exactly as they are. This
  project *guards* consistency; it does not restyle anything.
- **No auto-merge (for now).** UI/taste is subjective; a confident agent produces consistent-but-wrong
  changes. The loop's output is a PR a human merges. Autonomy can be earned later.
- **No visual-regression in the inner loop.** Too slow/flaky for a per-turn gate, needs human diff
  approval, and is not a mature agent practice (Storybook's official MCP is React-only + experimental;
  we are Vue). Deferred to an optional later CI-only phase.
- **No dependency on bleeding-edge design-system MCP servers.** Deterministic checks + Claude Code's
  native loop primitives only. Boring and robust over shiny.

## The four drifts (what the loop catches)

| # | Drift | Caught by | Kind of truth |
|---|---|---|---|
| 1 | **Token/rule violations** — hard-coded hex/font/spacing; hand-rolled `<button>` instead of `B*` | static lint (fast) | objective |
| 2 | **Story coverage gaps** — a component with no `*.stories.ts` | coverage script (fast) | objective |
| 3 | **Visual regression** — a token/CSS change silently alters rendering | self-hosted Playwright snapshots (**deferred**) | objective |
| 4 | **Behavior/prop drift** — story args/docs describe a component that no longer exists as shown | Storybook test-runner: render + `play()` + a11y | objective (render) |
| — | **Subjective consistency** — stamp-vs-badge, `--spot` for CTAs, copy voice, story shows all variants | blind reviewer + rubric | subjective |

## Architecture — one substrate, stacked into loops by speed

Each drift is caught at the *fastest layer that can catch it*. A per-turn gate must finish in seconds, so
slow checks sink to on-demand / CI — layering is about not poisoning the fast loop with a slow check.

```
LAYER 0 · per edit (ms) ......... PostToolUse hook (optional, interactive)
    eslint --fix + stylelint on the edited frontend file        → Drift #1

LAYER 1 · per turn (seconds) .... the HARD GATE (/goal evaluates against it)
    check-consistency.sh: token/rule scan + story-coverage scan → Drift #1, #2

LAYER 2 · on demand (minutes) ... Storybook test-runner (agent runs it / subagent)
    render every story + play() + a11y                          → Drift #4

LAYER 3 · CI backstop (frontend.yml) ... nothing drifts to main
    all of the above + (later) visual regression                → Drift #3
```

### The verification substrate — `frontend/scripts/check-consistency.sh`

The single "grader" everything reuses (Claude Code's `/goal`, the pipeline's hard gate, and CI). Exits
non-zero with machine-readable output on any violation. Composed of:

| Sub-check | Mechanism (deterministic) | Drift |
|---|---|---|
| Token/hex/font ban | stylelint (`color-no-hex`) on `<style>` blocks + regex hex/font scan in `.vue`/`.ts`, checked against `tokens.css` | #1 |
| Primitive reuse | eslint-plugin-vue rule: ban raw `<button>`/`<input>`/`<select>` outside `components/primitives/` (allowlist) | #1 |
| Story coverage | glob `components/**/*.vue` → assert sibling `*.stories.ts`; allowlist for shells/layouts | #2 |
| Behavior/render | Storybook **test-runner** (`test-storybook`) — render + `play()` + a11y (Layer 2, not in the per-turn gate) | #4 |

Fast sub-checks (token/rule + coverage) run in the per-turn gate; the test-runner runs on demand / in CI.

## The four-role agent pipeline

Role separation is the established best practice — the implementer must not grade its own work. **The hard
gate runs first** (cheapest, only role anchored in ground truth): no point spending an LLM review on code
that does not even lint or is missing a story.

```
   ① IMPLEMENTER  ──edits──►  makes app↔SSOT consistent  (/design-kit = its context)
                             │
   ② HARD GATE  ★ FIRST      │  check-consistency.sh → pass|fail
      (deterministic)        │  fail → back to ① (cheap, no LLM burned), cap 3× then escalate
                             ▼ pass
   ③ BLIND REVIEWER          │  FRESH isolated subagent (NOT a fork). Sees ONLY:
      (adversarial, critiques)│  the diff + the SSOT + a rubric. Not the implementer's reasoning.
                             │  produces findings; does NOT decide.
                             ▼
   ④ APPROVER (decides)      │  aggregates gate + findings →
                             │    go       → gh pr create   (human merges)
                             │    blocking → back to ① within cap
                             │    stuck    → DRAFT PR labeled needs-human  ← escape hatch
                             ▼
                        PR  ──►  human reviews + merges   (human ON the loop)
```

**Two truths, deliberately split:** the **hard gate (②)** owns *objective* consistency (lint, coverage,
does-the-story-render). The **blind reviewer + rubric (③)** own *subjective* consistency — the things no
regex can measure. Both are required; three LLMs agreeing can still be confidently wrong, so the
deterministic gate keeps the loop honest.

**Why the reviewer is blind:** if it sees the implementer's justification it anchors on it (shared failure
mode / sycophancy) and rubber-stamps. Isolated context + only the artifact + a rubric = an independent
prior it cannot be talked out of. In Claude Code this **must be a fresh subagent, not a `fork`** — a fork
inherits the implementer's whole conversation and destroys the blindness.

**The rubric** (`.claude/skills/consistency-loop/rubric.md`) is derived directly from
`src/design-system/foundations/*.mdx`, so the reviewer grades against *this project's documented design
intent*, not generic taste. It covers: stamp-vs-badge, `--spot` for every CTA/focus (never for stamps),
hard-offset shadow only, story shows all variants/states, copy voice, a11y intent.

**Termination:** implementer↔gate is capped at **3 passes**; on the 3rd failure the approver opens a draft
PR labeled `needs-human` instead of grinding. Autonomous loops without a stop condition are the #1 failure
mode.

## Native Claude Code expression (`/loop` + `/goal`)

Every loop maps to exactly one Claude Code primitive; the pipeline itself is a `/consistency-loop` skill.

```
/loop 1d /consistency-loop            ← OUTER loop: the supervised recurring sweep
   └─ /consistency-loop runs ONE pass:
        set /goal "check-consistency.sh exits 0 AND blind reviewer: no blocking findings"
        │   └─ each turn, /goal re-checks → runs the hard gate → not met? keep working  ★ inner loop
        ├─ ① implementer edits toward the goal
        ├─ ③ blind reviewer subagent (fresh context) + rubric
        └─ ④ approver → gh pr create
```

| Loop | Native command | Role |
|---|---|---|
| Inner verify ("keep fixing until consistent") | **`/goal`** | condition = hard gate passes; re-checked each turn, keeps the implementer working until green |
| Outer sweep ("run on schedule") | **`/loop`** | re-runs `/consistency-loop` on an interval (or self-paced) while a session is open |
| The pipeline | **`/consistency-loop` skill** | implementer → gate → blind reviewer → approver → PR |
| Hard gate | `check-consistency.sh` | what `/goal` evaluates against |

`/goal` is the **ergonomic** form of "keep working until green"; a **Stop hook** is the *hard* form (an
absolute block, overridable only by the 8-block cap). Default to `/goal`; keep the Stop hook in reserve
for absolute enforcement. Same `check-consistency.sh` underneath both.

### The honest boundary — session-bound vs unattended

`/loop` and `/goal` run only while a Claude Code session is open. The **same** `/consistency-loop` skill and
`check-consistency.sh` power the unattended triggers via a different ignition — nothing is duplicated.

| Trigger (chosen) | Session open? | Mechanism |
|---|---|---|
| You, supervising | ✅ | `/loop /consistency-loop` + `/goal` (native) |
| On push to main (frontend/**) | ❌ | GitHub Action → headless `claude -p /consistency-loop` → PR |
| Nightly sweep, unattended | ❌ | scheduled cloud routine → same skill → PR |

## Phased build (value ships before the fancy part)

1. **Phase 1 — the hard gate.** `check-consistency.sh` = stylelint hex/font ban + primitive-reuse eslint
   rule + story-coverage script + Storybook test-runner. Wire into the existing `frontend.yml` CI. *Useful
   on its own even if the agent pipeline never ships.*
2. **Phase 2 — the agent pipeline.** The `/consistency-loop` skill (implementer → gate → blind reviewer +
   rubric → approver → PR) and the rubric file. Run it **manually** first to prove it before automating.
3. **Phase 3 — the triggers.** On-push GitHub Action (headless `claude -p`) + nightly scheduled cloud
   routine. Both call the Phase-2 skill.
4. **Optional / later.** Visual regression (self-hosted Playwright snapshots) at CI only; PostToolUse/Stop
   hooks as a complementary *interactive* inner loop while editing live.

## Artifacts this design produces

- `frontend/scripts/check-consistency.sh` — the hard gate (orchestrates sub-checks, exit code).
- `frontend/scripts/check-story-coverage.mjs` — story-coverage sub-check.
- Stylelint config (`color-no-hex` etc.) + eslint primitive-reuse rule (extends existing `eslint.config.js`).
- Storybook **test-runner** wiring (`@storybook/test-runner`, `pnpm test-storybook`).
- `.claude/skills/consistency-loop/SKILL.md` — the four-role orchestrator skill.
- `.claude/skills/consistency-loop/rubric.md` — the blind reviewer's rubric, derived from `foundations/*.mdx`.
- `.github/workflows/frontend-consistency.yml` (or an extended `frontend.yml`) — on-push trigger → PR.
- A scheduled cloud routine (via `/schedule`) — the nightly sweep.
- `docs/adr/` entry recording the decision; `frontend/CLAUDE.md` note pointing at the loop.

## What does NOT change

- The design system, `tokens.css`, and every component's markup/styles/behavior.
- The `/design-kit` skill (reused as-is for the implementer's context).
- App routing, API layer, forms, or the existing `pnpm typecheck`/`lint`/`test` behavior.

## Success criteria

- `frontend/scripts/check-consistency.sh` exits non-zero on a planted violation of each fast check
  (hard-coded hex, hand-rolled `<button>`, a component missing its story) and zero on a clean tree.
- `pnpm test-storybook` renders every story + runs `play()`/a11y; a story referencing a removed prop fails.
- `/consistency-loop` run manually on a repo with seeded drift: implementer fixes it, hard gate goes green,
  blind reviewer (fresh context) produces findings, approver opens a PR — capped at 3 passes with a
  `needs-human` escape hatch.
- On-push GitHub Action and the nightly routine both open a PR (never auto-merge) when drift is found.
- Existing `frontend.yml` (typecheck/lint/test) still passes; the hard gate is added as a new CI step.

## Open questions (resolve during planning)

- Exact regex/stylelint rule set for the hex/font ban — reconcile with Tailwind 4 utilities so token
  utilities aren't flagged as violations.
- Primitive-reuse rule: eslint-plugin-vue custom rule vs a simpler `no-restricted-syntax` template check,
  and the exact allowlist (which raw elements are legitimately outside `primitives/`).
- Story-coverage allowlist policy (layouts/shells/pages that legitimately have no story).
- Extend `frontend.yml` vs a separate `frontend-consistency.yml` workflow.
- Exact `/goal` evaluator capability — confirm it can gate on the script's exit code directly vs the skill
  reporting the result each turn.
- Headless `claude -p` auth/permissions model in CI (`--allowedTools`, secrets) for the on-push path.
- Whether Phase 1's fast gate also lands as a pre-commit step (belt) in addition to CI.
