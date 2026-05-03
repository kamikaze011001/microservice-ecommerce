# Phase 4 — DoD Verification

Date: 2026-05-03
Branch: `frontend/phase-4-browse`
Verifier: Vitest unit suite + typecheck + lint. Manual DoD sweep deferred to a live-backend session.

## Automated evidence

| Check             | Result                                                                                 |
| ----------------- | -------------------------------------------------------------------------------------- |
| `pnpm test --run` | 99/99 passing across 26 test files                                                     |
| `pnpm typecheck`  | 0 errors                                                                               |
| `pnpm lint`       | 0 errors (10 pre-existing warnings in unrelated primitive files; unchanged by Phase 4) |

## Phase 4 test additions

- `BImageFallback.spec.ts` — 3 cases (cropmark-X swatch, name overlay, alt fallback)
- `useDebouncedRef.spec.ts` — 2 cases (trailing-edge, default 400ms)
- `HomePage.spec.ts` — 10 cases (render, empty catalog, STAMPING, debounce coalesce, ?q= sync, hydrate ?q=, click page→?page=, hydrate ?page=, FETCHING stamp, OFFLINE retry)
- `ProductDetailPage.spec.ts` — 6 cases (render attributes, image fallback, NotFoundPage on 404, guest CTA, authed in-stock CTA, sold-out CTA)

Total Phase 4 additions: 21 new cases.

## Manual DoD — pending live-backend sweep

The following items require a running backend and a browser. They are not blocked by code; they are deferred verification:

| DoD bullet                                                   | Evidence target                                     |
| ------------------------------------------------------------ | --------------------------------------------------- |
| Home shows real products from `/product-service/v1/products` | DevTools Network: GET returns 200; grid renders.    |
| Search debounce: 5 fast keystrokes → 1 network request       | DevTools Network filter `keyword=`.                 |
| Empty catalog state                                          | Stub empty list → `ISSUE Nº01 / COMING SOON` stamp. |
| PDP for valid id renders image/name/price/attrs/CTA          | Manual sweep `/products/<seed-id>`.                 |
| PDP for invalid id → NotFoundPage                            | Manual sweep `/products/no-such-id`.                |
| Guest CTA → `/login?next=…` round-trip                       | Logged-out → click → log in → URL = same PDP.       |
| Authed CTA disabled + AVAILABLE PHASE 5 stamp                | Manual sweep with seeded user.                      |
| Sold-out CTA hidden + SOLD OUT stamp                         | Seeded `quantity=0` product.                        |
| Pagination `?page=2` round-trips                             | URL bar + click.                                    |
| URL sync `/?q=foo&page=3` direct-load                        | Paste URL → input + page hydrate.                   |
| Image fallback on broken `image_url`                         | DevTools force 404 on image → cropmark-X.           |
| Sticker rotation + misregistration on hover                  | Inspector confirms transform per card.              |
| No console errors/warnings on `/` and `/products/:id`        | Manual console check.                               |

## Reproduction

```bash
cd frontend
pnpm test --run
pnpm typecheck
pnpm lint
```
