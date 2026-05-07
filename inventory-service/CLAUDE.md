# inventory-service

Stock management. MySQL + gRPC server for internal calls from order-service.

## Ports & path
- HTTP: `6969`
- gRPC: `9090`
- Context path: `/inventory-service`
- order-service waits for **both** ports to be listening before it starts (drift guard in `scripts/services/start.sh`).

## Layout
- `controller/` — REST (admin-facing stock ops)
- `grpc/server/` — gRPC service implementations (proto in `core/grpc-common`)
- `service/` — manual `@Bean` wiring
- `repository/master/` writes, `repository/slave/` reads, `repository/projection/` views
- `entity/` — JPA: `inventory_product`, `product_quantity_history`
- `listener/` — Kafka consumers (product create/update events)
- `resources/db/` — Liquibase / Flyway migrations

## Seed-data gotcha
After `make bootstrap`, both `inventory_product` AND `product_quantity_history` need rows or the cart shows "0 available". Both seed SQLs must run. See `memory/project_inventory_seed.md`.

## Tier
Tier 2 — boots after eureka + auth + gateway, before product/order/payment.
