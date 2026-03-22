# Saga Orchestrator Design

**Date:** 2026-03-22
**Status:** Approved
**Scope:** Upgrade `orchestrator-service` from choreography-based event router to true Saga Orchestrator for the Order-Payment flow

---

## Problem Statement

The current `orchestrator-service` is a stateless event router (`EventListenerHandler`) — it reacts to CDC events and forwards them to downstream Kafka topics. It has no state tracking, no coordination ownership, and no compensation logic. This is choreography, not orchestration.

A true Saga Orchestrator owns the state machine for distributed transactions and drives each step explicitly, including compensation on failure.

---

## System Context: Three Flows

| Flow | Trigger | Type | Change Needed |
|---|---|---|---|
| 1. Order-Payment Saga | `Order.Created` | Stateful — needs SagaInstance | Yes |
| 2. Product Catalog Sync | `Product.Updated` | Stateless routing | No change |
| 3. Inventory Quantity Sync | `Product.Quantity.Updated` | Stateless routing | No change |

**CDC as reply bus:** Instead of dedicated Kafka reply topics, the orchestrator uses the existing MongoDB CDC pipeline. When downstream services write events to MongoDB, the CDC connector publishes them to Kafka and the orchestrator reads them as replies. Correlation is by `orderId` extracted from the CDC event payload. This is valid Saga Orchestration — the orchestrator still owns the state machine; only the transport mechanism differs.

**CDC event schema:** The MongoDB Kafka Connector watches the `ecommerce_inventory` database, `event` collection (topic: `ecommerce_db.ecommerce_inventory.event`). Every service — including order-service — writes its `MongoSavedEvent` to this same collection via `MongoSavedEventListener`. Each document has the shape `{id, name, data}` (matching `EventDTO`). The `data` field contains `orderId` for payment events. Order.Created will use the same mechanism: `MongoSavedEvent("Order.Created", {orderId})` → persisted to `ecommerce_inventory.event` → CDC → orchestrator. **No new infrastructure required.**

---

## Flow 1: Order-Payment Saga

### Prerequisites (pre-saga, unchanged)
Before the saga starts, `order-service` already:
1. Validates inventory synchronously via gRPC to `inventory-service`
2. Atomically reserves inventory in Redis via Lua script
3. Saves order to MySQL with status `PROCESSING`

The saga begins **after** inventory is reserved.

---

### State Machine

```
STARTED
  └─► [send command to payment-service topic]
      └─► AWAITING_PAYMENT
            ├─► Payment.Success  ──► CONFIRMING
            │                          ├─► [confirm succeeds] ──► COMPLETED
            │                          └─► [confirm fails]    ──► COMPENSATING
            │                                                        └─► COMPENSATED
            ├─► Payment.Failed   ──► COMPENSATING
            │                          └─► COMPENSATED
            ├─► Payment.Canceled ──► COMPENSATING
            │                          └─► COMPENSATED
            └─► [timeout]        ──► COMPENSATING
                                       └─► COMPENSATED
```

**Terminal states:** `COMPLETED`, `COMPENSATED`, `FAILED`

`FAILED` is reached when compensation itself cannot be completed after exhausting retries (e.g., the compensation Kafka publish fails repeatedly). A saga in `FAILED` requires manual intervention and alerting.

**Timeout / late reply:** A saga timed out and moved to `COMPENSATING` will discard any late-arriving `Payment.Success` CDC event via the terminal-state idempotency check. If a payment was actually captured before the timeout, this creates an unrecoverable payment without a matched order. Mitigation: the `expiresAt` TTL (30 minutes) is deliberately generous to minimize this window; the payment-service PayPal order also expires, limiting the capture window. A dead-letter alert should be raised for any saga that is timed out while already COMPENSATED when a Payment.Success arrives.

---

### Compensation Detail

**On Payment.Success → CONFIRMING:**
1. Send `PaymentSuccess{orderId}` Avro to `order-service.order.success-status` → order status → `COMPLETED`
2. Send `PaymentSuccess{orderId}` Avro to `inventory-service.inventory-product.update-quantity` → deduct stock, release Redis reservation

Both messages use the same `PaymentSuccess` Avro type and same Kafka topics as the current system — confirming inventory-service and order-service require **no internal changes** on the success path.

**On Payment.Failed / Payment.Canceled / Timeout → COMPENSATING:**
1. Send to `order-service.order.failed-status` or `order-service.order.canceled-status`
2. `order-service` internally releases Redis reservation in `handleFailedOrder()` / `handleCanceledOrder()`

No separate inventory compensation step needed on failure — `order-service` owns the Redis release.

**Compensation reliability:** Kafka publishing is at-least-once. Downstream services (`order-service`, `inventory-service`) use the existing `ProcessedPaymentEvent` unique compound index `(orderId, eventType)` for deduplication — idempotent consumers. The orchestrator retries the compensation Kafka publish on failure up to a configurable max (default 3); after exhausting retries, the saga transitions to `FAILED`.

---

## SagaInstance Data Model

Stored in MySQL (master). One row per order.

```sql
CREATE TABLE saga_instance (
    id            VARCHAR(36) PRIMARY KEY,
    order_id      VARCHAR(36) NOT NULL UNIQUE,
    state         ENUM('STARTED','AWAITING_PAYMENT','CONFIRMING','COMPENSATING',
                       'COMPLETED','COMPENSATED','FAILED') NOT NULL,
    version       INT NOT NULL DEFAULT 0, -- optimistic locking
    created_at    DATETIME NOT NULL,
    updated_at    DATETIME NOT NULL,
    expires_at    DATETIME NOT NULL       -- createdAt + 30 minutes
);
```

- `orderId` unique — one saga per order, used for CDC correlation
- No `paymentId` column — the `PaymentSuccess` CDC event only carries `orderId` (confirmed: `PaymentSuccess` Avro schema has a single field). The PayPal capture ID is in the MySQL `payment.capture_id` column, queryable if a refund is ever needed.
- `version` — JPA `@Version` field for optimistic locking; prevents race conditions when concurrent CDC events or the timeout scheduler attempt to transition the same saga simultaneously
- No `failureReason` field — deliberate design decision; the order's own status record is the source of truth for failure details

---

## Component Breakdown

### New Components (orchestrator-service)

| Component | Role |
|---|---|
| `SagaInstance` | JPA entity; includes `@Version` for optimistic locking |
| `SagaInstanceRepository` | Spring Data JPA repo; includes `findByOrderId` and `findExpiredSagas` queries |
| `SagaOrchestrationService` | Core logic — `startSaga(orderId)`, `handlePaymentReply(event)`, `compensate(sagaId)` |
| `SagaTimeoutScheduler` | `@Scheduled` — detects expired `AWAITING_PAYMENT` sagas, triggers compensation |

### Modified Components

| Component | Change |
|---|---|
| `MongoEventListener` | Route `Order.Created` → `SagaOrchestrationService.startSaga()`. Route `Payment.*` → `SagaOrchestrationService.handlePaymentReply()` |
| `EventListenerHandler` | Remove `handlePaymentSuccess`, `handlePaymentFailed`, `handlePaymentCanceled`. Keep `handleProductQuantityUpdated` and `handleProductUpdate` (Flows 2 & 3) |
| `EcommerceEvent` (common-dto) | Add `ORDER_CREATED("Order.Created", OrderCreatedEvent::new)`. This is a shared module — only the orchestrator-service and order-service consume/produce this event; no other service is affected |
| `order-service` `OrderServiceImpl` | After Redis reservation succeeds (`create()` method), publish `MongoSavedEvent("Order.Created")` with payload `{orderId}`. No other changes |

### Unchanged
- Flows 2 & 3 in `EventListenerHandler`
- `order-service` Kafka listeners (success/failed/canceled)
- `inventory-service`, `product-service`, `payment-service` internal logic

---

## Concurrency & Safety

**Optimistic locking:** `SagaInstance` uses `@Version` (JPA optimistic locking). If two threads attempt to transition the same saga simultaneously (e.g., a CDC event and a timeout firing at the same instant), one will get an `OptimisticLockException` and retry or discard.

**Idempotency at orchestrator level:** Before any state transition, `SagaOrchestrationService` checks if the saga is already in a terminal state (`COMPLETED`, `COMPENSATED`, `FAILED`). This check and the subsequent state update are performed within a single `@Transactional` boundary to prevent TOCTOU races.

**Distributed lock for scheduler:** `SagaTimeoutScheduler` acquires a Redisson distributed lock (already available in the project) before querying and processing expired sagas. This prevents multiple orchestrator-service instances from double-compensating the same saga on timeout.

**Unknown orderId:** If a CDC event arrives with an `orderId` that has no matching `SagaInstance`, `SagaOrchestrationService` logs a warning and discards the event. This handles pre-migration orders and replayed CDC events from before the saga was introduced.

**Duplicate Order.Created (startSaga idempotency):** Kafka delivers at-least-once. If `Order.Created` is delivered twice for the same `orderId`, the second `startSaga` call will hit the `order_id UNIQUE` constraint. `SagaOrchestrationService.startSaga()` catches `DataIntegrityViolationException`, logs a warning, and returns — the existing `SagaInstance` is used. The first delivery wins.

**Crash recovery:** If the orchestrator crashes after publishing a Kafka command but before updating `SagaInstance` state, the state machine remains in the previous state. On CDC reply arrival (or timeout), it will attempt the transition again — which is safe given idempotent downstream consumers. There is no full transactional outbox in this design; the risk window is small (in-memory JVM crash between two fast operations). This is an accepted trade-off; a full outbox pattern is a future improvement.

---

## Timeout Handling

`SagaTimeoutScheduler` runs every 1 minute (configurable via `application.saga.timeout-check-interval`):
1. Acquire Redisson distributed lock
2. Query: `SELECT * FROM saga_instance WHERE state = 'AWAITING_PAYMENT' AND expires_at < NOW()`
3. For each result: call `SagaOrchestrationService.compensate()` → `COMPENSATING` → `COMPENSATED`

---

## Files Affected

```
common-dto/
  src/.../event/EcommerceEvent.java             — add ORDER_CREATED enum constant
  src/.../event/OrderCreatedEvent.java           — new event class (orderId payload)

order-service/
  src/.../service/impl/OrderServiceImpl.java     — publish Order.Created after reservation in create()

orchestrator-service/
  src/.../entity/SagaInstance.java               — new JPA entity (@Version, paymentId)
  src/.../repository/SagaInstanceRepository.java — new
  src/.../service/SagaOrchestrationService.java  — new (startSaga, handlePaymentReply, compensate)
  src/.../scheduler/SagaTimeoutScheduler.java    — new (distributed lock, 1-min interval)
  src/.../listener/MongoEventListener.java       — route Order.Created + Payment.* to orchestration service
  src/.../eventhandler/EventListenerHandler.java — remove 3 payment handler methods
  src/main/resources/application.yml            — add saga.timeout-check-interval, saga.compensation-max-retries
```
