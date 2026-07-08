# Design: `/loop /a11y-step` — self-paced accessibility-hardening loop

**Date:** 2026-07-09
**Branch:** `feat/a11y-step-loop`
**Status:** Approved (design) — ready for implementation plan

## Summary

Add a **third** local, self-paced `/loop` runner to the frontend enhance-loop family
(`/migrate-sweep`, `/coverage-step`). `/loop /a11y-step` drains the **app-level
accessibility backlog** — the route pages and `AppNav` that real users hit, which are
currently un-audited — one file per wake-up, ending at **one human-merged PR**.

It closes a precise gap. `@storybook/addon-a11y` (with `parameters.a11y.test = 'error'`)
already fails the build on any accessibility violation **in Storybook stories**, and it
runs them in a real browser via `@storybook/test-runner`, so the primitives' **color
contrast** is already guarded. But:

- No `vitest-axe` / `jest-axe` / `@axe-core/*` is installed — **nothing axe-checks the
  live app**. `tests/e2e/` is empty (`.gitkeep` only).
- The app's 14 route pages + `AppNav` render to users with **zero** structural a11y
  checking (missing labels, wrong roles/ARIA, absent landmarks, heading order, duplicate
  ids, name-from-content).

That structural layer is exactly what `axe-core` catches in **happy-dom** (no browser,
no running gateway) — using the Vitest + `@testing-library/vue` infra the repo already
has. Contrast (which needs a real layout engine) stays the Storybook gate's job.

### Why this is a **Hybrid** loop, not pure-axe

Automated axe covers only ~40% of WCAG (structure/ARIA/labels/ids). The other ~60%
(keyboard reachability, focus order, accessible naming, landmark/heading structure)
needs human-style judgment. So each iteration does **both** on the same file:

1. an **objective** axe assertion driven to zero violations (the drainable spine), and
2. a fixed **rubric pass** that adds the *testable* judgment checks
   (`user.tab()` reachability, `getByRole` accessible names, single `<main>` / heading
   order) and records the non-testable observations in the PR body.

### Why pages (not each component)

`axe(container)` on a **mounted page** transitively flags violations in the page's child
domain components **and** page-only issues (landmarks, heading order, focus flow) that
isolated component tests cannot see. Primitives' contrast is already Storybook-guarded.
So **pages + `AppNav`** is the highest-leverage queue; domain/primitive components are
covered transitively.

## Why the queue is "spec has an axe guard?", not a numeric baseline

`migrate-sweep`'s `consistency-baseline.json` can hold per-file **counts** because a
regex counts raw `<button>` in *source* — no rendering. Accessibility violations only
exist once a component is **mounted with the right props + query/store mocks**, and that
mock setup lives **inside each page spec** (`tests/unit/pages/*.spec.ts` already mock the
query hooks, wire Pinia + router + `VueQueryPlugin`, and expose a `mount()` returning a
container). A standalone seeding script therefore **cannot** compute a numeric a11y
baseline without duplicating every page's mock setup.

So this loop borrows the **`coverage-step` detector shape** instead: the queue is
"which target surfaces do **not** yet have a passing axe guard in their spec" — a
source-level check, no mounting needed to *detect*. The loop drives each target to a
**passing** guard, which **is** zero violations at commit time. Same monotonic drain, no
seeding problem.

## Shared loop contract (identical to the existing two loops)

- **State lives in git, never in model memory.** Each wake-up re-inspects the repo, does
  **exactly one unit of work**, commits it, then schedules the next wake-up or stops. A
  killed session resumes from git state.
- **One file per iteration, always commit** — never batch.
- **Never touch** `tokens.css`, `check-consistency.sh`, `.storybook/*`, or CI.
- **Page-only blast radius.** The loop edits only the target `<page>.vue` and its spec.
  If a violation's true root cause is a shared `B*` primitive (e.g. `BSelect` renders
  without an accessible name), the loop **does not edit the primitive** — it either
  fixes it at the page call-site (e.g. pass `aria-label`) or, if that is impossible
  without changing the primitive's source, treats it as **Gate 2 Blocked**. Shared-
  primitive a11y fixes are a **separate design PR off `main`**, human-reviewed — the same
  rule `migrate-sweep` uses for primitive-building.
- **Human is on the loop:** every run ends at **one PR a human merges**. Never auto-merge.

## The four-gate stop contract (checked in this order every wake-up)

### Gate 1 — Success stop (normal exit)
- Every target surface (route pages with a mount spec + `AppNav`) has a **passing axe
  guard** in its spec — the detector prints `DONE`.
- Action: open **one PR** (base `main`), then **omit the next wake-up** → loop ends.
- Self-terminating: with no un-guarded target left, the detector returns `DONE` before
  any work, so it cannot overshoot.

### Gate 2 — Blocked stop (cannot make progress)
- Trigger: **2 consecutive targets** cannot be brought green within the iteration —
  either a violation is only fixable in a shared primitive (out of blast radius), or
  `pnpm test` / `pnpm typecheck` stays red.
- Action: revert the current file (`git checkout -- .`), open a **draft PR labeled
  `needs-human`** naming the blocked files and the specific violation(s) that need a
  primitive-level or human decision, then omit wake-up → loop ends.

### Gate 3 — Hard cap (circuit breaker)
- Trigger: commits on the branch reach **8** (above the ~13 real targets' worst case of
  two PRs, so it only trips on a malfunction — matching the existing loops' "cap sits
  above the real count" rule).
- Action: open the PR with whatever landed, then stop.

### Gate 4 — User interrupt
- `/loop` runs live; the user can stop anytime. The last commit is on the branch;
  re-running resumes from git state.

### Stale-detector self-heal
If a picked target already has a passing axe guard (added out-of-band), the detector
skips it on the next scan and converges to `DONE` instead of hanging.

## Per-iteration steps

1. `cd frontend`. Ensure on branch `a11y/harden-pages` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 8, open the Gate 1 PR and stop.
3. Run `node scripts/next-a11y-target.mjs`.
   - `DONE` → **Gate 1**.
   - Otherwise output is `FILE` (a page path under `src/`, e.g. `pages/CheckoutPage.vue`),
     paired with its spec `tests/unit/pages/<Base>.spec.ts`.
4. In the **spec**, add an a11y block that mounts the page's **primary loaded state**
   (reuse the spec's existing `mount()` + query-hook mocks) and asserts
   `expect(await axe(container)).toHaveNoViolations()`.
5. Run it → **fix the real violations in `src/<FILE>`** (add `<label>`/`aria-label`,
   correct roles/ARIA, wrap content in a single `<main>`, fix heading order, dedupe ids)
   until axe is clean. **Page-only blast radius** (see contract). Do **not** change
   behavior; do **not** edit primitives.
6. **Rubric pass on the same file** — add the *testable* judgment assertions to the spec:
   keyboard reachability (`await user.tab()` lands on the expected controls, no trap),
   accessible names (`getByRole('button'|'link'|'textbox', { name })`), single-`<main>` /
   heading order. Note any non-testable observation (screen-reader flow, visual focus) in
   the eventual PR body.
7. Verify — all must pass: `pnpm test` **and** `pnpm typecheck`.
   - Green → `git add -A && git commit -m "a11y(frontend): harden <FILE>"`.
   - Un-fixable within blast radius → `git checkout -- .`, count toward **Gate 2**.
8. Report: "hardened `<FILE>`; N targets remain." Let `/loop` schedule the next wake-up.

**PR (Gate 1):** base `main`, title `a11y(frontend): harden app pages`, body = files
hardened + per-file rubric notes (incl. non-testable observations) + `pnpm test` summary.

## Deterministic target selection

`frontend/scripts/next-a11y-target.mjs` (mirrors `next-coverage-target.mjs`, unit-tested
under `tests/unit/scripts/`):

- **Target set:** the route pages that have a mount spec in `tests/unit/pages/` (12
  today) **plus** `components/layout/AppNav.vue` (spec `tests/unit/components/AppNav.spec.ts`).
- **Guarded?** a target is "done" when its spec contains a passing axe guard — detected
  by a stable marker (grep for an `axe(` call / an agreed `// @a11y-guarded` sentinel the
  loop writes alongside the assertion). Prefer the sentinel so the check is unambiguous
  and cheap.
- **Order:** deterministic — highest-interaction pages first
  (`LoginPage`, `RegisterPage`, `CheckoutPage`, `CartPage`, `ProductDetailPage`,
  `account/ProfilePage`, …), then the rest alphabetically, then `AppNav`.
- Prints the next un-guarded target's `src`-relative path, else `DONE`.

## New dependency + wiring

- Add `vitest-axe` (dev). Register its matcher once in `tests/unit/setup.ts`
  (`expect.extend(matchers)` from `vitest-axe/matchers`), alongside the existing
  `@testing-library/jest-dom/vitest` import and the happy-dom pointer-capture stubs.
- No change to `.storybook/*`, `check-consistency.sh`, `frontend.yml`, or the other loops.

## Packaging

Mirror the existing enhance-loop idiom:

- `.claude/skills/a11y-step/SKILL.md` — encodes the four-gate contract verbatim, the
  per-iteration steps, the page-only blast-radius rule, and "one file per wake-up, then
  stop or schedule next."
- Update `frontend/docs/enhance-loops.md` (add the third loop) and the "Enhance loops"
  section of `frontend/CLAUDE.md`.

Invocation:

```
/loop /a11y-step      # hardens each un-guarded app page + AppNav, opens one PR
```

## Non-goals (YAGNI)

- **No numeric `a11y-baseline.json`.** The "spec has an axe guard?" detector is the queue.
- **No new cron / cloud trigger.** Purely local; the Phase-3 GitHub Actions loop is untouched.
- **No primitive edits inside this loop.** Shared-primitive a11y fixes are a separate,
  human-reviewed design PR (Gate 2 surfaces them).
- **No color-contrast checking here.** That stays the Storybook `addon-a11y` real-browser
  gate; happy-dom cannot compute it.
- **No Playwright e2e a11y pass over the running SPA.** Deferred; would need the full
  stack up and belongs to a separate e2e workstream.
- **No blind-reviewer subagent mid-loop.** That rigor stays in `/consistency-loop`.

## Success criteria

- `/loop /a11y-step` ends with every target page + `AppNav` carrying a **passing axe
  guard** in its spec, the real violations fixed in the `.vue`, and **one** green PR;
  `pnpm test` and `pnpm typecheck` stay green throughout.
- The loop demonstrably **self-terminates** (Gate 1 `DONE`) and can be
  **interrupted/resumed** from git state (Gate 4).
- A violation whose only fix lives in a shared primitive is **surfaced to a human**
  (Gate 2 draft PR), never silently patched into a foundational component by the sweep.
