# order-service

Orders + shopping carts. MySQL master/slave. Calls inventory via gRPC. Saga is triggered downstream of this service via Mongo CDC.

## Port & path
- App: `9696`
- Context path: `/order-service`

## Layout
- `controller/` — `/v1/orders`, `/v1/shopping-carts`
- `service/impl/` — `OrderServiceImpl`, `ShoppingCartServiceImpl` (manual `@Bean` wiring in `configuration/OrderServiceConfiguration`)
- `client/` — Feign + gRPC clients (inventory)
- `repository/master/` writes, `repository/slave/` reads
- `scheduler/` — periodic jobs (e.g. abandoned cart sweeps)
- `listener/` — Kafka consumers (payment events)
- `resources/db/` — migrations

## Cart upsert (don't break this)
"Add N of X" is a DB-atomic upsert: unique key `uq_cart_product` on
`(shopping_cart_id, product_id)` + native `INSERT ... ON DUPLICATE KEY UPDATE`
on the master repo (`MasterShoppingCartItemRepo.upsertItem`; quantities sum,
price = latest). Do NOT reintroduce a check-then-insert via a slave read — the
slave lags under load and concurrent adds both see "absent" → duplicate rows
(stress run 2026-06-10, NonUniqueResultException ×269). Blind insert is equally
wrong. See `docs/performance-stress-report-2026-06-10.md` P1.

## Saga trigger
Order writes to MongoDB → Debezium → Kafka topic → orchestrator-service starts the saga. **Do not** call orchestrator directly. See `scripts/kafka/mongo-connector.sh`.

## Bean wiring
Adding a constructor parameter to a service impl? Update the matching `@Bean` method in `OrderServiceConfiguration`. There are no `@Service` annotations.
