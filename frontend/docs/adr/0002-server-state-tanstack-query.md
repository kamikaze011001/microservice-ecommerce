# 0002 — Server state: TanStack Vue Query

**Status:** Accepted
**Date:** 2026-05-01

## Context

The app reads/writes against ~10 backend endpoints. We need: caching, background refetch, retry policy, optimistic mutations, stale-while-revalidate, request deduping, devtools. Building this on top of plain `fetch` + Pinia would mean reinventing every primitive of a query library.

## Decision

**`@tanstack/vue-query`** for all server state. Pinia is reserved for client state (auth + UI) only.

## Alternatives considered

| Option                   | Why not                                                                                             |
| ------------------------ | --------------------------------------------------------------------------------------------------- |
| Pinia + composables only | Reinvents caching, invalidation, dedup, retry. Months of bugs to recover what TanStack ships day-1. |
| SWR for Vue              | Less mature, smaller community than TanStack.                                                       |
| Apollo Client            | We don't have GraphQL.                                                                              |

## Consequences

- Hierarchical cache keys give surgical invalidation (`["products"]` vs `["products", id]`).
- Optimistic mutations (cancel order, qty stepper) are first-class.
- Devtools in dev are fantastic.
- Bundle adds ~12 kB gzip — acceptable for the value.
- Clear boundary: server data flows through queries, never through Pinia. This is enforced in [`docs/04-api-conventions.md`](../04-api-conventions.md).
