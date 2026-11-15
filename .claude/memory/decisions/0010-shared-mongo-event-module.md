---
name: 0010-shared-mongo-event-module
description: the CDC `event` writer lives in core/core-mongo-event — MongoTemplate, AFTER_COMMIT with fallbackExecution, synchronous; replaces 4 divergent per-service copies
metadata: { type: decision, date: 2026-10-08 }
---

`core/core-mongo-event` owns `Event` (with top-level `aggregateId`), `MongoSavedEventListener`
and `@EnableMongoEvent`. Only order/payment/inventory/product depend on it. The listener is
`@TransactionalEventListener(AFTER_COMMIT, fallbackExecution = true)`, **not** `@Async`, writes
via `MongoTemplate.insert`, and rejects a blank `aggregateId`.

**Why:**
- Not in `common-dto`: putting a Mongo `@Document` there drags the Mongo starter into every
  service, and Boot then auto-configures a client + a failing `mongo` health check where there is no Mongo.
- The 4 copies had diverged: only order-service wrote after commit; the other 3 wrote before
  commit → phantom events on rollback (e.g. `Payment.Canceled` for a payment that never changed).
- `fallbackExecution`: product-service publishes outside a transaction; an after-commit listener drops those silently otherwise.
- No `@Async`: async writes can land out of order before Kafka sees them, which keys can't repair.
- `MongoTemplate`, not a repository: a repository in the module isn't under each service's scan
  root, and `@EnableMongoRepositories` in a shared module turns off auto-discovery of the services' own repositories.

**How to apply:** new event writers call `new MongoSavedEvent(this, name, aggregateId, data)` — the aggregateId is the id inside the Avro payload. Still a dual write (MySQL + Mongo): a crash between them loses the event; the fix is a transactional outbox (deferred). Related: [[0009-kafka-consumer-scaling-design]].
