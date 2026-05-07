# Cart enrichment via BFF + two FE polish fixes — Design

## Goal

Make the cart page render real items, replace the `@<uuid>` greeting with the user's name, and stop the `BSelect` dropdown panel from showing through the form below it.

Three independent bugs, one spec because they ship together as the cart-flow polish pass.

## Bug 1 — header shows `@<uuid>`

**Cause.** `AppNav.vue` reads `username` from the auth store, which decodes the JWT `sub` claim. `JWTServiceImpl.generateToken` sets `sub = accountUserPrj.getUserId()` — a UUID. There is no `username` or `preferred_username` claim.

**Fix.** Frontend-only.

- `AppNav.vue`: drop `username` from the auth store import. Use `useProfileQuery()` (already exists at `src/api/queries/profile.ts`). Greeting becomes `HI, {NAME.toUpperCase()}` while the profile is loaded; empty string while loading or on error.
- `stores/auth.ts`: remove the `username` computed and the `decodeJwtSub` helper. Auth no longer pretends to expose a display name.
- One new component test: `AppNav` shows `HI, SON ANH` when `useProfileQuery` resolves with `{ name: 'Son Anh' }`.

## Bug 3 — `BSelect` dropdown bleeds through

**Cause.** `BSelect.vue` portals its content via Reka-UI's `<SelectPortal>` to `document.body`. Vue's `<style scoped>` adds a `data-v-xxxx` attribute to elements rendered by the component, but Reka's `SelectContent` root does not always carry that attribute through the portal, so `.b-select__content { background; border; box-shadow }` is missing in the rendered DOM. Highlighted-item background still works because Reka applies the `data-highlighted` attribute on the item element directly.

**Fix.** CSS-only.

- In `BSelect.vue`: keep trigger styles in the existing `<style scoped>` block. Add a sibling `<style>` (unscoped) block with `.b-select__content`, `.b-select__viewport`, `.b-select__item`, `.b-select__item[data-highlighted]`, and `.b-select__check`. All class names already prefixed `.b-select__*`, so no global collision risk.
- No tests; visual regression is verified manually at the gender field on `ProfilePage`.

## Bug 2 — cart appears empty

**Cause.** Two-layer mismatch on `GET /order-service/v1/shopping-carts`.

1. Shape: backend returns `{ data: { shopping_carts: [...] } }`; frontend reads `cart.data.value?.items` (always `undefined`, so `isEmpty` is always true).
2. Fields: backend `ShoppingCartResponse` has only `id, price, quantity, productId`. Frontend needs `name, image_url, unit_price, available_stock` for line items, summary, and the over-stock checkout guard.

The frontend page is correct; the backend never enriches against product/inventory.

### Architecture

```
[FE] /bff-service/v1/cart*  ──►  [bff-service]  ──►  [order-service]  /v1/shopping-carts*
                                       │                              (existing, unchanged)
                                       ├──►  [product-service]  /v1/products?ids=…  (NEW filter)
                                       └──►  [inventory-service] gRPC ListInventoryProducts (existing)
```

- **bff-service** owns the FE's cart contract (read + writes). Reads fan out and merge; writes pass through to order-service unchanged.
- **product-service** gains an `ids` query param on the existing `GET /v1/products`: when present, return only matching products (no paging).
- **order-service** is untouched. Its `/v1/shopping-carts*` routes stay reachable through the gateway but the FE stops calling them.
- **frontend** switches all four cart calls in `src/api/queries/cart.ts` from `/order-service/v1/shopping-carts*` to `/bff-service/v1/cart*`. Response shape now matches the page's existing expectations.

### bff-service additions

- `controller/CartController.java` — `@RequestMapping("/v1/cart")`. Routes: `GET /`, `POST /:add-item`, `PATCH /:update-item`, `DELETE /:delete-item`. All read `X-User-Id` from headers.
- `service/CartBffService.java` + `service/impl/CartBffServiceImpl.java` — orchestrates the fan-out for `GET`; the three writes delegate to `OrderFeignClient` and return its `BaseResponse` as-is.
- `client/OrderFeignClient.java` — extend the existing client with `getCart(userId)`, `addItem(userId, body)`, `updateItem(body)`, `deleteItem(itemId)` methods. All forward `X-User-Id` via the existing Feign request interceptor.
- `client/ProductFeignClient.java` — add `listByIds(Set<String> ids)` calling `/v1/products?ids=…`.
- `dto/response/CartView.java` and `dto/response/CartItemView.java` — snake-case via `@JsonNaming(SnakeCaseStrategy.class)`. `CartView { shopping_cart_id, user_id, items: List<CartItemView> }`. `CartItemView { shopping_cart_item_id, product_id, name, image_url, unit_price, quantity, available_stock }`.

### product-service additions

- `ProductController.list(...)` accepts an optional `ids` query param (`@RequestParam(required = false) Set<String> ids`). When present, returns matched products without paging; when absent, behaviour is unchanged.
- `ProductRepository.findAllByIdIn(Collection<String> ids)` — Spring Data derived query.
- One repository test, one controller test.

### Data flow — `GET /bff-service/v1/cart`

1. Receive request with `X-User-Id`.
2. `OrderFeignClient.getCart(userId)` → `List<{id, productId, price, quantity}>` from order-service.
3. If empty, return `{ shopping_cart_id: "cart-" + userId, user_id: userId, items: [] }`.
4. Collect distinct `productIds`. Run **in parallel**:
   - `ProductFeignClient.listByIds(productIds)` → `Map<productId, {name, imageUrl}>`
   - `InventoryGrpcClientService.fetchInventory(productIds)` → `Map<productId, stock>`
   Use `CompletableFuture.supplyAsync` + `allOf().join()`.
5. Merge by `productId` into `CartItemView` rows:
   - `shopping_cart_item_id` ← order-service row `id`
   - `unit_price` ← order-service row `price` (snapshot at add-time)
   - `quantity` ← order-service row `quantity`
   - `name`, `image_url` ← product-service map; if missing (product was deleted), **drop the row** and log a warning
   - `available_stock` ← inventory map; if missing, default to `0`
6. Wrap in `BaseResponse.ok(cartView)`.

### Data flow — writes

`POST /:add-item`, `PATCH /:update-item`, `DELETE /:delete-item` are 1:1 forwards to `OrderFeignClient`. BFF returns whatever order-service returns. No body re-shaping.

### Auth & gateway

- `docker/api_role.json`: add four `USER`-required rules for `/bff-service/v1/cart*` matching the action-verb paths. Existing `/order-service/v1/shopping-carts*` rules stay (routes still exist).
- `FeignClientConfig` already forwards headers; verify `X-User-Id` propagates to order-service in a smoke test.

### Error handling

- `503 CART_UPSTREAM_UNAVAILABLE` if product-service or inventory-service is unreachable. FE's existing `cart.isError.value` branch shows the retry button.
- Empty cart → `200 { items: [] }`.
- Product missing for a row → drop row + warn (don't fail whole request).
- Inventory missing for a row → keep row with `available_stock = 0` (FE will gate checkout via `hasOverStock`).

### Testing

- **bff-service**: unit test `CartBffServiceImpl` with Mockito-mocked Feign + gRPC clients. Cases: empty cart, normal merge, product missing, inventory missing, product-service throws, inventory-service throws.
- **product-service**: repo test for `findAllByIdIn`, controller test for `?ids=` filter (returns subset, ignores paging).
- **frontend**: existing cart tests mock `@/api/queries/cart` so URL changes inside the module don't affect them. Add one new `AppNav` test for the profile-driven greeting. No test for Bug 3.

## Out of scope (flagged, not fixed)

- **Client-supplied `price` on add-to-cart**: real trust-boundary smell — order-service should look up price from product-service, not accept it from the client. Worth a follow-up.
- **BFF caching of product metadata**: helpful for hot cart loads, premature for v1.
- **Synthetic `shopping_cart_id`**: BFF returns `"cart-" + userId` to match the FE type; the FE never reads the field. Could be dropped from the contract entirely later.

## Migration / rollout

No DB migrations. Cart endpoints overlap (BFF and order-service both serve `cart`/`shopping-carts`); switching is a frontend URL change only. Old order-service routes can be deprecated in a follow-up once the BFF path is stable.
