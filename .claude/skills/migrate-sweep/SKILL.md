---
name: migrate-sweep
description: >
  Use to run ONE iteration of the primitive-migration sweep, then self-pace via /loop. Picks
  the lowest-count file in consistency-baseline.json, migrates its raw <button>/<input>/<select>
  to B* primitives, drives that baseline entry to 0, verifies the gate, and commits. Ends at one
  human-merged PR. Trigger phrases: "/migrate-sweep", "migration sweep", "/loop /migrate-sweep".
---

# migrate-sweep — one iteration of the primitive-migration loop

**Announce at start:** "Running one migrate-sweep iteration."

Runs as `/loop /migrate-sweep` (no interval → self-paced). Durable state lives in git and
`frontend/scripts/consistency-baseline.json` — a killed session resumes from there. The only
in-session state is a transient blocked-file counter (Gate 2), tracked across this run's
wake-ups and reset safely on restart. Do EXACTLY ONE file per invocation, commit it, then stop
or let /loop schedule the next wake-up.

## Four-gate stop contract (check in order, every invocation)
1. **Success stop** — the detector prints `DONE`. If the branch has commits, open the PR
   (below) and STOP: do NOT schedule another wake-up. If it has none, report "nothing to
   migrate" and STOP.
2. **Blocked stop** — track a blocked-file counter across this run's wake-ups; if 2 files in a
   row fail verification and cannot be fixed in-iteration, open the escape-hatch draft PR
   (below) and STOP. The counter is in-run only — a restart resets it, which is safe.
3. **Hard cap** — if `git rev-list --count main..HEAD` >= 10, open the PR and STOP. This gate is
   wired as step 2 of the iteration below so it fires before any new work.
4. **User interrupt** — the user may stop /loop anytime; the last commit is safe; re-running
   resumes from git state.

## The iteration
1. `cd frontend`. Ensure on branch `chore/migrate-primitives-sweep` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 10, open the Gate 1 PR and STOP
   before doing any work.
3. Run `node scripts/next-migration-target.mjs`.
   - `DONE` → Gate 1.
   - Otherwise the output is `FILE` (path relative to `src`).
4. Edit `src/<FILE>`: replace every raw `<button>`/`<input>`/`<select>` with the matching
   primitive (`BButton`/`BInput`/`BSelect`) from `src/components/primitives`, preserving props,
   `v-model`, `@events`, and mapping any inline hex/spacing to design tokens. Invoke `/design-kit`
   if unsure of the primitive's API. Do NOT change behavior.
5. In `scripts/consistency-baseline.json`, set `FILE`'s entry to `0`.
6. Verify — all three must pass: `pnpm check:consistency` && `pnpm typecheck` && `pnpm test`.
   - All green → `git add -A && git commit -m "chore(frontend): migrate <FILE> to primitives"`.
   - Un-fixable red → `git checkout -- .` and count this as a blocked file (Gate 2 on the 2nd).
7. Report: "migrated `<FILE>`; run the detector to see remaining." Let /loop schedule the next wake-up.

## Gate 1 PR
```bash
git push -u origin HEAD
gh pr create --base main --title "chore(frontend): migrate raw elements to B* primitives" \
  --body "Drains consistency-baseline.json to all-zero. Files migrated: <list>. Gate green."
```

## Gate 2 escape hatch
```bash
git add -A && git commit --allow-empty -m "wip(frontend): migrate-sweep blocked — needs human"
git push -u origin HEAD
gh pr create --draft --base main --title "wip: migrate-sweep needs human" \
  --body "<blocked files + the failing gate/typecheck/test output>"
gh pr edit --add-label needs-human
```

## Hard rules
- ONE file per invocation. Never batch.
- Never touch `tokens.css`, `check-consistency.sh`, CI, or component behavior.
- Never auto-merge. Output is always a PR a human merges.
