# core-redis

Redis connection + generic key/value helpers. Foundation for `core-order-cache` and any service caching directly.

## Layout
- `configuration/` — `RedisConnectionFactory`, `RedisTemplate`, serializer config
- `repository/` + `repository/impl/` — generic cache ops (get/set/expire/delete)
- `constant/` — common key prefixes

## Convention
- Connection details (host, port, password) from Vault.
- A service that imports this module **must** include `redis` in `management.endpoint.health.group.readiness.include` — otherwise readiness lies during a Redis outage. Authorization-server is the reference.
- Use `core-order-cache` for order/cart-specific caching; use this module directly only for service-local caches.
