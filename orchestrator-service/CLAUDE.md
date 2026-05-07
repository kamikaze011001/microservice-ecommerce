# orchestrator-service

Saga coordinator for distributed order transactions. Listens to Mongo CDC events, drives compensating transactions on failure.

## Port
- App: `9999`
- No HTTP API exposed at the gateway — purely event-driven.

## Layout
- `eventhandler/` — Kafka listeners for each saga step
- `service/impl/` — saga state machine
- `scheduler/` — timeout/retry jobs
- `entity/` + `repository/` — saga state persistence
- `listener/` — debezium / Mongo CDC consumers

## Trigger
Saga starts on `MongoSavedEvent` from product-service / order-service via the Debezium MongoDB connector (`scripts/kafka/mongo-connector.sh` registers the connector with Kafka Connect). **Nothing calls orchestrator directly.**

## Event vocabulary
Defined in `core/common-dto/src/main/java/.../event/`:
- `PaymentSuccessEvent`, `PaymentFailedEvent`, `PaymentCanceledEvent`
- `ProductUpdateEvent`, `ProductQuantityUpdatedEvent`
- `MongoSavedEvent` (CDC envelope)

## CI test guard
`contextLoads` test is guarded so it passes without Kafka/Vault/MySQL — this service is the **reference implementation** for that pattern. Mirror it when adding new services. See root CLAUDE.md → "Tests in CI without infra".
