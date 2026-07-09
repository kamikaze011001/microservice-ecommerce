# frontend

Vue 3 + Vite + TypeScript SPA. Hits the JVM stack through the gateway at `http://localhost:8080`.

## Stack

- **Vue 3** (Composition API) + **Vue Router** + **Pinia**
- **TanStack Query** (`@tanstack/vue-query`) — all server state
- **openapi-fetch** + **openapi-typescript** — typed API client generated from gateway Swagger
- **Tailwind 4** + **reka-ui** for components
- **vee-validate** + **zod** for forms
- **Vitest** + **@testing-library/vue** + **happy-dom** for unit; e2e in `tests/e2e/`
- Package manager: **pnpm 9+**, Node **20+**

## Commands

```bash
pnpm dev          # Vite dev server (typically :5173)
pnpm build        # vue-tsc -b && vite build
pnpm typecheck    # vue-tsc --noEmit
pnpm lint         # eslint .
pnpm test         # vitest run
pnpm test:watch   # vitest watch
pnpm api:gen      # regen src/api/schema.d.ts from gateway swagger
```

## Layout

- `src/api/` — generated `schema.d.ts`, hand-written `client.ts`, error helpers, query hooks in `queries/`
- `src/pages/` — route components (e.g. `CheckoutPage`, `account/OrdersPage`, `PaymentResultPage`)
- `src/components/domain/` — domain widgets; `src/components/layout/` — shells
- `src/stores/` — Pinia stores
- `src/composables/` — reusable composition functions
- `src/router/` — route table
- `tests/unit/` — mirrors `src/`; `tests/e2e/` — Playwright-style end-to-end

## Conventions

- All API calls go through `src/api/client.ts` and `src/api/queries/*.ts` — never hand-roll `fetch`.
- Endpoints use `/bff-service/v1/...` for SPA-shaped responses, `/<service>/v1/...` for direct calls. Storefront browse hits `/product-service/v1/products` (`PERMIT_ALL`).
- Wire format is **snake_case** (Java side uses `SnakeCaseStrategy`); the generated TS types reflect that — don't manually camelCase.
- Auth: gateway sets cookies / returns JWT; client sends credentials. CORS is permissive on `:5173`.

## Design system — single source of truth

The Issue Nº01 design system lives in **Storybook** (`cd frontend && pnpm storybook`).
Agents: use the project `/design-kit` skill — it reads the SSOT from source
(no server needed).

- **Tokens:** `src/styles/tokens.css`
- **Components:** `src/components/**/*.stories.ts` (+ the `.vue` beside each)
- **Foundations (rationale, Do/Don't):** `src/design-system/foundations/*.mdx`
- **Build playbook (routing/api/forms/testing/copy/a11y):** `src/design-system/guides/*.mdx`
- **Decisions:** `docs/adr/`
- **Consistency loop:** `/consistency-loop` proposes app↔Storybook consistency fixes as a
  reviewed PR (four-role agent pipeline; hard gate = `pnpm check:consistency`). See
  `docs/adr/0008-consistency-loop-agent-pipeline.md`.
- **Consistency loop automation:** `.github/workflows/frontend-consistency-loop.yml` runs
  `/consistency-loop` unattended — manual `workflow_dispatch` now, nightly cron gated. Runbook +
  how to take it hot: `frontend/docs/consistency-loop-automation.md`. See
  `docs/adr/0009-consistency-loop-unattended-trigger.md`.

Never hard-code a hex/font; reuse the `B*` primitives; `--spot` for CTAs,
`--stamp-red` for stamps only.

## After Swagger changes

Run `pnpm api:gen` to refresh `src/api/schema.d.ts`, then fix the resulting type errors — this is the canary for breaking API changes.

## Enhance loops

Three self-paced `/loop` runners live in `.claude/skills/{migrate-sweep,coverage-step,a11y-step}/`.
See `frontend/docs/enhance-loops.md` for `/loop /migrate-sweep` (primitive migration),
`/loop /coverage-step` (composable/store test coverage), and `/loop /a11y-step` (per-page axe
guards + keyboard/landmark rubric; guards are separate jsdom `vitest-axe` specs).
