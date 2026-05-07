# common-dto

Shared DTOs, events, exceptions consumed by every service. **Touch with care** — anything you change ripples across the whole stack.

## Layout
- `request/` + `response/` — shared request/response DTOs (e.g. `BaseResponse`, `PagingRequest`)
- `event/` — Kafka event payloads (`PaymentSuccessEvent`, `ProductQuantityUpdatedEvent`, `MongoSavedEvent`, …)
- `exception/` — common exception types
- `resources/avro/` — Avro schemas registered with Confluent Schema Registry

## Conventions
- All DTOs annotated `@JsonNaming(SnakeCaseStrategy)` — wire format is snake_case (see root CLAUDE.md "Cross-service JSON")
- `BaseResponse` constructed via static factories: `BaseResponse.ok(data)`, `.created(data)`, `.notFound(data)`, …
- `PagingRequest`: `page` is **1-indexed** (min 1), `size` defaults to 10. Convert to 0-indexed before passing to Spring Data / MongoTemplate.

## Avro
Event payloads serialized with Avro. When adding/modifying an event, regenerate Java sources and bump schema in registry. Schema-incompatible changes break consumers in production — coordinate.

## Build
This is a `core` module — install before services: `make build` (wraps `scripts/maven/install-modules.sh`). Maven build order matters here.
