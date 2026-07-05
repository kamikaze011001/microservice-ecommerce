---
name: design-system
description: Use when building or reviewing any frontend UI in this repo — the single source of truth for the Issue Nº01 design system (tokens, components, build conventions). Query it from source before writing markup, choosing a color/font, adding a component, or building a form/route/API call.
---

# Design System — Issue Nº01 (Storybook SSOT)

The frontend design system lives in Storybook. You do NOT need a running server —
read the source directly.

## Where things are (all under `frontend/`)
- **Tokens (values):** `src/styles/tokens.css` — colours, type, spacing, shadows, motion.
- **Component specs:** `src/components/**/*.stories.ts` — every variant + its props/args.
- **Component source:** the `.vue` next to each story — the real `defineProps`.
- **Foundations (rationale, Do/Don't):** `src/design-system/foundations/*.mdx`.
- **Build playbook (routing/api/forms/testing/copy/a11y):** `src/design-system/guides/*.mdx`.

## How to answer a question
- *"What variants does X have?"* → read `X.stories.ts` (argTypes + named stories).
- *"What's the spot colour / a token value?"* → read `src/styles/tokens.css`.
- *"Why / Do & Don't / the identity"* → read `foundations/*.mdx`.
- *"How do I build a form / route / API call / test?"* → read `guides/*.mdx`.
- *"List everything"* → run `scripts/list-stories.sh`.

## Hard rules (enforce in any UI you write)
- Never hard-code a hex or font — use `var(--…)` or the Tailwind token utility.
- Reuse the `B*` primitives; don't hand-roll a button/input/stamp.
- Stamps for status (never badges); the shadow is hard-offset only (no blur/opacity).
- `--spot` for every CTA/focus/alert; `--stamp-red` for stamps only, never a CTA.
- To see it rendered: `cd frontend && pnpm storybook`.
