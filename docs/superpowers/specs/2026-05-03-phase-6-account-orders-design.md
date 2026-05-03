# Phase 6: Account & Order History — Design Spec

**Status:** Approved (brainstorm) → ready for implementation plan
**Date:** 2026-05-03
**Depends on:** Phase 5 (Buy Flow) merged

---

## Goal

Build the post-purchase account experience: profile management and order
history. Users land here from the header dropdown after they've placed an
order to review past purchases, reorder, cancel pre-payment orders, edit
their profile, change their password, and update their avatar.

This phase combines a small backend extension (snapshot product data into
order line items + add totals to summary) with a new frontend account
surface (sidebar layout, three pages).

---

## Architecture

**Sidebar-layout account shell** at `/account` with three child routes:
profile, orders list, order detail. All routes require auth.

Backend extension is intentionally narrow:

- **order-service** snapshots `productName` and `imageUrl` onto each
  `order_item` at create time, and exposes `totalAmount` + `itemCount`
  + `firstItemImageUrl` on `OrderSummaryResponse`.
- **bff-service** simplifies: `OrderDetailBffResponse` becomes
  `{ order, payment }` with no product-service runtime call. Order
  history renders even if product-service is down.

This decouples order history from product-service availability — a
permanent record shouldn't need three services up to display.

---

## Backend Extensions

### order-service

**Migration** (additive, reversible):

```sql
ALTER TABLE order_item
  ADD COLUMN product_name VARCHAR(255) NULL,
  ADD COLUMN image_url VARCHAR(512) NULL;
```

Both columns nullable — existing rows stay valid. No backfill required;
legacy orders display fallback labels in the FE.

**Entity:** `OrderItem` gains `String productName` and `String imageUrl`.

**Order-create flow:** when the create-order service/saga looks up each
product for stock validation (already happens), capture `name` and
`imageUrl` into the persisted `OrderItem` alongside `price`.

**DTOs:**

`OrderItemResponse` (inside `OrderDetailResponse`):

| Field | Type | Notes |
|---|---|---|
| `productName` | `String` | Snapshotted at create. Nullable on legacy rows. |
| `imageUrl` | `String` | Snapshotted at create. Nullable on legacy rows. |

`OrderSummaryResponse`:

| Field | Type | Notes |
|---|---|---|
| `totalAmount` | `BigDecimal` | `sum(item.price × item.quantity)` |
| `itemCount` | `int` | `items.size()` |
| `firstItemImageUrl` | `String` | First line item's snapshot URL. Nullable. |

**Tests:**

- Order-create unit test asserts `productName` and `imageUrl` persist on
  each line item after create.
- Summary mapper test covers 0/1/N items for `totalAmount` and
  `itemCount`.

### bff-service

`OrderDetailBffResponse` is currently `{ Object order, Object payment }`
(both untyped). Tighten to `{ OrderDetailView order, PaymentView payment }`
where `OrderDetailView` is a typed pass-through of order-service's
`OrderDetailResponse` (now self-sufficient) and `PaymentView` carries the
relevant payment fields.

Aggregator simplifies: order-service + payment-service only. No
product-service call.

**Tests:** aggregator unit test with mocked order + payment clients,
including the case where payment is absent (status `null`).

### Out of scope (backend)

- Phone field on profile
- Email update endpoint
- Address book / saved addresses
- Order status history / timeline
- Backfill of legacy `order_item` rows
- Tax / shipping totals
- Admin-side endpoints

---

## Frontend

### Account shell & routing

**New files:**

- `frontend/src/layouts/AccountLayout.vue` — sidebar + content panel.
- `frontend/src/pages/account/ProfilePage.vue`
- `frontend/src/pages/account/OrdersPage.vue`
- `frontend/src/pages/account/OrderDetailPage.vue`

**Router** (`frontend/src/router/index.ts`):

```ts
{
  path: '/account',
  component: AccountLayout,
  meta: { requiresAuth: true },
  children: [
    { path: '', redirect: '/account/profile' },
    { path: 'profile', component: ProfilePage },
    { path: 'orders', component: OrdersPage },
    { path: 'orders/:id', component: OrderDetailPage },
  ],
},
```

**Header dropdown** gets an "Account" link above "Logout". One line in
the existing user dropdown component.

**Layout:** two-column on `md+` (240px sidebar, fluid content). On
mobile the sidebar collapses to a horizontal scroll-strip or top tab
bar — match existing mobile patterns in the codebase.

**State:** all server state via vue-query. No new Pinia stores.

### Profile page (`/account/profile`)

**Queries:**

- `useProfileQuery()` → `GET /authorization-server/v1/users/self`. Returns
  `{ id, name, email, gender, address }`.
- `useUpdateProfileMutation()` → `PUT /authorization-server/v1/users/self`.
  Body: `{ name?, gender?, address? }`. Invalidates `profile` on success.
- `useChangePasswordMutation()` → `PATCH /authorization-server/v1/users/self:update-password`.
  Body: `{ old_password, new_password, confirm_new_password }`.
- `useAvatarPresignMutation()` + `useAttachAvatarMutation()` — existing
  two-step flow. Invalidate profile on attach success so the avatar URL
  refreshes.

**UI sections (single page, stacked):**

1. **Avatar card** — current avatar (or initials placeholder), CHANGE
   PHOTO button. Click opens file picker (`accept="image/*"`, max 5MB).
   Flow: presign → PUT to S3 → attach. Show uploading state. Errors
   surface inline next to the avatar with RETRY.

2. **Profile form** (VeeValidate + Zod, matches Phase 5 pattern):
   - `name` — required, 1-100 chars
   - `gender` — select MALE / FEMALE / OTHER (or null)
   - `address` — textarea, optional, max 500 chars
   - `email` — read-only display (no update endpoint)
   - SAVE disabled until form is dirty + valid. Toast on success.

3. **Change password card** — three password inputs (old, new, confirm).
   Zod schema asserts new ≥ 8 chars and matches confirm. CHANGE
   PASSWORD button. On success: clear form, toast.

**New files:**

- `frontend/src/api/queries/profile.ts` — the four hooks.
- `frontend/src/lib/zod-schemas.ts` — extend with `profileSchema` and
  `passwordSchema`.
- Domain components if the page grows: `ProfileAvatarCard.vue`,
  `ProfileForm.vue`, `PasswordChangeForm.vue`.

**Tests:**

- Profile form validation surfaces Zod errors
- Avatar upload happy path (presign → PUT → attach mocked)
- Password change validation (mismatched confirm blocks submit)

### Orders list page (`/account/orders`)

**Query:** `useOrdersListQuery({ page, size })` →
`GET /order-service/v1/orders?page=N&size=20`. Gateway injects
`X-User-Id`. Returns paged `OrderSummaryResponse[]` with the new
`totalAmount`, `itemCount`, `firstItemImageUrl` fields.

**UI:**

- Page title "MY ORDERS".
- Empty state: "No orders yet." + BROWSE PRODUCTS CTA → `/`.
- Order card per row:
  - Thumbnail (`firstItemImageUrl` or placeholder)
  - `Order #{last 8 of UUID}`, formatted date, `{itemCount} item(s)`
  - Status pill (PENDING gray, PROCESSING blue, PAID green, CANCELED
    red, FAILED red), formatted total
  - Whole card is `<router-link>` to `/account/orders/:id`
- Pagination: PREV / page indicator / NEXT. Disable PREV on page 1, NEXT
  when fewer than `size` results returned.
- Loading: skeleton cards. Error: inline error with RETRY.

**Sort:** backend default (`createdAt DESC`). No FE sort UI.
**Filter:** none in Phase 6.

**New files:**

- Extend `frontend/src/api/queries/orders.ts` with `useOrdersListQuery`.
- `frontend/src/pages/account/OrdersPage.vue`
- `frontend/src/components/domain/OrderCard.vue`
- `frontend/src/components/domain/OrderStatusPill.vue` — reused on
  detail page.

**Tests:**

- Renders order cards from mocked query
- Empty state when list is empty
- Pagination disables correctly at boundaries

### Order detail page (`/account/orders/:id`)

**Queries:**

- `useOrderDetailBffQuery(orderId)` →
  `GET /bff-service/v1/orders/{orderId}`. Returns `{ order, payment }`.
- `useCancelOrderMutation()` — exists from Phase 5.
- `useAddToCartMutation()` — exists from Phase 5.

**UI (two-column on `md+`, stacks on mobile):**

**Left column — items:**

- Section title "ITEMS"
- Per row: thumbnail, product name (or "Product unavailable" if
  `productName` is null on legacy rows), `qty × price`, line subtotal.
  Product name links to `/products/:productId` when not null.

**Right column — sidebar:**

- `ORDER #{last 8 of UUID}` header, full UUID below in small mono.
- Status pill (reuses `OrderStatusPill`).
- Date placed.
- Shipping address block (multi-line, formatted).
- Phone.
- Payment block: `payment.status` pill (PAID / PENDING / FAILED /
  CANCELED / "—" if no payment), payment method, captured-at timestamp
  when PAID.
- Totals: subtotal, total.
- **Action buttons (conditional):**
  - **REORDER** — always visible when order has items. Loops
    `useAddToCartMutation` over items. Per-item failure (out-of-stock
    409) accumulates skipped names. Toast: "N items added" or "N
    added, M unavailable: [names]". Navigate to `/cart` after.
  - **CANCEL ORDER** — visible only when status is PENDING or
    PROCESSING. Confirmation modal ("Cancel order #abc12345? This
    cannot be undone."). On confirm: mutation → invalidate detail
    query → status flips on success.

**Loading:** skeleton layout. **Error:** inline error block with RETRY +
"Back to orders" link. **404:** friendly "Order not found" panel.

**New files:**

- Extend `frontend/src/api/queries/orders.ts` with
  `useOrderDetailBffQuery`.
- `frontend/src/pages/account/OrderDetailPage.vue`
- `frontend/src/components/domain/OrderItemRow.vue`

**Tests:**

- Renders order with hydrated items
- Legacy item (null `productName`) shows fallback label, no link
- CANCEL ORDER hidden when PAID; visible when PENDING; confirmation
  modal blocks submit until confirmed
- REORDER loops mutations, navigates to cart, surfaces partial-success
  toast

---

## Error Handling

- All mutations throw `ApiError` (existing). Pages catch and surface
  inline errors near the failing action — never silent.
- 401 anywhere → existing middleware redirects to `/login?next=`.
- 404 on order detail → friendly "Order not found" panel with "Back to
  orders" link.
- Avatar upload: surface S3 PUT failure (network, size-rejected)
  inline next to the avatar with RETRY.

---

## Testing Strategy

**Backend:** unit tests for the new mappers (summary totals, snapshot
persistence) and the trimmed BFF aggregator. Lean on existing Phase 5
saga coverage to prove order-create still works after the column add.

**Frontend:** Vitest + @testing-library/vue + `vi.mock` for query
modules (Phase 5 pattern, no MSW). ~15-20 new tests across the three
pages. Existing 126 tests stay green.

**Manual sandbox** (PR test-plan checkboxes):

- Profile edit + avatar upload
- Password change
- Orders list pagination
- Order detail with PAID example
- Order detail with CANCELED example
- Order detail with PENDING example
- REORDER happy path
- REORDER with one out-of-stock item
- CANCEL ORDER on a PENDING order

User runs these against a live stack.

---

## Rollout

Single PR on `feat/phase-6-account`. Backend migration lands on the
same branch. Deploy order: order-service → bff-service → FE (same
discipline as Phase 5).

No feature flag — account routes are net-new and gated behind
`requiresAuth`. Zero risk to non-logged-in storefront traffic.

---

## Out of Scope (Non-Goals)

- Phone field on profile
- Email update
- Address book / multiple saved addresses
- Order status history / timeline
- Tax / shipping line items
- Status filter on orders list
- Backfill of `productName` / `imageUrl` for legacy orders
- Admin-side order/profile management

---

## Visual Direction (binding)

The storefront has a committed editorial / risograph-zine aesthetic: outlined
display numerals as page folios, `BStamp` for state, `BCropmarks` framing key
content, thick rules, mono uppercase kickers, a single `--spot` accent over
ink. Phase 6 must extend that voice — it must NOT introduce SaaS-dashboard
conventions (sidebar nav, traffic-light status pills, neutral "MY ORDERS"
titles, "No orders yet." copy). If a page doesn't use at least two of
`BStamp`, `BCropmarks`, `BMarginNumeral`, or the outlined-numeral folio
treatment, it's wrong.

### Naming & copy

| Generic (do not use) | Use instead |
|---|---|
| "My Account" / sidebar header | `THE ACCOUNT` with folio numeral `02` |
| "My Orders" page title | `THE LEDGER` with folio numeral and kicker `Issue Nº0X — Receipts` |
| "Order Detail" | `RECEIPT Nº{last8}` (outlined-display treatment) |
| "Profile" tab | `MASTHEAD` (avatar) / `COLOPHON` (form) / `CREDENTIALS` (password) — three sections, not three tabs |
| "No orders yet." | `LEDGER UNPRINTED — BROWSE THE ISSUE` |
| Loading spinner | `STAMPING…` / `INKING…` / `TYPESETTING…` (match HomePage tone) |
| Error generic | `SERVER STAMP MISSED — RETRY?` (mirrors HomePage) |
| Cancel modal "This cannot be undone" | `VOID THIS ORDER? STAMP IS PERMANENT.` |
| REORDER toast partial | `N STAMPED · M OUT OF PRESS: [names]` |

### Account shell — masthead strip, not sidebar

`AccountLayout.vue` is a **masthead** with a horizontal tab strip on every
breakpoint. Drop the 240px sidebar entirely.

- Top: folio numeral `02` (outlined display, mirrors `home__numeral`) + kicker
  `Issue Nº0X — The Account`.
- Thick rule (`var(--border-thick)`) beneath.
- Three nav items in mono uppercase: `MASTHEAD · LEDGER · RECEIPT`. (Internally
  these route to `/account/profile`, `/account/orders`, `/account/orders/:id`.)
- Active item: underlined with a 4px `--spot` rule, no background fill.
- Inactive items: ink color, hover sets `--spot` underline.
- The strip is the same horizontal element on mobile and desktop — no
  collapse, no hamburger.

### Status: stamps, not pills

Replace every status pill in spec sections (orders list card + detail
sidebar + payment block) with `BStamp`. One spot color only. No
gray/blue/green/red palette.

| Order status | Stamp text | Tone | Rotate |
|---|---|---|---|
| `PENDING` | `PENDING` | `ink` | `-3` |
| `PROCESSING` | `IN PRESS` | `ink` | `+4` |
| `PAID` | `PAID` | `spot` | `-6` |
| `CANCELED` | `VOIDED` | `ink` | `+8` (struck-through if BStamp supports; otherwise plain) |
| `FAILED` | `MISFIRE` | `ink` | `-4` |

Payment statuses use the same vocabulary: `PAID` (spot), `PENDING`,
`VOIDED`, `MISFIRE`. Missing payment renders an em-dash, not a placeholder
pill.

The **new** `OrderStatusPill.vue` component name in the original spec is
misleading. Rename to **`OrderStatusStamp.vue`** and have it return a
configured `BStamp`. Update plan Task 10 accordingly.

### Orders list — receipts, not cards

`OrdersPage.vue` is a stack of typeset receipts, not a grid of card
components.

- Page title: outlined-numeral folio (`02`) + display heading `THE LEDGER` +
  kicker `Issue Nº0X — Receipts`.
- Each row is a full-width receipt: thick top rule, two-row mono layout —
  - Row 1: `Nº{last8} ──── STAMPED 2026.05.03 / 14:22 ──── {itemCount} ITEMS`
  - Row 2: thumbnail (small, framed by 2px ink border, no rounded corners) on
    the left; total set in display font on the right; `OrderStatusStamp` slotted
    above the total, rotated.
- Hover: row's left margin pulls 8px right and reveals a `→` glyph in
  `--spot`. No card shadow. No background fill.
- Empty state: centered `BStamp size="lg" rotate="-4"` reading `LEDGER
  UNPRINTED`, ghost `BButton` `BROWSE THE ISSUE` below.
- Pagination: reuse the existing `home__pager` mono-button treatment from
  `HomePage.vue` verbatim. Don't invent a new "PREV / NEXT" bar.
- `OrderCard.vue` becomes `OrderReceiptRow.vue` to reflect the metaphor.
  Update plan Task 10.

### Order detail — printed bill

`OrderDetailPage.vue` is framed as a printed receipt.

- Wrap the items block in `<BCropmarks>` — non-decorative use; this is the
  signature device.
- Header: outlined-display `RECEIPT Nº{last8}`, full UUID below in muted
  mono, `STAMPED 2026.05.03 / 14:22` kicker.
- Items rendered as a typeset bill (one row per line item):

  ```
  01 ── PRODUCT NAME ............... 2 × $29 ........ $58
  02 ── PRODUCT NAME ...............  1 × $12 ........ $12
  ```

  Use a leader-dot CSS pattern (`::after` with `border-bottom: 1px dotted` or
  flex with a `flex: 1` dotted spacer). Index column uses `BMarginNumeral`.
  Legacy null `productName` renders `── PRODUCT VOIDED ──` in muted ink, no
  link.
- Right column: shipping block labeled `SHIP TO`, payment block labeled
  `TENDERED`, totals block labeled `TOTAL DUE`. The totals row reverses to
  ink-on-`--spot` — the only filled block on the page.
- Status: `OrderStatusStamp` rotated and absolutely positioned to overlap the
  top-right corner of the items frame, breaking the grid (the print-stamp
  metaphor — match how `home__title` uses `text-shadow: 4px 4px 0 var(--spot)`).
- Action buttons: ghost `BButton` only, mono uppercase. `REORDER → STAMP
  AGAIN`. `CANCEL ORDER → VOID THIS RECEIPT`.
- 404 state: `BStamp size="lg" rotate="-6"` reading `RECEIPT MISFILED`, ghost
  `BButton` back link.
- Loading: skeleton uses muted ink rules, not gray rectangles. Caption:
  `INKING…`.

### Profile — three printer's sections

`ProfilePage.vue` stacks three sections divided by `BCropmarks`, each with a
folio numeral and section label:

1. `01 — MASTHEAD` — avatar card. CTA reads `RE-STAMP PHOTO`. Upload-in-flight
   caption: `INKING…`. Error: inline `SERVER STAMP MISSED — RETRY?`.
2. `02 — COLOPHON` — profile form. SAVE button copy: `SET IN TYPE`. Toast on
   success: `COLOPHON UPDATED`.
3. `03 — CREDENTIALS` — password change. Submit copy: `RE-KEY`. Toast: `KEY
   CHANGED`. Mismatch error: `KEYS DON'T LINE UP`.

Email read-only field labeled `IMPRINT` (not "Email"), set in mono.

### Component renames (binding for plan)

| Plan calls it | Build it as |
|---|---|
| `OrderStatusPill.vue` | `OrderStatusStamp.vue` (wraps `BStamp`) |
| `OrderCard.vue` | `OrderReceiptRow.vue` |
| `OrderItemRow.vue` | (keep name, but layout is leader-dot bill row) |

### What this rules out

- No `bg-blue-100` / `bg-green-100` / `bg-red-100` traffic-light backgrounds.
- No rounded-card components with shadow. The aesthetic uses 2px ink rules,
  not elevation.
- No "Account" sidebar with vertical nav.
- No emoji, no icon-only buttons, no Heroicons. Existing app uses zero of
  these.
- No tooltip libraries or dropdown menus introduced for Phase 6.

### Tests pick up the rename

Test file names follow the renamed components:
`OrderStatusStamp.spec.ts`, `OrderReceiptRow.spec.ts`. Test the rendered
stamp text + rotation prop, not pill background colors.
