---
name: a11y-step
description: >
  Use to run ONE iteration of the accessibility-hardening sweep, then self-pace via /loop.
  Picks the next app page (or AppNav) lacking an axe guard, writes a jsdom vitest-axe spec
  under tests/unit/, fixes real violations page-only, verifies, and commits. Ends at one
  human-merged PR. Trigger phrases: "/a11y-step", "a11y sweep", "/loop /a11y-step".
---

# a11y-step — one iteration of the accessibility-hardening loop

**Announce at start:** "Running one a11y-step iteration."

Runs as `/loop /a11y-step` (no interval → self-paced). Durable state lives in git and the
test tree — a killed session resumes from there. The only in-session state is a transient
blocked-file counter (Gate 2), tracked across this run's wake-ups and reset safely on restart.
Harden EXACTLY ONE target per invocation, commit it, then stop or let /loop schedule the next wake-up.

## Why a separate jsdom spec file
Each guard is a **separate** file `tests/unit/<mirror>/<Base>.a11y.spec.ts` whose **first line**
is `// @vitest-environment jsdom`. The docblock pins axe to jsdom — axe-core's reference DOM — so
its results are deterministic regardless of the repo's global `happy-dom` env. (Older happy-dom
had a `Node.prototype.isConnected` bug that made axe skip rules → silent false pass; it is **fixed
in the pinned happy-dom v15**, where axe runs fine — verified empirically, so the jsdom pin is
defense-in-depth against a downgrade/regression, not a hard requirement.) The separate file also
keeps a11y guards distinct from behavior specs, lets the detector find them by name, and never
touches the ~13 existing happy-dom specs. Reference example: `tests/unit/pages/LoginPage.a11y.spec.ts`.

## Four-gate stop contract (check in order, every invocation)
1. **Success stop** — the detector prints `DONE`. If the branch has commits, open the PR
   (below) and STOP: do NOT schedule another wake-up. If it has none, report "every page is
   guarded" and STOP.
2. **Blocked stop** — track a blocked-file counter across this run's wake-ups; if 2 targets in a
   row cannot be brought green in-iteration (violation only fixable in a shared primitive, or
   test/typecheck stays red), open the escape-hatch draft PR (below) and STOP. The counter is
   in-run only — a restart resets it, which is safe.
3. **Hard cap** — if `git rev-list --count main..HEAD` >= 8, open the PR and STOP. This gate is
   wired as step 2 of the iteration below so it fires before any new work.
4. **User interrupt** — the user may stop /loop anytime; the last commit is safe; re-running
   resumes from git state.

## The iteration
1. `cd frontend`. Ensure on branch `a11y/harden-pages` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 8, open the Gate 1 PR and STOP
   before doing any work.
3. Run `node scripts/next-a11y-target.mjs`.
   - `DONE` → Gate 1.
   - Otherwise the output is `FILE` (a page path relative to `src`, e.g. `pages/CheckoutPage.vue`,
     or `components/layout/AppNav.vue`).
4. Create `tests/unit/<mirror>/<Base>.a11y.spec.ts` (pages → `tests/unit/pages/`, AppNav →
   `tests/unit/components/`). **First line must be** `// @vitest-environment jsdom`. Copy the
   sibling mount spec's provider setup + query-hook `vi.mock`s (Pinia via
   `setActivePinia(createPinia())`, router, `VueQueryPlugin`), mount the page's primary loaded
   state, and assert `expect(await axe(container)).toHaveNoViolations()` (axe is async).
5. Run it → **fix real violations in `src/<FILE>` only** (missing label/`aria-label`, wrong
   role/ARIA, no `<main>`, heading order, duplicate ids). **Page-only blast radius**: if the
   only fix is in a shared `B*` primitive, do NOT edit the primitive — fix at the page call-site
   if possible, else count this as a blocked file (Gate 2). Do NOT change behavior.
6. **Rubric pass** — add the testable judgment assertions to the same a11y spec: keyboard
   reachability (`await user.tab()` lands on the expected control, no trap), accessible names
   (`getByRole('button'|'link'|'textbox', { name })`), single `<main>` / heading order. Note any
   non-testable observation (screen-reader flow, visible focus) for the PR body.
7. Verify — both must pass: `pnpm test` && `pnpm typecheck`.
   - Green → `git add -A && git commit -m "a11y(frontend): harden <FILE>"` (with the Co-Authored-By trailer).
   - Un-fixable within blast radius → `git checkout -- .` and count this as a blocked file (Gate 2 on the 2nd).
8. Report: "hardened `<FILE>`; run the detector to see remaining." Let /loop schedule the next wake-up.

## Gate 1 PR
```bash
git push -u origin HEAD
gh pr create --base main --title "a11y(frontend): harden app pages" \
  --body "Adds passing axe guards + rubric checks to app pages/AppNav: <list>. Real violations fixed page-only. Per-file rubric notes: <notes>. pnpm test green."
```

## Gate 2 escape hatch
```bash
git add -A && git commit --allow-empty -m "wip(frontend): a11y-step blocked — needs human"
git push -u origin HEAD
gh pr create --draft --base main --title "wip: a11y-step needs human" \
  --body "<blocked files + the specific violation(s) needing a primitive-level or human decision>"
gh pr edit --add-label needs-human
```

## Hard rules
- ONE target per invocation. Never batch.
- Every a11y spec's first line is `// @vitest-environment jsdom`. No exceptions.
- Page-only blast radius — never edit a `B*` primitive inside this loop. Shared-primitive a11y
  fixes are a separate, human-reviewed design PR (Gate 2 surfaces them).
- Never touch `tokens.css`, `check-consistency.sh`, `.storybook/*`, CI, or component behavior.
- Never auto-merge. Output is always a PR a human merges.
