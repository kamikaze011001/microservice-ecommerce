# bff-service

Backend-for-frontend aggregator. Fan-out Feign calls to other services, shape responses for the SPA.

## Port & path
- App: `8087`
- Context path: `/bff-service`
- No DB. No master/slave. Pure HTTP fan-out.

## Layout
- `controller/` — `BffController` (homepage, product detail), `CartController` (cart fan-out)
- `client/` — Feign interfaces (`ProductFeignClient`, `OrderFeignClient`, `PaymentFeignClient`, …)
- `service/impl/` — orchestration (manual `@Bean` wiring as elsewhere)
- `dto/response/` — frontend-shaped DTOs

## Critical gotchas

### Feign paths must include the target's context-path
Other services have `server.servlet.context-path: /<service-name>`. Feign calls go service-to-service via the **gateway's load-balanced route**, so paths are `/<target-service>/v1/...`, e.g. `@GetMapping("/order-service/v1/shopping-carts")`. See commit `4695052`.

### snake_case map keys (THE big footgun)
When a Feign response is deserialized as `Map<String, Object>` instead of a typed DTO, **map keys are snake_case** (downstream DTOs use `@JsonNaming(SnakeCaseStrategy)`). `row.get("productId")` silently returns `null`; the real key is `product_id`. See root CLAUDE.md → "Cross-service JSON".

### Cart endpoints
`/v1/cart`, `/v1/cart:add-item`, `/v1/cart:update-quantity`, `/v1/cart:remove-item`. Colon-action paths must be **absolute on the method annotation** (no class-level `@RequestMapping`) — otherwise Spring inserts a slash and the route breaks. See root CLAUDE.md.

### Cart upsert
"Add N of X" must look up existing line and merge quantity (slave repo lookup → master upsert), not blind insert. See `memory/feedback_cart_upsert.md`.
