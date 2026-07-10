# HANDOFF — microservice-ecommerce — 2026-07-10

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first — write it so anyone grasps "where we are, what's next" in 10 seconds.

## Current goal
**Nothing is mid-flight.** `main` @ `dc6403d`, clean tree, no open PRs. The last two workstreams
(frontend a11y sweep, `CLAUDE.md` restructure) both shipped.

The one real item left is a **manual keyboard/focus-ring walkthrough** — it cannot be automated
(see Next Steps #1). Offer it; don't auto-start it.

## Done (settled, do not redo)
- **`CLAUDE.md` restructure → PR #40 MERGED** (`dc6403d`). Root `CLAUDE.md` 18,704 → 14,452 chars.
  Deleted derivable sections (Project Overview, Core Architecture, Core Modules, Key Technologies,
  `mvn` commands, Key Events list). Migrated out: Image storage → `core/core-s3/CLAUDE.md`;
  Gateway CORS → `gateway/CLAUDE.md`; Mock PayPal → **new** `mock-paypal-service/CLAUDE.md`
  (+ pointer line in `payment-service/CLAUDE.md`, where `application.paypal.base-url` is flipped).
  Rationale + the keep/move test live in `decisions/0002-*` and
  `conventions/nested-claude-md-loads-only-in-scope`. **Read those before "deduplicating" more —
  the five root sections that look like duplicates are load-bearing.**
- **a11y-step sweep DONE → PRs #37 + #38 + #39 MERGED.** All app pages + `AppNav` carry jsdom
  `vitest-axe` guards + keyboard/landmark/heading rubric. Detector returns `DONE`. 263 tests green.
- Earlier in this session-chain: enhance-loop skill builds #34/#35/#36 all merged.
- Branch hygiene done: `docs/claude-md-trim` and `fix/profilepage-heading` deleted local + remote.
  (This repo squash-merges, so `git branch -d` false-negatives on merged branches — use `-D`.)
- `/doctor` run, personal machine only (**NOT repo state**, lives in the global auto-memory —
  see [[two-memory-systems-coexist]]): 2 unused plugins disabled; 46 broken gstack skill symlinks
  found and deleted; global `~/.claude/CLAUDE.md` trimmed 5,057 → 3,389 chars.

## In progress / Next steps
1. **Manual keyboard/focus-ring walkthrough (LAST a11y item).** jsdom has no layout, so visible
   focus *order* and focus *rings* were never asserted — axe in jsdom structurally cannot catch
   them. Needs a real-browser keyboard pass against `pnpm dev`, or by hand. Offer, don't auto-start.
2. **Optional loose end:** ProfilePage section-01 kicker also reads "MASTHEAD" (`<p>`, a different
   tier from the display `<h1>`) — a harmless echo. Rename only if it reads oddly in-browser.
3. **~30 stale local branches** from long-merged PRs (`frontend/phase-1..4`, `feat/b*-primitive`,
   …). Pruning them needs a content-based check, not `git branch --merged` (squash-merge again).
   Low value; do it only if asked.

## Settled decisions + rationale
- **Root `CLAUDE.md` = non-derivable + cross-cutting only.** Module specifics go in nested
  `<module>/CLAUDE.md`. But nested files load ONLY when work happens under their directory, so a
  rule binding *other* modules stays in root even when a nested file repeats it. Deliberately kept
  duplicated: Bean wiring, Repository layout, Response & paging shapes, User identity, Gateway
  routing. See `decisions/0002-*`.
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
- Manual keyboard/focus-ring pass — see Next Step #1 (real-browser only; jsdom can't assert it).
- Five never-used claude.ai connectors (Gmail, Calendar, Drive, Notion, monday.com) — can only be
  disabled on claude.ai, not from any local settings file. User's call.
