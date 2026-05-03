# Phase 5 — Buy Flow Design

**Date:** 2026-05-03
**Status:** Approved
**Companion docs:** [`2026-05-01-storefront-frontend-design.md`](./2026-05-01-storefront-frontend-design.md), [`2026-05-01-storefront-frontend-rollout.md`](./2026-05-01-storefront-frontend-rollout.md)
**Branch:** `feat/phase-5-buy-flow`

## Goal

Logged-in user can complete a purchase end-to-end against the live backend: add to cart → adjust quantities → enter shipping address → place order → approve on PayPal sandbox → land back on the storefront and see the order marked `PAID`.

## Scope

One shippable branch. Three new frontend pages plus a small backend patch:

- `pages/CartPage.vue` (replaces the existing `CartPlaceholder.vue` stub)
- `pages/CheckoutPage.vue`
- `pages/PaymentResultPage.vue` (handles both `/payment/success` and `/payment/cancel`)
- Backend patch to `IPNPaypalController` so PayPal redirect lands on the FE

## Non-goals

- Guest cart (cart is auth-required, per design doc)
- Server-side persisted shipping addresses (localStorage only for v1)
- Multiple payment methods (PayPal sandbox only)
- Order history page (`OrdersPage` ships in Phase 6)
- Playwright e2e for the buy flow (lands in Phase 7)
- Coupons, taxes, shipping calc (out of v1 scope)

## PayPal flow — Pattern A (backend-landing, then 302 to FE)

The canonical PayPal Smart Checkout (Orders v2) flow:

```
1. FE  → BE:      POST /v1/payments { orderId, amount }
2. BE  → PayPal:  POST /v2/checkout/orders { …, return_url, cancel_url }
                  ← { id, links:[…approve…] }
3. BE  → FE:      { approvalUrl }
4. FE  → browser: window.location.href = approvalUrl
5. User approves on paypal.com
6. PayPal → browser: 302 to return_url?token=ORDER_ID
7. BE handler:
     a. capture order (POST /v2/checkout/orders/{token}/capture)
     b. resolve internal orderId from PayPal custom_id
     c. respond 302 Location: ${FRONTEND}/payment/success?orderId=…
8. FE /payment/success polls GET /bff-service/v1/orders/{orderId} until status=PAID
```

**Why Pattern A** (backend captures, then 302s to FE) over Pattern B (FE captures): capture stays authoritative server-side, no client-side race, no risk of a user closing the tab before capture fires. FE is purely a result viewer.

## Routes

| Route                           | Auth     | Page                                      |
| ------------------------------- | -------- | ----------------------------------------- |
| `/cart`                         | required | `CartPage`                                |
| `/checkout`                     | required | `CheckoutPage`                            |
| `/payment/success?orderId=…`    | public   | `PaymentResultPage` (success variant)     |
| `/payment/cancel?orderId=…`     | public   | `PaymentResultPage` (cancel variant)      |

`/payment/success` and `/payment/cancel` are public because the user may briefly lose auth context during the PayPal round-trip; the existing 401 interceptor handles re-login with `?next=` if `useOrderQuery` is rejected.

## Files

### New

- `frontend/src/pages/CartPage.vue`
- `frontend/src/pages/CheckoutPage.vue`
- `frontend/src/pages/PaymentResultPage.vue`
- `frontend/src/api/queries/cart.ts` — `useCartQuery`, `useUpdateCartItemMutation`, `useRemoveCartItemMutation`
- `frontend/src/api/queries/orders.ts` — `useCreateOrderMutation`, `useOrderQuery`
- `frontend/src/api/queries/payments.ts` — `useCreatePaymentMutation`
- `frontend/src/components/domain/CartLineItem.vue`
- `frontend/src/components/domain/CartSummary.vue`
- `frontend/src/components/domain/AddressForm.vue`
- `frontend/src/components/domain/OrderStatusStamp.vue`

### Modified

- `frontend/src/router/index.ts` — replace `CartPlaceholder` route, add `/checkout`, `/payment/success`, `/payment/cancel`
- `frontend/src/lib/zod-schemas.ts` — add `addressSchema`
- `frontend/src/pages/ProductDetailPage.vue` — wire add-to-cart CTA to `useAddToCartMutation` (cart query exists from Phase 3 but `add-to-cart` was a placeholder)
- `payment-service/src/main/java/org/aibles/payment_service/controller/IPNPaypalController.java`
- `payment-service/src/main/java/org/aibles/payment_service/service/PaymentService.java` — `handleSuccessPayment` / `handleCancelPayment` return `String orderId` instead of `void`
- `payment-service/src/main/java/org/aibles/payment_service/service/PaymentServiceImpl.java` — return `orderId` from those methods
- `payment-service/src/main/resources/application.yml` — add `application.frontend.base-url`
- `docker/vault-configs/payment-service.json` — add `application.frontend.base-url` key

### Removed

- `frontend/src/pages/CartPlaceholder.vue`

## CartPage `/cart`

**Query.** `useCartQuery()` → `GET /api/order-service/v1/shopping-carts`. Cache key `["cart"]`. Returns `{ items: [{ shoppingCartItemId, productId, name, image_url, unit_price, quantity, available_stock }], subtotal }`.

**Empty state.** Marginalia numeral `00` + headline `YOUR CART IS EMPTY` + secondary CTA `BACK TO HOME` → `/`.

**Line item (`CartLineItem`).** Polaroid thumbnail, name (link to `/products/{productId}`), unit price, qty stepper, line subtotal, remove (×). No card-rotation here — too distracting on a list.

**Qty stepper.**
- Bounds: `1 ≤ qty ≤ available_stock`. If a line item exceeds current stock (race after another tab/session bought stock), show inline `LOW STOCK — N AVAILABLE` and clamp to N.
- Debounced 400 ms before firing `useUpdateCartItemMutation` → `POST /shopping-carts:update-item { shopping_cart_item_id, quantity }`.
- Optimistic update: vue-query `onMutate` patches the cached cart, `onError` rolls back with red toast `COULDN'T UPDATE QUANTITY`.

**Remove.** `useRemoveCartItemMutation` → `POST /shopping-carts:delete-item { shopping_cart_item_id }`. Optimistic. Rollback toast on error.

**Subtotal.** Computed client-side from items (sum of `unit_price * quantity`). Right-aligned. Currency formatted via `lib/format.ts`.

**Primary CTA.** `BButton variant="spot"` → `PROCEED TO CHECKOUT` → `/checkout`. Disabled when:
- Cart is empty, or
- Any line has `quantity > available_stock` (force user to fix race conflict first).

## CheckoutPage `/checkout`

**Layout.** Two columns (desktop). Left: address form. Right: order summary (read-only line items + subtotal). Mobile: stacked.

**Read.** `useCartQuery()` shared with `/cart`. If cart is empty on mount, redirect to `/cart` (defensive — they shouldn't reach this state via UI).

**Address form (`AddressForm` + VeeValidate + Zod).** Fields:

| Field      | Validation                                              |
| ---------- | ------------------------------------------------------- |
| `street`   | `min(3)`                                                |
| `city`     | `min(2)`                                                |
| `state`    | `min(2)`                                                |
| `postcode` | `regex(/^\S{3,10}$/)` (loose; country-specific deferred)|
| `country`  | ISO-3166-1 alpha-2 enum, default `US`                   |
| `phone`    | `regex(/^\+?[0-9\s\-()]{7,20}$/)` (loose E.164)         |

All required. Errors surface inline on blur.

**Address persistence.** On mount, populate from `localStorage["aibles.checkout.lastAddress"]` if present. On successful order creation, save the submitted address back to that key. No backend address-book endpoint in v1.

**Place Order button.** `BButton variant="spot"` with copy `PLACE ORDER`. While the mutation chain runs, copy swaps to `STAMPING…` and the button enters a 200 ms rotation+scale animation per design doc.

**Sequential mutations.**

```
1. useCreateOrderMutation
   POST /api/order-service/v1/orders
   body: { items: [{ productId, quantity }], shippingAddress }
   ← { orderId }
   side-effects:
     - localStorage["aibles.checkout.pendingOrderId"] = orderId
     - localStorage["aibles.checkout.lastAddress"] = address

2. useCreatePaymentMutation
   POST /api/payment-service/v1/payments
   body: { orderId, amount: subtotal }
   ← { approvalUrl }

3. window.location.href = approvalUrl
```

**Error semantics.**

| Failure point     | UX                                                                                  |
| ----------------- | ----------------------------------------------------------------------------------- |
| Order create      | Stay on page. Stamp-red banner `ORDER NOT CREATED — TRY AGAIN`. Form preserved.     |
| Payment init      | Banner `PAYMENT NOT STARTED — RETRY` with retry button that re-fires step 2 only against the same `orderId`. |
| Network / unknown | Generic stamp-red toast `SOMETHING BROKE — TRY AGAIN`.                              |

**Browser-back from PayPal.** If the user backs out of the PayPal approval page before approving, they land on `/checkout` again. On mount, if `aibles.checkout.pendingOrderId` exists, show a pending-order banner above the form:

> `ORDER #{id} IS PENDING PAYMENT`
> Two buttons: `RESUME PAYMENT` (re-init `useCreatePaymentMutation` against that orderId, redirect to fresh `approvalUrl`) and `CANCEL ORDER` (`POST /orders/{id}:cancel`, clear localStorage key, then proceed fresh).

The banner clears `aibles.checkout.pendingOrderId` once the user picks an action.

## PaymentResultPage `/payment/{success|cancel}?orderId=…`

Single component, branches on `route.path` to determine variant.

### Success variant

**Query.** `useOrderQuery(orderId, { polling: { interval: 1000, max: 10, until: status => status === 'PAID' } })` → `GET /api/bff-service/v1/orders/{orderId}`.

**State machine.**
1. Mount → `VERIFYING…` stamp with gentle pulse animation. Poll #1 fires immediately, then every 1 s.
2. Poll returns `status === 'PAID'` → swap to `PAID` stamp with rotation+scale 200 ms entry. Stop polling.
3. After 10 polls without `PAID` → swap to `STILL PROCESSING` stamp with secondary copy `Saga is still settling. Check Orders.`
4. Final CTA in all terminal states: `VIEW ORDER` → `/orders?selected={orderId}`. (OrdersPage doesn't exist yet in Phase 5; the link will 404 to NotFound until Phase 6 — acceptable.)

**Cleanup.** On `PAID` or unmount, clear `aibles.checkout.pendingOrderId` from localStorage.

### Cancel variant

**Static.** No polling. Stamp-red `PAYMENT CANCELED` with secondary copy `Your order is on hold. Pick up where you left off, or cancel.`

**Two CTAs:**
- `RETRY PAYMENT` → re-init `useCreatePaymentMutation({ orderId })` → redirect to fresh `approvalUrl`.
- `CANCEL ORDER` → `POST /orders/{id}:cancel` → on success, clear `aibles.checkout.pendingOrderId`, route to `/` with toast `ORDER CANCELED`.

## Error & 401 model

Mutation hooks return `{ data, error, isPending, reset }`. Components map `ApiError.code` to user-facing copy; unknown codes fall through to a generic stamp-red toast. 401 is handled centrally by the existing interceptor in `api/client.ts` — pages do not replicate auth handling.

## Backend patch (Pattern A)

Single controller change plus a config key.

**`IPNPaypalController.java`** (replaces void return with `302`):

```java
@RestController
@RequestMapping("/v1")
public class IPNPaypalController {

    private final PaymentService paymentService;
    private final String frontendBaseUrl;

    public IPNPaypalController(
        PaymentService paymentService,
        @Value("${application.frontend.base-url}") String frontendBaseUrl
    ) {
        this.paymentService = paymentService;
        this.frontendBaseUrl = frontendBaseUrl;
    }

    @GetMapping("/paypal:success")
    public ResponseEntity<Void> ipnSuccess(@RequestParam("token") String token) {
        String orderId = paymentService.handleSuccessPayment(token);
        URI location = URI.create(frontendBaseUrl + "/payment/success?orderId=" + orderId);
        return ResponseEntity.status(HttpStatus.FOUND).location(location).build();
    }

    @GetMapping("/paypal:cancel")
    public ResponseEntity<Void> ipnCancel(@RequestParam("token") String token) {
        String orderId = paymentService.handleCancelPayment(token);
        URI location = URI.create(frontendBaseUrl + "/payment/cancel?orderId=" + orderId);
        return ResponseEntity.status(HttpStatus.FOUND).location(location).build();
    }
}
```

**`PaymentService` interface change.** `handleSuccessPayment` and `handleCancelPayment` change return type from `void` to `String` (the internal orderId). Implementation already resolves orderId from PayPal order details (`PaypalOrderDetail.purchaseUnits[0].customId`); just plumb it through.

**Config.** `payment-service/src/main/resources/application.yml`:

```yaml
application:
  frontend:
    base-url: ${FRONTEND_BASE_URL:http://localhost:5173}
```

Plus the same key in `docker/vault-configs/payment-service.json` so prod can override via Vault.

**Tunnel.** Dev still requires a public tunnel for PayPal sandbox to reach the backend (`PAYPAL_TUNNEL_URL`). That's pre-existing — no new infra needed.

## Testing

Per rollout DoD: ≥ 4 page tests with Vitest + @testing-library/vue + MSW.

1. **Cart renders** — mocked `GET /shopping-carts` returns 2 items + subtotal; assert both line items + correct subtotal in DOM.
2. **Cart qty stepper debounce** — fake timers, 5 stepper clicks within 400 ms, advance 500 ms, assert MSW recorded exactly 1 `POST /shopping-carts:update-item` call.
3. **Checkout form validation** — render `CheckoutPage` with non-empty cart, click `PLACE ORDER` with empty form, assert all required-field error messages visible and `useCreateOrderMutation` was not called.
4. **PaymentResultPage poll** — mount with `?orderId=ABC`, MSW returns `PROCESSING` for first 2 polls then `PAID`, advance fake timers 3 s, assert `PAID` stamp visible.

Backend: no new tests for the controller patch (Spring `contextLoads` guard pattern continues to apply; redirect logic is trivial and verified by manual sandbox dry-run).

Manual verification: end-to-end against PayPal sandbox before merge — the only way to validate the full redirect chain.

## Definition of Done

- [ ] Add to cart from PDP → `/cart` shows item with correct qty, unit price, line subtotal, cart subtotal
- [ ] Qty stepper debounced 400 ms — 5 fast clicks produce exactly 1 `POST /shopping-carts:update-item` (verified in test + DevTools network panel)
- [ ] Stepper clamps to `available_stock` and shows `LOW STOCK — N AVAILABLE` if cart was stale
- [ ] Place Order on a valid cart → redirect to PayPal sandbox → approve → land on `/payment/success?orderId=…` → see `PAID` stamp within 10 s
- [ ] PayPal cancel → land on `/payment/cancel?orderId=…` → `RETRY PAYMENT` re-inits payment for the same `orderId`
- [ ] `CANCEL ORDER` on the cancel page → order moves to CANCELED server-side, user lands on `/` with confirmation toast
- [ ] Browser back from PayPal approval page → `/checkout` shows pending-order banner with `RESUME PAYMENT` and `CANCEL ORDER` actions
- [ ] Address form validation: empty submit shows inline errors, mutations not called; valid submit succeeds
- [ ] Address localStorage persists across page loads
- [ ] ≥ 4 page tests passing (`pnpm test`); lint + typecheck clean (`pnpm lint`, `pnpm typecheck`)
- [ ] Backend patch merged: `IPNPaypalController` returns 302 to FE, `application.frontend.base-url` configured in `application.yml` and Vault template

## Open follow-ups (not in scope)

- `OrdersPage` (`/orders` and `?selected=…` deep-link) → Phase 6
- Playwright golden-path test for the full buy flow → Phase 7
- Country-specific postcode validation, address book, multiple shipping addresses → post-v1
- PayPal webhook safety net (`CHECKOUT.ORDER.APPROVED`) for tab-close-before-capture edge case → only needed if we ever switch to Pattern B; sticking with Pattern A makes this unnecessary
