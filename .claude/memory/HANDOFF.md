# HANDOFF — microservice-ecommerce — 2026-07-10

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first — write it so anyone grasps "where we are, what's next" in 10 seconds.

## Current goal
First `/loop /a11y-step` **run** (page-hardening, distinct from the skill *build* PR #34) shipped
and **merged as PR #37**. Nothing mid-flight — the next session starts fresh from `main`.

## Done (settled, do not redo)
- **`/loop /a11y-step` run → PR #37 MERGED** (branch `a11y/harden-pages`, now on `main` @ e15fa3b).
  8 pages hardened with jsdom `vitest-axe` guards + keyboard/landmark/heading rubric: RegisterPage,
  CheckoutPage, CartPage, ProductDetailPage, account/ProfilePage, account/OrdersPage,
  account/OrderDetailPage, PaymentResultPage. 249 tests + typecheck green. Loop stopped at **Gate 3
  (hard cap = 8 commits)** — NOT DONE; detector still lists remaining pages (next: `pages/ActivatePage.vue`).
- **4 real fixes** (all page-only, zero visual change): (1) `account/OrdersPage` + (2) `account/OrderDetailPage`
  each rendered their **own `<main>`**, nesting a duplicate landmark inside `AccountLayout`'s main → both → `<div>`
  fragments (scoped CSS keys off the class); (3) `ProfilePage` 4th section got `aria-label="Sessions"`;
  (4) `PaymentResultPage` paid/success state had **no heading at all** → added `<h1>PAYMENT CONFIRMED</h1>`.
- Earlier this session-chain: enhance-loop skill builds #34/#35/#36 all merged.

## In progress / Next steps
1. **Continue the a11y sweep:** re-run `/loop /a11y-step` from `main` → resumes at `pages/ActivatePage.vue`,
   hardens up to 8 more pages, then Gate-3 PR again. (Cap is a deliberate human checkpoint, not "done".)
2. **Pair with a layout a11y pass (separate PR):** `AccountLayout`'s masthead is a `<p class="account__kicker">`,
   NOT an `<h1>` — a real layout-level heading gap. The 3 account child guards scope around it
   (`page-has-heading-one` disabled in `LAYOUT_OWNED_RULES`). Outside the loop's page-only blast radius,
   so it needs its own human-reviewed change — don't let the loop touch it.

## Settled decisions + rationale
- **a11y-step layout-fragment pattern:** account pages are `AccountLayout` children; the layout owns the sole
  `<main>`. Child page guards use a documented `LAYOUT_OWNED_RULES` carve-out (`landmark-one-main`,
  `page-has-heading-one`, `region`) because the fragment's loose top-level content is only wrapped by the
  layout's `<main>` in the composed app. A child rendering its own `<main>` is a real nested-landmark bug the
  isolated guard can't see — caught by reading router nesting. Top-level pages (e.g. PaymentResultPage) keep
  the standard single-main/heading rubric.
- **axe is a floor, not a ceiling:** `page-has-heading-one` stays quiet on a detached container, so a
  headingless state can pass `axe()` yet fail the rubric's explicit `getByRole('heading', {level:1})`. Always
  pair axe with role/keyboard assertions.
- **a11y-step:** jsdom pin = insurance, not a hard axe requirement. See convention
  `a11y-guards-jsdom-pin-is-insurance`. Page-only blast radius: never touch a `B*` primitive, `tokens.css`,
  `check-consistency.sh`, `.storybook/*`, or CI.

## Context to Load (paths only, do NOT paste contents)
- `.claude/skills/a11y-step/SKILL.md` — the loop + four-gate stop contract
- `frontend/scripts/next-a11y-target.mjs` — detector (prints next page or `DONE`)
- `frontend/tests/unit/pages/account/ProfilePage.a11y.spec.ts` — reference for the LAYOUT_OWNED_RULES fragment pattern
- `frontend/tests/unit/pages/PaymentResultPage.a11y.spec.ts` — reference for the standard top-level-page rubric
- `.claude/memory/conventions/a11y-guards-jsdom-pin-is-insurance.md` — a11y toolchain rationale
- `frontend/docs/enhance-loops.md` — all 3 enhance-loops documented

## Blocked / Needs user input
- Nothing blocking.

## Paused (not abandoned)
- Consistency-loop R1 headless smoke test — still NOT run (needs `ANTHROPIC_API_KEY` secret).
- `AccountLayout` `<h1>` heading gap — see Next Step 2 (layout-level, separate PR).
