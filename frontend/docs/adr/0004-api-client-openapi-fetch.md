# 0004 — API client: openapi-typescript + openapi-fetch

**Status:** Accepted
**Date:** 2026-05-01

## Context

The backend gateway aggregates Swagger from all microservices at `/v3/api-docs`. We want type-safe API calls without a heavyweight client generator (large bundle, maintenance burden, mismatch with our error envelope). The runtime client must be tiny (we're shipping a learning-scope SPA).

## Decision

- **`openapi-typescript`** for ahead-of-time type generation: `pnpm api:gen` produces `src/api/schema.d.ts`.
- **`openapi-fetch`** for the runtime client (~3 kB minzip). Uses the generated types for full request/response inference.

## Alternatives considered

| Option                                | Why not                                                                                                         |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `axios` + hand-written types          | No type safety from the OpenAPI spec; types drift from backend.                                                 |
| `Orval` (codegen for queries + types) | Generates an entire client + react-query layer, but for Vue + our custom envelope it's awkward. Heavier output. |
| `tRPC`                                | Backend isn't tRPC. Out of scope.                                                                               |
| Hand-rolled fetch wrapper             | Loses type safety; reinvents what `openapi-fetch` does in 3 kB.                                                 |

## Consequences

- The `BaseResponse { status, code, message, data }` envelope is unwrapped in `src/api/client.ts` interceptor — so callers see `data` directly while still getting OpenAPI-derived types.
- `pnpm api:gen` must be run when backend OpenAPI changes. Can be wired into CI as a check (Phase 3+).
- Tiny runtime — no bundle bloat.
- Type errors surface at compile time when backend signatures drift.

## Generation pipeline

```
backend gateway /v3/api-docs ──→  openapi-typescript ──→  src/api/schema.d.ts
                                                            │
                                          ▲
                                          │ openapi-fetch<paths>()
                                          │
                                src/api/client.ts (singleton)
                                          │
                                src/api/queries/* (the boundary)
```

Defined in detail in [`docs/04-api-conventions.md`](../04-api-conventions.md).
