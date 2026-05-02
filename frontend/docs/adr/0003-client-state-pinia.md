# 0003 — Client state: Pinia (auth + UI only)

**Status:** Accepted
**Date:** 2026-05-01

## Context

We have client-side state that isn't server data: auth token + decoded identity, toast queue, modal stack, UI theming knobs. We need a store with persistence (auth survives reload), devtools, and TS inference.

## Decision

**Pinia** for client state. Two stores: `useAuthStore` (token, user, role; persisted to `localStorage`) and `useUiStore` (toasts, modals).

**Server data does NOT live in Pinia.** That's TanStack Query's job (see ADR 0002).

## Alternatives considered

| Option                                     | Why not                                                                                                         |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Vuex 4                                     | Officially superseded by Pinia.                                                                                 |
| Composables-only (`useAuth()` with `ref`s) | Loses `localStorage` persistence wiring + Vue DevTools integration. Possible, but reinventing what Pinia ships. |
| Zustand-style external store               | Would work, but Pinia is the Vue-idiomatic answer with first-class DevTools.                                    |

## Consequences

- Strong boundary: anything that came from the API → query. Anything else → Pinia. This boundary is enforced in [`docs/01-architecture.md`](../01-architecture.md).
- `localStorage` persistence is hand-wired (small, fits the auth use case). No `pinia-plugin-persistedstate` dependency.
- Multi-tab sync: Pinia subscribes to `storage` event for `aibles.auth` key.
