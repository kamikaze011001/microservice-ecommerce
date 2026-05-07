# core-order-cache

Redis-backed cache helpers specific to order/cart hot paths.

## Layout
- `configuration/` — Redis template / serializer wiring (uses `core-redis` for connection)
- `repository/` + `repository/impl/` — cache repository contracts and impls
- `constant/` — key prefix constants, TTLs

## Convention
Key naming is **load-bearing** — they're consumed by other services / dashboards. Don't rename keys without a migration plan. TTLs are intentional (carts expire, order summaries refresh) — change them with the order-service team.

## Relationship to core-redis
`core-redis` provides the connection + generic ops. `core-order-cache` adds order-domain-specific repository abstractions on top.
