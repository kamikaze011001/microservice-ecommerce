# HANDOFF — microservice-ecommerce — 2026-07-10

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first — write it so anyone grasps "where we are, what's next" in 10 seconds.

## Current goal
The per-page a11y-step sweep is **COMPLETE and merged** (PR #37 + PR #38). Detector prints `DONE`
— every page and the nav shell has an axe guard + rubric. Nothing mid-flight; next session starts
from `main` @ 6ab25f7. Remaining a11y work is layout-level (outside the loop) — see Next Steps.

## Done (settled, do not redo)
- **a11y-step sweep DONE → PR #37 + PR #38 MERGED** (`main` @ 6ab25f7). All app pages + `AppNav`
  now carry jsdom `vitest-axe` guards + keyboard/landmark/heading rubric. Detector returns `DONE`.
  - **#37** (branch `a11y/harden-pages`, 8 pages, Gate 3 hard-cap stop): RegisterPage, CheckoutPage,
    CartPage, ProductDetailPage, account/ProfilePage, account/OrdersPage, account/OrderDetailPage,
    PaymentResultPage. 4 real fixes: 2× nested-`<main>`→`<div>` (Orders/OrderDetail), ProfilePage
    `aria-label="Sessions"`, PaymentResultPage added `<h1>PAYMENT CONFIRMED</h1>`.
  - **#38** (branch `a11y/harden-pages-2`, 4 targets, Gate 1 `DONE` stop): ActivatePage,
    ForgotPasswordPage, HomePage, components/layout/AppNav. 1 real fix: HomePage `heading-order`
    (hero h1 → ProductCard h3 skip) fixed page-only via sr-only `<h2>` "Spotlight"/"Catalog" +
    `aria-labelledby` on the sections (scoped `.home__section-label`, zero visual change). 262 tests green.
- **Branch cleanup:** both `a11y/harden-pages` and `a11y/harden-pages-2` (local + remote) are stale
  post-merge — delete them (squash-merge means `git branch -d` reports "not merged"; use `-D`).
- Earlier this session-chain: enhance-loop skill builds #34/#35/#36 all merged.

## In progress / Next steps
1. **Layout a11y pass (separate PR, NOT the loop):** `AccountLayout`'s masthead is a
   `<p class="account__kicker">`, NOT an `<h1>` — a real layout-level heading gap. The 3 account
   child guards scope around it (`page-has-heading-one` in `LAYOUT_OWNED_RULES`). Outside the loop's
   page-only blast radius → needs its own human-reviewed change.
2. **Manual keyboard/focus-ring walkthrough:** jsdom has no layout, so visible focus order + focus
   rings were never asserted by the guards. Worth a real-browser keyboard pass.

## Settled decisions + rationale
- **a11y-step layout-fragment pattern:** account pages are `AccountLayout` children; the layout owns the sole
  `<main>`. Child page guards use a documented `LAYOUT_OWNED_RULES` carve-out (`landmark-one-main`,
  `page-has-heading-one`, `region`) because the fragment's loose top-level content is only wrapped by the
  layout's `<main>` in the composed app. A child rendering its own `<main>` is a real nested-landmark bug the
  isolated guard can't see — caught by reading router nesting. Top-level pages keep the standard rubric.
- **Layout components (AppNav) use a nav-landmark rubric, not single-main/heading:** AppNav owns the `<nav>`,
  not a `<main>`/`<h1>`, so its guard asserts a single nav landmark + toggle ARIA + reachable named actions
  instead. Passed with zero fixes — the hamburger's aria-label/expanded/controls live on `BIconButton`
  (payoff of the migrate-sweep primitive discipline).
- **axe is a floor, not a ceiling:** `page-has-heading-one` stays quiet on a detached container, but
  `heading-order` DOES fire in jsdom (caught HomePage's h1→h3 skip). Always pair axe with role/keyboard
  assertions — a per-element linter can't see a heading-tree skip.
- **a11y-step:** jsdom pin = insurance, not a hard axe requirement. See convention
  `a11y-guards-jsdom-pin-is-insurance`. Page-only blast radius: never touch a `B*` primitive, `tokens.css`,
  `check-consistency.sh`, `.storybook/*`, or CI. Shared-component heading fixes (e.g. ProductCard h3) are
  done page-side (sr-only headings), never in the shared component.

## Context to Load (paths only, do NOT paste contents)
- `.claude/skills/a11y-step/SKILL.md` — the loop + four-gate stop contract
- `frontend/scripts/next-a11y-target.mjs` — detector (prints next page or `DONE`; now returns `DONE`)
- `frontend/tests/unit/pages/account/ProfilePage.a11y.spec.ts` — reference for the LAYOUT_OWNED_RULES fragment pattern
- `frontend/tests/unit/pages/PaymentResultPage.a11y.spec.ts` — reference for the standard top-level-page rubric
- `frontend/tests/unit/components/AppNav.a11y.spec.ts` — reference for the nav-landmark (layout component) rubric
- `.claude/memory/conventions/a11y-guards-jsdom-pin-is-insurance.md` — a11y toolchain rationale
- `frontend/docs/enhance-loops.md` — all 3 enhance-loops documented

## Blocked / Needs user input
- Nothing blocking.

## Paused (not abandoned)
- Consistency-loop R1 headless smoke test — still NOT run (needs `ANTHROPIC_API_KEY` secret).
- `AccountLayout` `<h1>` heading gap + manual focus-ring pass — see Next Steps 1 & 2 (layout-level, separate PRs).
