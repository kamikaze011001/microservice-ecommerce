# 0007 — Routing: Vue Router 4 with route guards

**Status:** Accepted
**Date:** 2026-05-01

## Context

SPA routing for ~9 paths, with auth-required and guest-only flavours, deep-link support (`/orders?selected=ORD123`), and PayPal redirect handling on `/payment/success` and `/payment/cancel`.

## Decision

**Vue Router 4** — the canonical Vue routing solution. Auth enforced via route `meta.requiresAuth` / `meta.guestOnly` flags + a global `beforeEach` guard. `?next=` query param round-trips users back through login. (Full conventions in [`docs/06-routing-auth.md`](../06-routing-auth.md).)

## Alternatives considered

| Option                           | Why not                                                                                                                     |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Unplugin-vue-router (file-based) | Cool DX but adds a build-time generator and obscures the route table. Our route count is small enough for an explicit file. |
| Nuxt                             | SSR is a non-goal.                                                                                                          |
| Custom hash routing              | No history API integration, breaks deep-linking + share-ability.                                                            |

## Consequences

- Single explicit `routes` array makes auth audit simple — grep for `requiresAuth: true`.
- Route guards centralise the auth check; pages don't reimplement it (banned by convention).
- 401 handling is dual-layered (guard + interceptor) — see `docs/06-routing-auth.md`.
- `?next` is a path (not absolute URL); we strip absolute URLs to defend against open-redirect.
