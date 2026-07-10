# HANDOFF — microservice-ecommerce — 2026-07-10

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first — write it so anyone grasps "where we are, what's next" in 10 seconds.

## Current goal
**Uncommitted `CLAUDE.md` restructure sitting in the working tree, awaiting review.** A `/doctor`
run trimmed root `CLAUDE.md` and migrated module-specific sections into nested files. Nothing is
staged or committed. Next session: review `git diff`, then commit (or ask the user to).

The a11y workstream is **complete and merged** — nothing mid-flight there.

## Done (settled, do not redo)
- **`/doctor` cleanup (2026-07-10), working tree only:**
  - `CLAUDE.md` 18,704 → 14,452 chars. Deleted derivable sections (Project Overview, Core
    Architecture, Core Modules, Key Technologies, `mvn` commands, Key Events list).
  - Migrated out: Image storage → `core/core-s3/CLAUDE.md` (already there); Gateway CORS →
    `gateway/CLAUDE.md` (already there); Mock PayPal → **new** `mock-paypal-service/CLAUDE.md`.
  - `payment-service/CLAUDE.md`: +1 pointer line to the mock (that's where `application.paypal.base-url`
    is flipped; it had no mention before).
  - Rationale + the keep/move test are captured in `decisions/0002-*` and
    `conventions/nested-claude-md-loads-only-in-scope`. **Read those before "deduplicating" more.**
  - Personal-machine changes (2 unused plugins disabled; 46 broken gstack skill symlinks found)
    are NOT repo state — they live in the global auto-memory. See [[two-memory-systems-coexist]].
- **a11y-step sweep DONE → PR #37 + #38 + #39 MERGED** (`main` @ d74a679). All app pages + `AppNav`
  carry jsdom `vitest-axe` guards + keyboard/landmark/heading rubric. Detector returns `DONE`.
  263 tests green. `fix/profilepage-heading` is a stale merged branch — delete local + remote
  (squash-merge means `git branch -d` reports "not merged"; use `-D`).
- Earlier this session-chain: enhance-loop skill builds #34/#35/#36 all merged.

## In progress / Next steps
1. **Review + commit the `CLAUDE.md` restructure.** `git diff` covers `CLAUDE.md` and
   `payment-service/CLAUDE.md`; `mock-paypal-service/CLAUDE.md` is untracked. Suggested commit:
   `docs(claude-md): trim derivable content, migrate module sections to nested files`.
2. **Manual keyboard/focus-ring walkthrough (LAST a11y item):** jsdom has no layout, so visible
   focus order + focus rings were never asserted. Needs a real-browser keyboard pass against
   `pnpm dev`, or by hand. Offer, don't auto-start.
3. **Optional loose end:** ProfilePage section-01 kicker also reads "MASTHEAD" (`<p>`, different
   tier from the display `<h1>`) — harmless echo; rename only if it reads oddly in-browser.

## Settled decisions + rationale
- **Root `CLAUDE.md` = non-derivable + cross-cutting only.** Module specifics go in nested
  `<module>/CLAUDE.md`. But nested files load ONLY in scope, so a rule binding *other* modules stays
  in root even when a nested file repeats it. See `decisions/0002-*`.
- **a11y-step layout-fragment pattern:** account pages are `AccountLayout` children; the layout owns
  the sole `<main>`. Child guards use a `LAYOUT_OWNED_RULES` carve-out (`landmark-one-main`,
  `page-has-heading-one`, `region`). A child rendering its own `<main>` is a real nested-landmark bug
  the isolated guard can't see — caught by reading router nesting.
- **Layout components (AppNav) use a nav-landmark rubric**, not single-main/heading.
- **axe is a floor, not a ceiling:** `page-has-heading-one` stays quiet on a detached container, but
  `heading-order` DOES fire in jsdom. Always pair axe with role/keyboard assertions.
- **a11y-step blast radius:** never touch a `B*` primitive, `tokens.css`, `check-consistency.sh`,
  `.storybook/*`, or CI. Shared-component heading fixes are done page-side (sr-only headings).

## Context to Load (paths only, do NOT paste contents)
- `.claude/memory/decisions/0002-root-claude-md-delegates-to-nested-module-files.md` — the trim rationale
- `.claude/memory/conventions/nested-claude-md-loads-only-in-scope.md` — the keep-vs-move test
- `.claude/skills/a11y-step/SKILL.md` — the loop + four-gate stop contract
- `frontend/scripts/next-a11y-target.mjs` — detector (now returns `DONE`)
- `frontend/tests/unit/pages/account/ProfilePage.a11y.spec.ts` — LAYOUT_OWNED_RULES fragment pattern
- `frontend/tests/unit/components/AppNav.a11y.spec.ts` — nav-landmark (layout component) rubric
- `frontend/docs/enhance-loops.md` — all 3 enhance-loops documented

## Blocked / Needs user input
- Nothing blocking.

## Paused (not abandoned)
- Consistency-loop R1 headless smoke test — still NOT run (needs `ANTHROPIC_API_KEY` secret).
- Manual keyboard/focus-ring pass — see Next Step #2 (real-browser only; jsdom can't assert it).
