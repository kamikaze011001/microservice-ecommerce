# Storefront Frontend

The Vue 3 + Vite + TS storefront for the aibles e-commerce backend.
Style: risograph-zine "Issue Nº01" — see [`02-design-tokens.md`](./02-design-tokens.md).
Architecture: see [`01-architecture.md`](./01-architecture.md).

## Prerequisites

- Node ≥ 20 (LTS)
- pnpm ≥ 9 (`corepack enable && corepack prepare pnpm@9 --activate`)
- Backend running locally — run `make up` from the repo root before `pnpm dev`.

## Commands

| Command           | What it does                                     |
| ----------------- | ------------------------------------------------ |
| `pnpm install`    | Install dependencies                             |
| `pnpm dev`        | Start Vite dev server on `http://localhost:5173` |
| `pnpm build`      | Production build to `dist/`                      |
| `pnpm preview`    | Serve the production build                       |
| `pnpm typecheck`  | `vue-tsc --noEmit` (TypeScript strict)           |
| `pnpm lint`       | ESLint flat config check                         |
| `pnpm lint:fix`   | ESLint auto-fix                                  |
| `pnpm format`     | Prettier write                                   |
| `pnpm test`       | Vitest unit + component tests                    |
| `pnpm test:watch` | Vitest in watch mode                             |

## Folder map

```
frontend/
├── public/fonts/             self-hosted Bricolage / Cabinet / Departure
├── src/
│   ├── api/                  openapi-fetch client + queries layer
│   ├── components/{primitives,domain}/
│   ├── composables/
│   ├── lib/                  zod schemas, formatters
│   ├── pages/
│   ├── router/
│   ├── stores/               Pinia (auth + UI only)
│   └── styles/               tokens.css, fonts.css, main.css
├── tests/{unit,e2e,fixtures}/
└── docs/                     this folder
```

## Where to look

- Adding a primitive? Read [`03-component-conventions.md`](./03-component-conventions.md).
- Adding an API call? Read [`04-api-conventions.md`](./04-api-conventions.md).
- Adding a form? Read [`05-form-conventions.md`](./05-form-conventions.md).
- Adding a route? Read [`06-routing-auth.md`](./06-routing-auth.md).
- Writing a test? Read [`07-testing-conventions.md`](./07-testing-conventions.md).
- Writing copy? Read [`08-copy-and-voice.md`](./08-copy-and-voice.md).
- Accessibility? Read [`09-a11y-checklist.md`](./09-a11y-checklist.md).
- Why we picked X? Read [`adr/`](./adr/).

## Local dev gotchas

- The dev server proxies `/api/**` → `http://localhost:8080` (gateway). The backend must be `make up`.
- If fonts 404 on first load, confirm `frontend/public/fonts/` has the four `.woff2` files (download paths in `LICENSES.md`).
- Pre-commit hook runs `lint-staged` + `typecheck` on staged files. It will block bad commits.
- Vault-sealed backend = 503 on first API call. Re-run `make up`.
