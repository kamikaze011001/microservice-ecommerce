---
name: coverage-step
description: >
  Use to run ONE iteration of the test-coverage sweep, then self-pace via /loop. Picks the next
  untested composable/store, writes a behavior-focused Vitest spec under tests/unit/, verifies,
  and commits. Ends at one human-merged PR. Trigger phrases: "/coverage-step", "coverage sweep",
  "/loop /coverage-step".
---

# coverage-step — one iteration of the test-coverage loop

**Announce at start:** "Running one coverage-step iteration."

Runs as `/loop /coverage-step` (no interval → self-paced). Durable state lives in git and the
test tree — a killed session resumes from there. The only in-session state is a transient
blocked-unit counter (Gate 2), tracked across this run's wake-ups and reset safely on restart.
Write EXACTLY ONE spec per invocation, commit it, then stop or let /loop schedule the next wake-up.

## Four-gate stop contract (check in order, every invocation)
1. **Success stop** — the detector prints `DONE`. If the branch has commits, open the PR
   (below) and STOP: do NOT schedule another wake-up. If it has none, report "everything is
   covered" and STOP.
2. **Blocked stop** — track a blocked-unit counter across this run's wake-ups; if 2 units in a
   row fail verification and cannot be fixed in-iteration, open the escape-hatch draft PR
   (below) and STOP. The counter is in-run only — a restart resets it, which is safe.
3. **Hard cap** — if `git rev-list --count main..HEAD` >= 4, open the PR and STOP. This gate is
   wired as step 2 of the iteration below so it fires before any new work.
4. **User interrupt** — the user may stop /loop anytime; the last commit is safe; re-running
   resumes from git state.

## The iteration
1. `cd frontend`. Ensure on branch `test/coverage-composables-stores` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 4, open the Gate 1 PR and STOP
   before doing any work.
3. Run `node scripts/next-coverage-target.mjs`.
   - `DONE` → Gate 1.
   - Otherwise the output is `UNIT` (path relative to `src`, e.g. `composables/useToast.ts`).
4. Write `tests/unit/<mirror>/<basename>.spec.ts` (mirror `UNIT`'s dir, e.g.
   `composables/useToast.ts` → `tests/unit/composables/useToast.spec.ts`). Follow the existing
   patterns: Vitest globals (`describe/it/expect`), `happy-dom`, Pinia via
   `setActivePinia(createPinia())` for store-backed units, `vi.useFakeTimers()` for timers.
   Read `UNIT` and cover its real BEHAVIOR branches, not implementation details.
5. Verify — both must pass: `pnpm test` (the new spec passes, nothing else breaks) && `pnpm typecheck`.
   - Green → `git add -A && git commit -m "test(frontend): cover <UNIT>"`.
   - Un-fixable red → `git checkout -- .` and count this as a blocked unit (Gate 2 on the 2nd).
6. Report: "covered `<UNIT>`; run the detector to see remaining." Let /loop schedule the next wake-up.

## Gate 1 PR
```bash
git push -u origin HEAD
gh pr create --base main --title "test(frontend): cover composables + stores" \
  --body "Adds Vitest specs for previously untested composables/stores: <list>. pnpm test green."
```

## Gate 2 escape hatch
```bash
git add -A && git commit --allow-empty -m "wip(frontend): coverage-step blocked — needs human"
git push -u origin HEAD
gh pr create --draft --base main --title "wip: coverage-step needs human" \
  --body "<blocked units + the failing test/typecheck output>"
gh pr edit --add-label needs-human
```

## Hard rules
- ONE spec per invocation. Never batch.
- Test behavior, not implementation. Never edit the source unit to make a test pass.
- Never auto-merge. Output is always a PR a human merges.
