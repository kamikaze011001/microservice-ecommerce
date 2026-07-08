# Design: two self-paced `/loop` prompts to enhance the frontend

**Date:** 2026-07-08
**Branch:** `feat/frontend-enhance-loops`
**Status:** Approved (design) — ready for implementation plan

## Summary

Add two **local, self-paced `/loop` runners** that incrementally improve the
frontend, each ending at **one human-merged PR**. They are distinct from the
existing cloud/cron `/consistency-loop` automation:

- **`/loop /migrate-sweep`** — drains `frontend/scripts/consistency-baseline.json`
  (9 grandfathered files, 14 raw `<button>/<input>/<select>` elements) to
  all-zero by migrating each file to the `B*` primitives.
- **`/loop /coverage-step`** — writes a Vitest spec for each untested composable/store.
  This repo centralizes tests as `tests/unit/**/*.spec.ts` (mirroring `src/`), not as
  sibling files. Against that convention the genuinely untested units are **2**:
  `composables/useToast.ts` and `composables/usePageMeta.ts` (`auth`, `toast`, and
  `useDebouncedRef` already have specs). The loop re-scans each run, so newly added
  composables/stores are picked up automatically on the next invocation.

### Why `/loop` (not another cron trigger)

`/consistency-loop` is a one-shot 4-role pipeline, optionally fired by GitHub
Actions cron in the cloud. `/loop` is a **local, in-session** runner: `/loop <prompt>`
with **no interval** self-paces via wake-ups on the developer's machine. It is a
hands-on "walk the repo until there's no work left" tool, not a replacement for
the unattended trigger.

## Shared loop contract

Both loops obey the same contract:

- **State lives in git + the baseline file, never in model memory.** Each wake-up
  re-inspects the repo, does **exactly one unit of work**, commits it, then either
  schedules the next wake-up or stops. A killed session resumes from git state.
- **One unit per iteration, always commit** — progress survives interruption; never batch.
- **Never touch** `tokens.css`, `check-consistency.sh`, or CI.
- **Human is on the loop:** every loop ends at **one PR a human merges**. Never auto-merge.

## The four-gate stop contract (checked in this order every wake-up)

Every iteration evaluates these gates before doing any work. This is the
safety-critical core: gates 1–3 map to the three ways an autonomous loop can
misbehave — **finishing**, **stuck**, and **runaway**.

### Gate 1 — Success stop (normal exit)
- **Loop A:** every entry in `consistency-baseline.json` is `0`.
- **Loop B:** every `.ts` under `src/{composables,stores}` (excluding `*.spec.ts`) has a matching `tests/unit/**/<basename>.spec.ts`.
- Action: open **one PR** (base `main`), then **omit the next wake-up** → loop ends.
- Self-terminating: with no work left, the first step returns "0 remaining," so it
  cannot overshoot.

### Gate 2 — Blocked stop (cannot make progress)
- Trigger: **2 consecutive units** fail their verification (`check:consistency` /
  `typecheck` / `test`) and cannot be fixed within the iteration.
- Action: revert the current unit (`git checkout -- .`), open a **draft PR labeled
  `needs-human`** describing what is stuck, then omit wake-up → loop ends. No
  thrashing on a bad file.

### Gate 3 — Hard cap (circuit breaker)
- Trigger: commits on the branch reach the cap — **Loop A: 10**, **Loop B: 4**
  (both above the 9 and 2 real units, so it only trips on a malfunction).
- Action: open the PR with whatever landed, then stop. Bounds token/blast-radius
  if the loop is confused.

### Gate 4 — User interrupt
- `/loop` runs in the live session, so the user can stop it at any time. The last
  commit is already on the branch; re-running the loop resumes from git state.

### Stale-ledger self-heal
On Gate 1's success check, if a picked file already has **0 raw elements** (Loop A)
or a unit turns out already tested (Loop B), the loop treats it as done for that
unit: set its baseline entry to `0` / skip, commit the bookkeeping, and continue.
A stale ledger therefore **converges to done** instead of hanging.

## Loop A — primitive-migration sweep (lean per-component)

**Target (already enumerated):** `frontend/scripts/consistency-baseline.json` —
drive every entry to `0`.

Per iteration:
1. Ensure on branch `chore/migrate-primitives-sweep` (create off `main` if missing).
2. Read the baseline. `TARGETS` = entries with value `> 0`. If empty → **Gate 1**
   (open PR, stop).
3. Pick the entry with the **lowest** count first (cheapest win) → `FILE`.
4. In `frontend/src/<FILE>`, replace every raw `<button>/<input>/<select>` with the
   matching primitive (`BButton`/`BInput`/`BSelect`) from `src/components/primitives`,
   preserving props, `v-model`, events, and mapping hard-coded styles to tokens.
   Consult the `/design-kit` SSOT when unsure. **Do not change behavior.**
5. Set `FILE`'s baseline entry to `0`.
6. Verify: `pnpm check:consistency` (green) **and** `pnpm typecheck` **and** `pnpm test`.
   - All green → `git commit -m "chore(frontend): migrate <FILE> to primitives"`.
   - Un-fixable red → revert; count toward **Gate 2**.
7. Apply **Gate 3** cap (10).
8. Report: "migrated `<FILE>`; N entries remain." Schedule next wake-up.

**PR (Gate 1):** base `main`, title `chore(frontend): migrate raw elements to B* primitives`,
body = files migrated + gate-green confirmation.

## Loop B — test-coverage sweep (tests-first)

**Target:** untested composables/stores, fixed priority: `useToast` → `usePageMeta`
(today's only two; the detector appends any future untested unit alphabetically).

Per iteration:
1. Ensure on branch `test/coverage-composables-stores` (create off `main` if missing).
2. `UNTESTED` = `.ts` under `src/{composables,stores}` (excluding `*.spec.ts`) with **no
   matching `tests/unit/**/<basename>.spec.ts`**. If empty → **Gate 1** (open PR, stop).
3. Pick the first `UNTESTED` unit by priority → `UNIT`.
4. Write `tests/unit/<mirror>/<basename>.spec.ts` (e.g. `composables/useToast.ts` →
   `tests/unit/composables/useToast.spec.ts`), following existing Vitest patterns
   (globals `describe/it/expect`, `happy-dom`, Pinia via `setActivePinia(createPinia())`,
   `vi.useFakeTimers()`). Test **behavior, not implementation** — cover the real branches:
   - `useToast`: each tone (`info`/`success`/`error`) pushes to the toast store with the
     right tone/title/body; `dismiss(id)` delegates to the store; `duration` opt passes through.
   - `usePageMeta`: sets `document.title` + `<meta name="description">`; reacts to a `Ref`
     title change via `watchEffect`; restores the initial title/description on unmount.
5. Verify: `pnpm test` (new file passes, nothing else breaks) **and** `pnpm typecheck`.
   - Green → `git commit -m "test(frontend): cover <UNIT>"`.
   - Un-fixable red → revert; count toward **Gate 2**.
6. Apply **Gate 3** cap (4).
7. Report: "covered `<UNIT>`; N units remain." Schedule next wake-up.

**PR (Gate 1):** base `main`, title `test(frontend): cover composables + stores`,
body = files covered + `pnpm test` summary.

## Packaging

Wrap each loop's per-iteration logic in a tiny skill — mirroring the existing
`.claude/skills/consistency-loop/` idiom — so the loop invocation stays one line
and the logic is versioned/greppable:

- `.claude/skills/migrate-sweep/SKILL.md`
- `.claude/skills/coverage-step/SKILL.md`

Invocations:

```
/loop /migrate-sweep      # drains consistency-baseline.json to all-zero, opens one PR
/loop /coverage-step      # covers each untested composable/store (today: 2), opens one PR
```

Each SKILL.md encodes: the four-gate stop contract verbatim, the per-iteration
steps above, and the "one unit per wake-up, then stop or schedule next" rule.

**Deterministic target selection.** Gate 1 (the stop condition) and "pick the next
unit" must be data-driven, not LLM guesswork. Each loop calls a tiny, unit-tested
detector script (mirroring the existing `scripts/check-*.mjs` + `tests/unit/scripts/`
pattern) that prints the next target's path or `DONE`:

- `frontend/scripts/next-migration-target.mjs` — lowest-count `> 0` baseline entry, else `DONE`.
- `frontend/scripts/next-coverage-target.mjs` — highest-priority untested unit, else `DONE`.

The skill runs the script, acts on one target, and treats `DONE` as Gate 1.

## Non-goals (YAGNI)

- No auto-merge, ever — output is always a human-merged PR.
- No new cron trigger — the existing Phase 3 GitHub Actions loop is untouched.
- No blind-reviewer subagent mid-loop (that rigor stays in `/consistency-loop`).
- No page/layout story coverage in this iteration (deferred; tests-first only).

## Success criteria

- `/loop /migrate-sweep` ends with `consistency-baseline.json` all-zero and one
  green PR; `pnpm check:consistency` stays green throughout.
- `/loop /coverage-step` ends with every untested composable/store (today: the 2 units)
  having a passing `tests/unit/**/*.spec.ts` and one PR.
- Both loops demonstrably self-terminate (Gate 1) and can be interrupted/resumed
  from git state (Gate 4).
