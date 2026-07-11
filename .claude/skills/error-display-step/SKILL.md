---
name: error-display-step
description: >
  Use to run ONE iteration of the frontend error-display sweep, then self-pace via /loop.
  Picks the next page that discards caught errors, rewrites it to surface real backend
  messages + field errors via useApiError, verifies (pnpm test + typecheck), and commits.
  Ends at one human-merged PR. Trigger: "/error-display-step", "/loop /error-display-step".
---

# error-display-step — one iteration of the frontend error-display loop

**Announce at start:** "Running one error-display-step iteration."

Runs as `/loop /error-display-step` after the backend catalog PR merges. ONE page per
invocation. Durable state is git + the page tree; only in-session state is a blocked-page
counter (Gate 2).

## Four-gate stop contract
1. **Success** — `node scripts/next-error-display-target.mjs` prints `DONE` → open PR, STOP.
2. **Blocked** — 2 pages in a row un-fixable (test/typecheck stays red) → draft needs-human PR.
3. **Hard cap** — `git rev-list --count main..HEAD` >= 8 → open PR, STOP.
4. **User interrupt** — last commit safe; rerun resumes.

## The iteration
1. `cd frontend`. Ensure on branch `chore/error-display-sweep` (create off `main` if missing).
2. Gate 3 check (>= 8 commits → PR + STOP).
3. `node scripts/next-error-display-target.mjs`. `DONE` → Gate 1. Else output is `<page>.vue`.
4. Rewrite that page's error handling:
   - Replace bare `catch {}` / error-discarding catches with `catch (e) { ... }`.
   - Use `useApiError()`: `notify(e)` for toasts (surfaces the real backend `message`),
     `fieldErrors(e)` → vee-validate `setErrors(...)` for forms.
   - Switch on `e.code` only where the page needs custom UI (e.g. `INVALID_CREDENTIALS`).
   - Replace SHOUTY hardcoded strings (`'ORDER NOT CREATED — TRY AGAIN'`) with `notify(e, '<fallback>')`.
5. **Verify:** `pnpm test && pnpm typecheck`. Green → commit (Co-Authored-By). Red → `git checkout -- .` (Gate 2).
6. Report; let /loop schedule the next wake-up.

## Gate 1 / Gate 2 PRs — same pattern as a11y-step (base main, needs-human label on the draft).

## Hard rules
- ONE page per invocation. Never batch. Never touch a `B*` primitive, `tokens.css`, or CI.
- Never auto-merge.
