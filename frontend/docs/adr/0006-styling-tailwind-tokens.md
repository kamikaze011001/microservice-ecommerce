# 0006 — Styling: Tailwind v4 + custom tokens, hand-rolled primitives

**Status:** Accepted
**Date:** 2026-05-01

## Context

The Issue Nº01 visual identity is opinionated: specific palette, specific type stack, hard-offset shadows, mechanical motion. Off-the-shelf component libraries (shadcn-vue, Naive UI, Element Plus) have generic aesthetics that we'd fight on every component. We also want speed — utilities for layout, spacing, responsive — without writing CSS for every gap.

## Decision

- **Tailwind v4** for layout, spacing, responsive utilities, colour utilities driven by token CSS vars (`@theme` block).
- **CSS custom properties** in `src/styles/tokens.css` as the single source of truth for palette, type, shadows, motion.
- **Hand-rolled primitives** (`B*` components) — no off-the-shelf component library for visuals. **Reka UI** (formerly Radix Vue) is used only for behaviour-heavy a11y primitives (Dialog, Select, Popover) — they're headless and don't fight our design.

## Alternatives considered

| Option                         | Why not                                                                                                                                                                                             |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| shadcn-vue                     | Beautiful default look, but defaults are exactly what we don't want — we'd override every Tailwind class. The component shapes don't match Issue Nº01 (badges aren't stamps, dialogs aren't paper). |
| Naive UI / Element Plus        | Heavy CSS-in-JS theming, hard to bend to risograph aesthetics.                                                                                                                                      |
| Pure CSS-Modules + no Tailwind | Slower iteration on layout/spacing.                                                                                                                                                                 |
| Vanilla Extract                | Adds a build step.                                                                                                                                                                                  |

## Consequences

- Every visual primitive is ours. Total control of feel and motion.
- Tailwind utilities cover 70 % of layout. Tokens + scoped CSS cover the brand.
- Reka UI gives us free focus traps + keyboard support for Dialog / Select / Popover.
- New colour or motion value? Add a token in `tokens.css`. Hard-coded hex outside that file is a review-block.
- Primitive count is bounded (10 — see design spec). When that list closes, no library would have served us better.
