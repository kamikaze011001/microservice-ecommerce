# Architecture

## Stack at a glance

| Concern       | Pick                                                             |
| ------------- | ---------------------------------------------------------------- |
| Framework     | Vue 3 (Composition API) + Vite + TS strict                       |
| Server state  | TanStack Vue Query                                               |
| Client state  | Pinia (auth + UI only — never server data)                       |
| API client    | `openapi-typescript` (codegen) + `openapi-fetch` (~3 kB runtime) |
| Forms         | VeeValidate + Zod (schemas reused for runtime API parsing)       |
| Routing       | Vue Router 4 + route guards                                      |
| Styling       | Tailwind v4 + custom tokens, hand-rolled primitives              |
| Headless a11y | Reka UI (Dialog, Select, Popover)                                |
| Tests         | Vitest + @testing-library/vue + MSW + Playwright                 |

Decision rationale lives in [`adr/`](./adr/).

## Folder structure

```
frontend/src/
├── api/
│   ├── schema.d.ts           # generated from gateway /v3/api-docs (Phase 3)
│   ├── client.ts             # openapi-fetch + auth interceptor
│   └── queries/              # vue-query wrappers per resource
├── components/
│   ├── primitives/           # B*: BButton, BCard, BInput, BStamp, ...
│   └── domain/               # ProductCard, CartLineItem, OrderRow, ...
├── composables/              # useAuth, useToast, useTelemetry, ...
├── pages/
├── router/
├── stores/                   # Pinia: auth + ui only
├── styles/                   # tokens.css, fonts.css, main.css
└── lib/                      # zod-schemas.ts, format.ts
```

## Layer boundaries

Three boundaries are strict. Violating them is a review-block.

### 1. The API boundary lives in `src/api/queries/`

- **No component, page, or composable calls `client.GET / .POST` directly.**
- Components consume `useProductsQuery()`, `useAddToCartMutation()`, etc. — exported only from `src/api/queries/`.
- Why: centralizes cache keys, error mapping, retry policy, invalidation rules. If the API changes, edits stay in one place.

### 2. Primitives know nothing about the API

- `src/components/primitives/B*` are styling-only. Props in, slots/emits out.
- They never import from `@/api`, `@/stores`, `@/composables/useAuth`.
- Why: primitives are reusable across pages and testable in isolation.

### 3. Zod schemas are the single source of truth for shape

- Every input shape and every API response shape is defined in `src/lib/zod-schemas.ts`.
- The same schema validates a form (via VeeValidate's `toTypedSchema`) and parses an API response in `src/api/queries/`.
- Why: drift between FE types and backend shapes fails fast, in one file.

## Data flow

```
User input
   ↓
Page component (uses primitives + queries)
   ↓
useXQuery / useXMutation       ← src/api/queries/
   ↓
openapi-fetch client           ← src/api/client.ts
   ↓
/api/** (Vite proxy in dev)
   ↓
http://localhost:8080 (gateway)
   ↓
microservice
```

Server data lives in TanStack Query's cache. Pinia holds **only** auth (token + identity) and UI state (toasts, modal stack). If you find yourself caching server data in Pinia, stop — use a query.

## Why so many small files

- A primitive per file. A page per file. A query module per resource.
- Smaller files are faster to reason about, faster to review, and produce cleaner diffs.
- Files that change together live together (e.g. `useCartQuery` and `useAddToCartMutation` share `api/queries/cart.ts`), but a module shouldn't grow past ~150 lines without a reason.
