# product-service

Product catalog: CRUD, search, image management. MongoDB-backed.

## Port & path
- App: `7777`
- Context path: `/product-service`
- Vault imports: `secret/product-service`, `secret/core-s3`

## Layout
- `controller/` — REST endpoints (`/v1/products`, image presign + finalize)
- `service/impl/` — manual `@Bean` wiring
- `repository/` — MongoDB repos (no master/slave — Mongo handles replication itself)
- `entity/` — Mongo documents
- `listener/` — Kafka consumers (e.g. `ProductQuantityUpdatedEvent` from inventory)

## Image uploads
`core-s3` presign flow:
1. `POST /v1/products/{id}/image/presign` → `{uploadUrl, objectKey, expiresAt}` (5MB cap, Content-Type pinned)
2. Client `PUT`s bytes
3. `PUT /v1/products/{id}/image` with `{objectKey}` — server HEAD-checks key prefix `products/{productId}/...` then stores public URL

## Saga
This service emits `MongoSavedEvent` via Kafka Connect (Debezium MongoDB connector → `mongo-connector.sh`). The orchestrator listens — saga is **not** triggered by direct calls. See root CLAUDE.md → "Saga trigger".

## Public reads
`GET /product-service/v1/products/**` is `PERMIT_ALL` at the gateway — storefront browse works without auth.
