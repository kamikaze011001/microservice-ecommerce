# Storefront Frontend Design — "Issue Nº01"

**Date:** 2026-05-01
**Status:** Design approved, pending implementation plan
**Owner:** anhson713@gmail.com

## Goals

Build a single-page storefront for the existing microservice e-commerce backend. Seven user-facing screens (Home, PDP, Cart, Checkout, Orders, Login, Register) plus a PaymentResultPage component used by the PayPal `/payment/success` and `/payment/cancel` redirect routes. Distinctive risograph-zine visual identity. Type-safe API integration via generated OpenAPI types. Production-grade flow patterns (optimistic mutations, granular error handling, accessible primitives) on a learning-project scope.

## Non-goals (v1)

- Offline mode / service worker / queue-and-replay
- Refresh-token rotation (401 = logout-and-redirect; revisit if backend issues short-lived tokens)
- i18n / multi-language
- Storybook + visual regression
- Lighthouse / performance budgets in CI
- Coverage % gates
- Admin screens (CRUD on products / inventory)
- Server-side rendering

## Stack — locked decisions

| Concern | Pick |
|---|---|
| Framework | Vue 3 + Vite + TypeScript |
| Location | `frontend/` subfolder of monorepo |
| Styling | Tailwind v4 + custom design tokens, hand-rolled primitives |
| Server state | `@tanstack/vue-query` |
| Client state | Pinia (auth + UI only) |
| API client | `openapi-typescript` (codegen) + `openapi-fetch` (runtime, ~3 kB) |
| Forms | VeeValidate + Zod (schemas reused for runtime API parsing) |
| Routing | Vue Router |
| Headless UI | Reka UI for Dialog / Select / Popover (a11y for free) |
| Dev workflow | Vite proxy → real gateway, no mocks. `make up` required. |
| Cart UX | Login-gated (no guest cart in v1) |
| Unit tests | Vitest + @testing-library/vue |
| API mocking | MSW (Mock Service Worker) — used in unit tests + CI-mode e2e |
| E2E | Playwright |

## Folder structure

```
frontend/
├── public/
├── src/
│   ├── api/
│   │   ├── schema.d.ts          # generated from gateway /v3/api-docs
│   │   ├── client.ts            # openapi-fetch instance + auth interceptor
│   │   └── queries/             # vue-query wrappers per resource
│   │       ├── products.ts
│   │       ├── cart.ts
│   │       ├── orders.ts
│   │       └── auth.ts
│   ├── components/
│   │   ├── primitives/          # BButton, BCard, BInput, BStamp, BTag, BCropmarks, BMarginNumeral, BDialog, BSelect, BToast
│   │   └── domain/              # ProductCard, CartLineItem, OrderRow, ...
│   ├── composables/             # useAuth, useToast, useTelemetry, ...
│   ├── pages/                   # HomePage, ProductDetailPage, CartPage, CheckoutPage, OrdersPage, LoginPage, RegisterPage, PaymentResultPage
│   ├── router/index.ts
│   ├── stores/
│   │   ├── auth.ts              # token, user, role
│   │   └── ui.ts                # toasts, modal stack
│   ├── styles/
│   │   ├── tokens.css           # CSS variables for palette, borders, shadows, type
│   │   └── main.css             # Tailwind + global resets
│   ├── lib/
│   │   ├── zod-schemas.ts       # email, password, address; reused in forms + API parsing
│   │   └── format.ts
│   ├── App.vue
│   └── main.ts
├── tests/
│   ├── unit/
│   ├── e2e/
│   └── fixtures/
├── vite.config.ts
├── tailwind.config.js
├── tsconfig.json
└── package.json
```

**Boundaries:**
- `api/queries/` is the single API boundary. Components never call `client.GET` directly — they consume `useProductsQuery()`, etc. Centralizes cache keys, error mapping, retry policy.
- `primitives/` are styling-only (no API knowledge); `domain/` components compose primitives + queries.
- `lib/zod-schemas.ts` is the single source of truth — same schemas validate forms AND parse API responses.

## Routing & auth

| Path | Page | Auth |
|---|---|---|
| `/` | HomePage | public |
| `/products/:id` | ProductDetailPage | public |
| `/login` | LoginPage | guest-only (logged-in → `/`) |
| `/register` | RegisterPage | guest-only |
| `/cart` | CartPage | required |
| `/checkout` | CheckoutPage | required |
| `/orders` | OrdersPage | required (deep-link `?selected=ORD123` opens detail panel) |
| `/payment/success?orderId=…` | PaymentResultPage | public (PayPal lands here) |
| `/payment/cancel?orderId=…` | PaymentResultPage | public |

**Auth flow:**

1. `POST /authorization-server/v1/auth/login` → `{ accessToken, refreshToken, expiresIn }`. Pinia `useAuthStore` persists to `localStorage` (key: `aibles.auth`). User identity decoded from JWT (`sub` claim → userId). Display fields fetched via `GET /authorization-server/v1/users/me`.
2. **API client interceptor** attaches `Authorization: Bearer <token>` on every request. On `401`, clears auth store and routes to `/login?next=<currentPath>`.
3. **Route guard** in `router/index.ts`: `requiresAuth` redirects to login with `?next`; `guestOnly` redirects logged-in users to `/`.
4. **No refresh-token rotation in v1.** Logout-and-redirect on 401. Acceptable if backend issues hour-plus tokens.
5. **Multi-tab logout sync**: Pinia subscribes to `storage` event; if `aibles.auth` removed in another tab, clear store immediately.

**Vite proxy** (dev only): `/api/**` → `http://localhost:8080/**`. Same-origin in dev, no CORS needed locally. Production CORS handled by the gateway (`application.gateway.cors.*`).

**PayPal redirect** lands on the FE at `/payment/success?orderId=…` or `/payment/cancel?orderId=…` (requires backend redirect-target config — see Open Follow-ups).

## Visual identity — "Issue Nº01"

The storefront feels like a printed risograph zine catalog, not a website. Each product is a "lot". Order statuses are inspection stamps. Section breaks are printer's cropmarks. The whole UI reads like Issue Nº01 of an art-school zine that sells things.

Still neo-brutalist (thick borders, hard offset shadows, raw type), but with a specific voice instead of generic Dribbble pink-and-mint.

### Palette — risograph two-tone + one spot

```css
:root {
  --paper:        #F4EFE6;  /* warm off-white — page background */
  --paper-shade:  #E8DFD0;  /* card surfaces */
  --ink:          #1C1C1C;  /* warm charcoal — text + borders */
  --spot:         #FF4F1C;  /* fluorescent riso orange — every CTA, focus, alert */
  --stamp-red:    #C4302B;  /* stamps + inspection marks only */
  --muted-ink:    #6B6256;  /* hints, secondary text */
}
```

Orange is the singular memorable thing — every CTA, every "SOLD OUT" stamp, every focus ring. Two-tone restraint everywhere else means the orange punches.

### Typography — distinctive, free, self-hosted

| Role | Font | Source |
|---|---|---|
| Display | **Bricolage Grotesque** weight 900 | Google Fonts (free, variable) |
| Body | **Cabinet Grotesk** medium / regular | Fontshare (free) |
| Mono | **Departure Mono** | helena.gd (free) — used only for SKUs, order IDs, prices, timestamps |

No Inter. No Archivo Black. No system fonts.

### Borders, shadows, motion

```css
:root {
  --border-thin:  2px solid var(--ink);
  --border-thick: 3px solid var(--ink);
  --shadow-sm:    3px 3px 0 var(--ink);
  --shadow-md:    6px 6px 0 var(--ink);
  --shadow-lg:    10px 10px 0 var(--ink);
  --press-translate: 4px;
  --transition-snap: 60ms steps(2);  /* mechanical, not smooth */
}
```

### Memorable signature details

1. **Status stamps, not badges** — `<BStamp>` primitive: thick double-ring circular stamp, condensed text, slight rotation, `--stamp-red` ink. Renders order statuses (PROCESSING / SHIPPED / CANCELED).
2. **Misregistration on hover** — hovering a product card shifts a ghost-orange copy of the title 2 px via `text-shadow: 2px 2px 0 var(--spot)`. Looks like a misprinted poster.
3. **Marginalia numerals** — `<BMarginNumeral>` renders huge outlined section numerals ("01", "02") hanging off the page edge. Catalog page numbers.
4. **Cropmark dividers** — `<BCropmarks>` separates sections with four small black corner cropmarks instead of `<hr>`.
5. **Sticker-rotation on cards** — product cards sit at `±0.5°` random rotation. Pinned-to-wall feel, not grid.
6. **Paper grain** — body has a subtle inline-SVG noise overlay at ~4 % opacity. Page feels printed.
7. **The CTA press** — buttons have `--shadow-md`. On `:active`, translate `4px 4px` down-right, shadow shrinks to `--shadow-sm`. Snap (`steps(2)`), not ease. Mechanical, not soft.

### Primitive components

| Primitive | Notes |
|---|---|
| `BButton` | variants: `spot` (orange CTA), `ink`, `ghost`, `danger`. Press animation built in. |
| `BCard` | optional `rotate` prop, misregistration-on-hover hook |
| `BInput` | thick ink border, focus = orange ring + 2 px shift, error flips border to `--stamp-red` |
| `BStamp` | circular stamp for order status, optional rotation prop |
| `BTag` | sticker-style label, optional rotation |
| `BCropmarks` | section divider |
| `BMarginNumeral` | outlined section numeral fixed to page edge |
| `BDialog` / `BSelect` / `BPopover` | Reka UI headless primitives, brutally restyled |
| `BToast` | slide-in from top, hard shadow, auto-dismiss |

## Per-screen data flow

Cache keys are hierarchical (`["products"]`, `["products", id]`) for surgical invalidation.

### `/` HomePage (public)
- **Query:** `useProductsQuery({ page, size, q })` → `GET /api/bff-service/v1/products?page=1&size=12`
- **States:** loading → skeleton cards (no spinners); empty → "Issue Nº01 coming soon" stamp; error → page-level error card with retry
- **Search:** debounced 300 ms, sync to URL `?q=…` (shareable)

### `/products/:id` ProductDetailPage (public)
- **Query:** `useProductQuery(id)` → `GET /api/product-service/v1/products/:id`
- **CTA:** if logged in → `<BButton variant="spot">ADD TO CART</BButton>` triggers `useAddToCartMutation`; if guest → `LOGIN TO BUY` redirects to `/login?next=<currentPath>`
- **On add success:** toast + invalidate `["cart"]`
- **Inventory** rendered as `BStamp` ("IN STOCK" / "LOW STOCK" / "SOLD OUT")

### `/cart` CartPage (auth required)
- **Query:** `useCartQuery()` → `GET /api/order-service/v1/shopping-carts`
- **Mutations:** `useUpdateCartItemMutation` (qty stepper, debounced 400 ms), `useRemoveCartItemMutation`
- **Empty state:** marginalia "00" + "YOUR CART IS EMPTY" + CTA back to `/`
- No card rotation here — too distracting on a list

### `/checkout` CheckoutPage (auth required)
- **Read:** `useCartQuery()` (right-side summary)
- **Form:** VeeValidate + Zod address schema (street, city, state, postcode, country, phone)
- **Mutations (sequential):**
  1. `useCreateOrderMutation()` → `POST /api/order-service/v1/orders` (cart + address)
  2. `useCreatePaymentMutation()` → `POST /api/payment-service/v1/payments` returns `{ approvalUrl }`
  3. `window.location.href = approvalUrl` (full redirect to PayPal)
- **Errors:** order failure → stay on page, stamp-red banner; payment-init failure → "Payment not started — retry" with retry against existing orderId
- **Animation:** "PLACE ORDER" button shows "STAMPING…" during request; status stamp animates in (rotation + scale, 200 ms)

### `/payment/success?orderId=…` (public)
- **Query:** `useOrderQuery(orderId)` polls every 1 s up to 10 attempts OR until `status === "PAID"` (saga is async)
- **States:** "VERIFYING…" stamp animation → "PAID" stamp on success
- **CTA:** "VIEW ORDER" → `/orders?selected=…`

### `/payment/cancel?orderId=…` (public)
- "PAYMENT CANCELED" stamp-red. Order remains PROCESSING server-side. Two CTAs: "RETRY PAYMENT" (re-init for same order) and "CANCEL ORDER" (calls cancel endpoint).

### `/orders` OrdersPage (auth required)
- **Query:** `useOrdersQuery({ page, size })` → `GET /api/order-service/v1/orders`
- **Layout:** master-detail. Left: list (id in Departure Mono, date, total, status stamp). Right: detail panel for `?selected=…`.
- **Detail:** line items, address, payment status, "CANCEL ORDER" button if `status === "PROCESSING"`
- **Cancel:** `useCancelOrderMutation()` → `PATCH /api/order-service/v1/orders/:id:cancel`. Optimistic — stamp flips to CANCELED instantly; on 409, rollback + toast

### `/login` (guest-only)
- Zod schema (email, password). VeeValidate handles errors. 401 maps to inline "Wrong email or password" in `--stamp-red`.
- On success → `router.push(route.query.next ?? '/')`

### `/register` (guest-only)
- Zod schema matches backend `@ValidPassword` (min 8, mixed case, number) + confirm-password
- Auto-login after register; route to `?next` or `/`

### Cross-cutting: query invalidation

| Mutation | Invalidates |
|---|---|
| Login / Register | `["currentUser"]` |
| Add / Update / Remove cart | `["cart"]` |
| Create order | `["cart"]`, `["orders"]` |
| Cancel order | `["orders"]`, `["orders", orderId]` |
| Logout | clear all queries |

## Error handling

### API error taxonomy

The `openapi-fetch` interceptor classifies every non-2xx into one of six classes:

| Class | Status | Default UX |
|---|---|---|
| `auth-required` | 401 | clear auth store; redirect to `/login?next=current` |
| `forbidden` | 403 | toast "Not allowed"; stay on page |
| `not-found` | 404 | route-level → 404 page; component-level → empty state |
| `validation` | 400 / 409 / 422 | NO toast — surface inline (form field or page banner). 409 maps via `code` field for tailored copy (e.g. `ORDER_ALREADY_CANCELED`) |
| `server` | 500-599 | toast "Server error — try again". Vue-query auto-retries 3× exp-backoff for queries. Mutations don't auto-retry. |
| `network` | fetch threw | toast "Connection lost"; mutations show inline retry |

Backend response envelope is `BaseResponse { status, code, message, data }`. Interceptor unwraps `data` on success; on error throws typed `ApiError` carrying `{ status, code, message }`.

### Optimistic mutation pattern (cancel order)

```ts
useMutation({
  mutationFn: cancelOrder,
  onMutate: async (orderId) => {
    await queryClient.cancelQueries(["orders"]);
    const prev = queryClient.getQueryData(["orders"]);
    queryClient.setQueryData(["orders"], (old) =>
      old.map(o => o.id === orderId ? { ...o, status: "CANCELED" } : o)
    );
    return { prev };
  },
  onError: (err, _id, ctx) => {
    queryClient.setQueryData(["orders"], ctx.prev);
    toast.error(err.code === "ORDER_ALREADY_CANCELED"
      ? "Already canceled — refreshed."
      : "Cancel failed");
  },
  onSettled: () => queryClient.invalidateQueries(["orders"]),
});
```

### Edge cases handled

| Edge | Handling |
|---|---|
| Two tabs, logout in tab A | Pinia `storage` listener clears store in tab B; next API call gets 401 → login redirect |
| Token expired overnight, user hits `/cart` | Route guard checks boolean; API call fails 401 → interceptor kicks to `/login?next=/cart` |
| Browser-back from PayPal mid-payment | Lands on `/checkout`, cart still populated, order in PROCESSING. Banner: "Pending order — continue payment or cancel?" |
| Double-click "ADD TO CART" | Mutation has `mutationKey: ["cart","add",id]` + `useMutationState` blocks duplicate; button shows "ADDING…" disabled |
| Image fails to load on PDP | `<img @error>` swaps to brutalist placeholder: ink-on-paper outline + "IMAGE NOT FOUND" stamp |
| Empty product catalog | Home shows "Issue Nº01 coming soon" stamp (not generic "No products") |
| Cold-start gateway 503/504 | Vue-query retry handles; after 3 retries → "Connection lost" toast with manual retry |

### Observability

- Console logs gated on `import.meta.env.DEV`
- `useTelemetry()` composable: no-op stubs for `track(event)` and `captureError(err)` — wire to Sentry/PostHog later
- Vue DevTools + vue-query DevTools enabled in dev

## Testing strategy

| Layer | Tool | Scope |
|---|---|---|
| Unit | Vitest | Zod schemas (happy + sad), format helpers, `useAuth`, `apiError` classifier |
| Component | @testing-library/vue | Primitives (`BButton`, `BInput`, `BStamp`), domain components (`ProductCard`, `CartLineItem`) |
| Page | @testing-library/vue + MSW | Pages render + key flows (login error path, optimistic cancel rollback, debounced search) |
| E2E | Playwright | 2 paths: (1) public browse → PDP; (2) register → cart → checkout (PayPal stubbed) → orders → cancel |
| API mocking in tests | MSW | Same handlers reused across unit + CI-mode e2e |

**Fixtures** in `tests/fixtures/` are parsed through Zod schemas at construction → drift between FE types and backend shapes fails the fixture parse fast.

**No coverage % gate.** Test what matters: every Zod schema (happy + sad), every page (happy render), every optimistic mutation (rollback path), every error class (mapping).

**E2E run modes:**
- Local: `pnpm test:e2e` against `make up` infra
- CI: Playwright + MSW in-page (no backend dependency)

**Deferred:** Storybook, visual regression, axe-core suite, Lighthouse budgets.

## Open follow-ups (backend coordination)

These need a small backend tweak before FE can complete:

1. **PayPal redirect URLs** — backend's PayPal config currently redirects to `/payment-service/v1/paypal:success`. For the FE flow to work, the configured PayPal `return_url` and `cancel_url` need to point at the FE: `http://localhost:5173/payment/success?orderId={id}` and `…/payment/cancel?orderId={id}`. Either:
   - The backend handler issues a 302 to the FE URL after processing, OR
   - PayPal config points directly at the FE and the FE polls for status (current design)
   This needs ~10 min of backend config and confirmation of the chosen approach.

2. **Token lifetime confirmation** — current FE design assumes `accessToken` lives at least 1 hour, since v1 logs out on 401 (no refresh-token rotation). If tokens are short-lived (<15 min), users will be kicked to login mid-session. Either lengthen TTL or add refresh-token flow as v1.5 work.

3. **OpenAPI completeness** — the gateway aggregates Swagger from all services. Verify that every endpoint the FE consumes is reachable in the aggregated `/v3/api-docs` JSON (not just present in the per-service docs). The new `PATCH /v1/orders/{id}:cancel` endpoint added in this same week should be included.

## Out of scope for this spec

- Admin product management UI
- Inventory dashboards
- Email confirmation pages (transactional emails are backend-only)
- User profile / settings page (change password, avatar upload — covered by existing `/v1/users/**` endpoints, but not a v1 storefront screen)
- Wishlist, reviews, search facets, pagination beyond simple page+size
