# Design System SSOT — Storybook consolidation

**Date:** 2026-07-05
**Branch:** `feat/design-system-storybook`
**Status:** Approved design — ready for implementation planning

## Problem

The frontend already has a strong, distinctive visual identity — **"Issue Nº01"** (risograph-zine / neo-brutalist: warm paper, riso-orange spot, hard-offset shadows, `steps(2)` mechanical motion, signature details like stamps / misregistration / cropmarks / sticker rotation / paper grain). But its documentation is **fragmented across ten files** (`frontend/docs/00-09`) plus `frontend/src/styles/tokens.css`, and none of it is rendered, interactive, or easy for an AI agent to query. The scattered prose drifts from the code, and a human can't *see* the components without reading the app.

We want **one source of truth** that is friendly to both humans and AI agents, without inventing a new aesthetic and without re-skinning the built app.

## Goal

Consolidate the design system into **Storybook** as the single content home, keep `tokens.css` as the machine token source, and add a **project-scoped skill** that lets AI agents query the system from source. Retire the fragmented `docs/00-09`.

## Non-goals

- **No new aesthetic.** Issue Nº01 stays exactly as-is.
- **No app re-skin.** Existing components/pages are unchanged. This project documents them; it does not restyle them.
- **No MCP server.** Agents query via a repo-local skill reading source files, not a running MCP process.
- **No hosted platform** (zeroheight / Supernova / Backlight). Overkill for a small team.
- **No token-format migration** (e.g. to DTCG JSON). `tokens.css` remains the value source; revisit later if desired.

## Current state (inventory)

- **Primitives** (`frontend/src/components/primitives/`): `BButton`, `BCard`, `BCropmarks`, `BDialog`, `BInput`, `BMarginNumeral`, `BSelect`, `BStamp`, `BTag`, `BToast`, `ToastViewport` (+ `index.ts`).
- **Domain / patterns** (`frontend/src/components/domain/`, `layout/`, root): `OrderStatusStamp`, `CartLineItem`, `CartSummary`, `OrderItemRow`, `OrderReceiptRow`, `AddressForm`, `ProductCard`, `BImageFallback`, `AppNav`.
- **Styles** (`frontend/src/styles/`): `tokens.css` (token SSOT), `fonts.css`, `main.css` (incl. paper-grain overlay).
- **Docs to migrate** (`frontend/docs/`): `00-readme`, `01-architecture`, `02-design-tokens`, `03-component-conventions`, `04-api-conventions`, `05-form-conventions`, `06-routing-auth`, `07-testing-conventions`, `08-copy-and-voice`, `09-a11y-checklist`, `adr/`.
- **Stack:** Vue 3 (Composition API) + Vite + TS, Tailwind 4, reka-ui, vee-validate + zod, Vitest, pnpm 9, Node 20. No Storybook installed yet.

## Target architecture

Three layers plus one query doorway. **Storybook is the only documentation content home.**

| Layer | Audience | Lives in | Role |
|---|---|---|---|
| **Storybook** (rendered site + source) | Humans (rendered) + agents (source) | `frontend/.storybook/`, `*.stories.ts`, foundations & guides `*.mdx` | The single content SSOT |
| **`tokens.css`** | Machine / code | `frontend/src/styles/tokens.css` | Token *values*; Foundations render *from* it, so they can't drift |
| **`/design-system` skill** | AI agents | `.claude/skills/design-system/` (project-scoped, committed) | Pointer/procedure to query the Storybook source. No content of its own. |

Key property: **humans read rendered Storybook; agents read the same Storybook source files** (`.stories.ts` + `.mdx`) and `tokens.css` via the skill. One tree, one truth, no sync burden.

### Storybook content structure

- **Foundations** (`.mdx`, rendered live from `tokens.css`):
  `Identity` (the Issue Nº01 story + hard rules) · `Color` · `Typography` · `Spacing` · `Borders & Shadows` · `Motion` · `Signature Details` (stamps, misregistration, cropmarks, sticker rotation, paper grain — shown running).
- **Primitives** — one `*.stories.ts` per `B*` component: every variant + interactive controls (args/argTypes) + a short Do/Don't autodocs block.
- **Patterns** — stories for domain components (`OrderStatusStamp`, `ProductCard`, cart rows, `AddressForm`, etc.).
- **Guides** (`.mdx`) — the build playbook, migrated from `docs/00-09`: architecture, routing/auth, API conventions, form conventions, testing conventions, copy & voice, a11y checklist.

Story files co-locate next to components (`X.vue` → `X.stories.ts`), per Vue/Storybook convention. Foundations/Guides `.mdx` live under `frontend/.storybook/` (or a `frontend/src/design-system/` docs folder — decided in the plan).

### The `/design-system` skill

A project-scoped skill (`.claude/skills/design-system/SKILL.md` + optional helper script) that teaches an agent how to answer design/build questions **from source, without a running server**:

- *Component question* → read its `*.stories.ts` (variants/args) + the `.vue` source.
- *Token / value question* → read `frontend/src/styles/tokens.css`.
- *Rationale / "why" / Do-Don't* → read the foundations `.mdx`.
- *"How do I build a form / route / API call / test"* → read the guides `.mdx`.
- *Optional helper:* parse `frontend/storybook-static/index.json` to enumerate all stories **only if a build exists**; otherwise read source directly (no build dependency).

The skill is committed with the repo so it travels with the code and applies only to this project.

## Migration & cleanup

1. Stand up Storybook in `frontend/` (`@storybook/vue3-vite`), Tailwind-aware preview importing `tokens.css` / `fonts.css` / `main.css` so stories render in the real identity.
2. Author Foundations `.mdx` from `02-design-tokens.md` (+ visual bits of `08`, `09`), rendering from `tokens.css`.
3. Write `*.stories.ts` for all primitives, then domain/pattern components.
4. Author Guides `.mdx` from `01`, `04`, `05`, `06`, `07`, `08`, `09`.
5. Retire `frontend/docs/00-09` once content is absorbed (keep `adr/` — decisions are still valuable history; the plan decides whether ADRs move into Storybook Guides or stay).
6. Rewrite `frontend/CLAUDE.md` to point at Storybook as the SSOT and reference the `/design-system` skill.
7. Add `pnpm storybook` / `pnpm build-storybook` scripts.

## What does NOT change

- `tokens.css`, `fonts.css`, `main.css` values and the visual identity.
- Any component's markup, styles, or behavior.
- App routing, API layer, forms, or tests.

## Success criteria

- `pnpm storybook` renders Foundations + every primitive + patterns + Guides in the Issue Nº01 identity.
- Every `B*` primitive has a story covering its variants/states.
- The build playbook (former `docs/01,04–09`) is fully represented in Guides — nothing lost.
- An agent, given only the `/design-system` skill, can answer: "what variants does `BButton` have?", "what's the spot color hex?", "how do I add a validated form?", "what does `BStamp` look like?" — by reading source.
- `docs/00-09` removed; `frontend/CLAUDE.md` points at the new SSOT.
- `pnpm typecheck` / `pnpm lint` / `pnpm test` still pass.

## Open questions (resolve during planning)

- Exact home for Foundations/Guides `.mdx` (`.storybook/` vs `src/design-system/`).
- Storybook 9 addon set (docs, a11y, interactions/vitest addon) and whether to wire the Storybook Vitest addon given the existing Vitest setup.
- Fate of `docs/adr/` (absorb vs keep).
- Whether the skill ships a helper script now or starts as pure procedure.
