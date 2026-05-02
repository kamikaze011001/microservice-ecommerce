# Routing & auth

## Route table

| Path               | Page                | Auth                                             |
| ------------------ | ------------------- | ------------------------------------------------ |
| `/`                | `HomePage`          | public                                           |
| `/products/:id`    | `ProductDetailPage` | public                                           |
| `/login`           | `LoginPage`         | guest-only (logged-in → `/`)                     |
| `/register`        | `RegisterPage`      | guest-only                                       |
| `/cart`            | `CartPage`          | required                                         |
| `/checkout`        | `CheckoutPage`      | required                                         |
| `/orders`          | `OrdersPage`        | required (`?selected=ORD123` opens detail panel) |
| `/payment/success` | `PaymentResultPage` | public (PayPal lands here, `?orderId=…`)         |
| `/payment/cancel`  | `PaymentResultPage` | public (`?orderId=…`)                            |

## Guards

Two route-level meta flags. Defined on the route record, enforced in a global `beforeEach`.

```ts
// src/router/index.ts (lands in Phase 3)
const routes = [
  { path: '/', component: HomePage },
  { path: '/cart', component: CartPage, meta: { requiresAuth: true } },
  { path: '/login', component: LoginPage, meta: { guestOnly: true } },
  // …
];

router.beforeEach((to) => {
  const auth = useAuthStore();
  if (to.meta.requiresAuth && !auth.isLoggedIn) {
    return { path: '/login', query: { next: to.fullPath } };
  }
  if (to.meta.guestOnly && auth.isLoggedIn) {
    return { path: '/' };
  }
});
```

## `?next=` preservation

Login-gated CTAs must round-trip the user back to where they were.

- Guest hits `LOGIN TO BUY` on `/products/abc123` → `router.push({ path: '/login', query: { next: '/products/abc123' } })`.
- After successful login → `router.push(route.query.next ?? '/')`.
- Same after register.

The `next` value is always a path, never an absolute URL — defend against open-redirect on `next` (allow only paths starting with `/`).

## Login-gated cart (v1 design)

The backend `/order-service/v1/shopping-carts` requires `AUTHORIZED`. **No guest cart in v1.**

- Anonymous users see "LOGIN TO BUY" on PDP, never an "ADD TO CART" button.
- Cart route `/cart` redirects guests to `/login?next=/cart`.
- Trade-off: simpler code, fewer states, fewer edge cases. Revisit if conversion data demands.

## 401 handling

Two levels of defence:

1. **Route guard** — read `useAuthStore.isLoggedIn` synchronously. Cheap pre-check.
2. **Interceptor** — every API call passes through `src/api/client.ts`. On 401, the interceptor:
   - Clears `useAuthStore` (and `localStorage`).
   - Calls `router.replace({ path: '/login', query: { next: route.fullPath } })`.

Why both? The guard handles "stale tab where token expired hours ago". The interceptor catches "token revoked server-side mid-session".

## No refresh-token rotation in v1

The current design treats 401 as terminal: clear store, redirect to login. This is acceptable if the backend issues hour-plus access tokens. If tokens are short-lived (<15 min), users will be kicked mid-session — escalate to v1.5 for refresh-token flow.

## Multi-tab logout sync

Pinia subscribes to `window`'s `storage` event. If `aibles.auth` is removed in tab A, tab B clears its store immediately. Tab B's next API call gets 401 (or the in-memory clear already redirected) → login.

```ts
// src/stores/auth.ts (lands in Phase 3)
window.addEventListener('storage', (e) => {
  if (e.key === 'aibles.auth' && e.newValue === null) {
    useAuthStore().clear();
  }
});
```

## PayPal redirect

PayPal sends users to FE URLs after approval/cancel:

- `http://localhost:5173/payment/success?orderId=…`
- `http://localhost:5173/payment/cancel?orderId=…`

`PaymentResultPage` is **public** — at the moment of redirect the user has just left a third-party domain and may not have an active session in this tab. The page polls `useOrderQuery(orderId)` until `status === "PAID"` (or 10 attempts).

Backend coordination — see Open Follow-up #1 in the design spec for the PayPal config change required.

## Hard rules

- **Never** read auth state by parsing the JWT in business code. The store is the source of truth (it parses once at login).
- **Never** put `requiresAuth` logic inside a component (`if (!auth.isLoggedIn) router.push(…)`). Use route meta.
- `next` must be a path. Strip absolute URLs.
