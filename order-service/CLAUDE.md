# order-service

Orders + shopping carts. MySQL master/slave. Calls inventory via gRPC. Saga is triggered downstream of this service via Mongo CDC.

## Port & path
- App: `9696`
- Context path: `/order-service`

## Layout
- `controller/` — `/v1/orders`, `/v1/shopping-carts`
- `service/impl/` — `OrderServiceImpl`, `ShoppingCartServiceImpl` (manual `@Bean` wiring in `configuration/OrderServiceConfiguration`)
- `client/` — Feign + gRPC clients (inventory)
- `repository/master/` writes, `repository/slave/` reads — including `SlaveShoppingCartItemRepo` for the upsert path
- `scheduler/` — periodic jobs (e.g. abandoned cart sweeps)
- `listener/` — Kafka consumers (payment events)
- `resources/db/` — migrations

## Cart upsert (don't break this)
"Add N of X" must call slave repo to find existing line, merge quantity, then write through master. Blind insert creates duplicate rows. See `memory/feedback_cart_upsert.md`.

## Saga trigger
Order writes to MongoDB → Debezium → Kafka topic → orchestrator-service starts the saga. **Do not** call orchestrator directly. See `scripts/kafka/mongo-connector.sh`.

## Bean wiring
Adding a constructor parameter to a service impl? Update the matching `@Bean` method in `OrderServiceConfiguration`. There are no `@Service` annotations.
