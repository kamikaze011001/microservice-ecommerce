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

The orchestrator handles three distinct event flows. Only Flow 1 requires stateful orchestration.

| Flow | Trigger | Type | Change Needed |
|---|---|---|---|
| 1. Order-Payment Saga | `Order.Created` | Stateful — needs SagaInstance | Yes — new orchestration logic |
| 2. Product Catalog Sync | `Product.Updated` | Stateless routing | No change |
| 3. Inventory Quantity Sync | `Product.Quantity.Updated` | Stateless routing | No change |

**Key insight:** Instead of dedicated Kafka reply topics, the orchestrator uses the existing MongoDB CDC pipeline as its reply bus. When payment-service saves a payment event to MongoDB, the CDC connector publishes it to Kafka, and the orchestrator reads it as the "reply." Correlation is by `orderId` — the orchestrator looks up the `SagaInstance` by `orderId` from the CDC event payload.

This is still a valid Saga Orchestration pattern. The distinction is who owns the state machine (the orchestrator does), not the transport mechanism used for replies.

---

## Flow 1: Order-Payment Saga

### Prerequisites (unchanged, pre-saga)
Before the saga starts, `order-service` already:
1. Validates inventory synchronously via gRPC call to `inventory-service`
2. Atomically reserves inventory in Redis via Lua script
3. Saves the order to MySQL with status `PROCESSING`

The saga begins **after** inventory is already reserved.

### State Machine

```
STARTED
  └─► [orchestrator sends command to payment-service topic]
      └─► AWAITING_PAYMENT
            ├─► Payment.Success  ──► CONFIRMING
            │                          └─► [notify order + inventory services]
            │                              └─► COMPLETED
            ├─► Payment.Failed   ──► COMPENSATING
            │                          └─► [notify order-service]
            │                              └─► COMPENSATED
            └─► Payment.Canceled ──► COMPENSATING
                                       └─► [notify order-service]
                                           └─► COMPENSATED
```

**Terminal states:** `COMPLETED`, `COMPENSATED`, `FAILED`

### Compensation Detail

**On Payment.Success:**
1. Send to `order-service.order.success-status` → order status → `COMPLETED`
2. Send to `inventory-service.inventory-product.update-quantity` → deduct stock, release Redis reservation

**On Payment.Failed / Payment.Canceled:**
1. Send to `order-service.order.failed-status` or `order-service.order.canceled-status`
2. `order-service` already handles Redis reservation release internally in `handleFailedOrder()` / `handleCanceledOrder()`

No extra compensation step needed for inventory on failure — `order-service` owns that responsibility.

**Idempotency:** Before processing any CDC reply, `SagaOrchestrationService` checks if the saga is already in a terminal state. If yes, log and skip — prevents double-compensation from duplicate CDC events.

---

## SagaInstance Data Model

Stored in MySQL (master). One row per order.

```sql
CREATE TABLE saga_instance (
    id          VARCHAR(36) PRIMARY KEY,
    order_id    VARCHAR(36) NOT NULL UNIQUE,
    state       ENUM('STARTED','AWAITING_PAYMENT','CONFIRMING','COMPENSATING',
                     'COMPLETED','COMPENSATED','FAILED') NOT NULL,
    created_at  DATETIME NOT NULL,
    updated_at  DATETIME NOT NULL,
    expires_at  DATETIME NOT NULL
);
```

- `orderId` is unique — one saga per order, used for CDC correlation
- `expiresAt` = `createdAt + 30 minutes` — used by timeout scheduler
- No `failureReason` field — the order's own status record is the source of truth for failure details

---

## Component Breakdown

### New Components (orchestrator-service)

| Component | Role |
|---|---|
| `SagaInstance` | JPA entity for the state machine row |
| `SagaInstanceRepository` | Spring Data JPA repository |
| `SagaOrchestrationService` | Core logic — creates sagas, drives transitions, sends Kafka commands |
| `SagaTimeoutScheduler` | `@Scheduled` — finds expired `AWAITING_PAYMENT` sagas, triggers compensation |

### Modified Components

| Component | Change |
|---|---|
| `MongoEventListener` | Route `Order.Created` events to `SagaOrchestrationService.startSaga()`. Route `Payment.*` events to `SagaOrchestrationService.handleReply()` |
| `EventListenerHandler` | Remove `handlePaymentSuccess`, `handlePaymentFailed`, `handlePaymentCanceled` (moved to `SagaOrchestrationService`). Keep `handleProductQuantityUpdated` and `handleProductUpdate` |
| `EcommerceEvent` (common-dto) | Add `ORDER_CREATED("Order.Created", OrderCreatedEvent::new)` |
| `order-service` `OrderServiceImpl` | After Redis reservation succeeds, publish `MongoSavedEvent("Order.Created")` with `orderId` in payload |

### Unchanged
- Flows 2 & 3 routing in `EventListenerHandler`
- `order-service` Kafka listeners for success/failed/canceled
- `inventory-service`, `product-service`, `payment-service` internal logic

---

## Timeout Handling

`SagaTimeoutScheduler` runs every 1 minute:
```
SELECT * FROM saga_instance
WHERE state = 'AWAITING_PAYMENT' AND expires_at < NOW()
```
For each expired saga → treat as `Payment.Canceled` → drive to `COMPENSATING` → `COMPENSATED`.

---

## What Does NOT Change

The following existing services need **no internal changes** to their business logic:
- `inventory-service` — already handles compensation in payment success path
- `payment-service` — already publishes MongoDB events on all payment outcomes
- `product-service` — unchanged
- `order-service` listeners — unchanged; only `OrderServiceImpl.create()` gets one new `MongoSavedEvent` publish call

---

## Files Affected

```
common-dto/
  src/.../event/EcommerceEvent.java          — add ORDER_CREATED
  src/.../event/OrderCreatedEvent.java        — new event class

order-service/
  src/.../service/impl/OrderServiceImpl.java  — publish Order.Created after reservation

orchestrator-service/
  src/.../entity/SagaInstance.java            — new JPA entity
  src/.../repository/SagaInstanceRepository.java — new
  src/.../service/SagaOrchestrationService.java  — new
  src/.../scheduler/SagaTimeoutScheduler.java    — new
  src/.../listener/MongoEventListener.java    — route Order.Created + Payment.*
  src/.../eventhandler/EventListenerHandler.java — remove 3 payment handlers
  src/main/resources/application.yml         — add saga timeout config
```
