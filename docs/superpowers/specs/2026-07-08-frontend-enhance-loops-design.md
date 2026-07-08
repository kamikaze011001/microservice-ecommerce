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
- **`/loop /coverage-step`** — writes a Vitest test for each of the 5 untested
  composables/stores (`stores/auth.ts`, `stores/toast.ts`, `composables/useToast.ts`,
  `composables/usePageMeta.ts`, `composables/useDebouncedRef.ts`).

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
- **Loop B:** no `.ts` under `src/{composables,stores}` lacks a sibling `*.test.ts`.
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
- Trigger: commits on the branch reach the cap — **Loop A: 10**, **Loop B: 7**
  (both above the 9 and 5 real units, so it only trips on a malfunction).
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

**Target:** 5 untested units, fixed priority:
`stores/auth.ts` → `stores/toast.ts` → `useToast` → `usePageMeta` → `useDebouncedRef`.

Per iteration:
1. Ensure on branch `test/coverage-composables-stores` (create off `main` if missing).
2. `UNTESTED` = `.ts` under `src/{composables,stores}` with no sibling `*.test.ts`.
   If empty → **Gate 1** (open PR, stop).
3. Pick the first `UNTESTED` unit by priority → `UNIT`.
4. Write `UNIT.test.ts` beside it, following existing Vitest patterns. Test
   **behavior, not implementation** — cover the real branches:
   - `auth`: login / logout / token refresh / persistence.
   - `toast`: add / dismiss / auto-expire.
   - `useDebouncedRef`: timing with `vi.useFakeTimers()`.
5. Verify: `pnpm test` (new file passes, nothing else breaks) **and** `pnpm typecheck`.
   - Green → `git commit -m "test(frontend): cover <UNIT>"`.
   - Un-fixable red → revert; count toward **Gate 2**.
6. Apply **Gate 3** cap (7).
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
/loop /coverage-step      # covers the 5 untested composables/stores, opens one PR
```

Each SKILL.md encodes: the four-gate stop contract verbatim, the per-iteration
steps above, and the "one unit per wake-up, then stop or schedule next" rule.

## Non-goals (YAGNI)

- No auto-merge, ever — output is always a human-merged PR.
- No new cron trigger — the existing Phase 3 GitHub Actions loop is untouched.
- No blind-reviewer subagent mid-loop (that rigor stays in `/consistency-loop`).
- No page/layout story coverage in this iteration (deferred; tests-first only).

## Success criteria

- `/loop /migrate-sweep` ends with `consistency-baseline.json` all-zero and one
  green PR; `pnpm check:consistency` stays green throughout.
- `/loop /coverage-step` ends with all 5 units having a passing test file and one PR.
- Both loops demonstrably self-terminate (Gate 1) and can be interrupted/resumed
  from git state (Gate 4).
