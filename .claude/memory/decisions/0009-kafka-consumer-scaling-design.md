---
name: 0009-kafka-consumer-scaling-design
description: Kafka consumer scaling = correctness first; per-aggregate keys, 12 partitions, concurrency 1, at-least-once + idempotent consumers, blocking retry → DLT, cooperative-sticky; shipped as PR0–PR5
metadata: { type: decision, date: 2026-10-08 }
---

Design agreed in a grilling session (2026-09-29) before scaling any consumer:

| Area | Decision |
|---|---|
| Ordering | per aggregate: same `orderId`/`productId` → same key → same partition |
| Semantics | at-least-once + idempotent consumers (not Kafka EOS — every consumer has non-Kafka side effects) |
| Partitions | 12 per business topic (divides 1/2/3/4/6/12), declared from ONE canonical topic list used by `topics.sh` + a k8s Job; `auto.create.topics.enable=false` |
| Concurrency | fixed `concurrency: 1`; scale by pods only; guard `maxReplicas × concurrency ≤ 12` |
| CDC key | top-level `aggregateId` on every `event` doc, projected by the connector |
| Producer | orchestrator sends keyed + ack-awaited (bounded 10 s) |
| Dedupe | state-guard where a state machine exists; inbox marker in the SAME tx for ledger/stock; never marker-before-work |
| Errors | blocking `DefaultErrorHandler` + backoff → `<topic>.DLT`; non-retryables straight to DLT; DLT metric/alert + `make dlt-replay`. NOT `@RetryableTopic` (breaks per-key order) |
| Rebalance | `CooperativeStickyAssignor`, no static membership |
| Out of scope | 3 brokers / RF 3; transactional outbox |

PR order: PR0 Avro mismatch fix (merged #66) → PR2 keys → PR1 partitions → PR3 idempotency + index seed + cleanup-job lock → PR4 DLT/assignor/`earliest` → PR5 `make kafka-chaos-proof`.

**Why:** a survey found scaling today would add no throughput (1 partition on k8s/AWS) and break correctness: null producer keys, CDC keyed by unique resume token, marker-before-work dedupe, and the dedupe unique index never created (`auto-index-creation` unset). The single partition was *hiding* the orchestrator's Created-before-Payment assumption — so keys must land before or with PR1, never after.

**How to apply:** follow the PR order; don't raise partitions on a branch without PR2's keys. Coworking markers use `[HUMAN ✍️ KAFKA-PR<n>.<step>]` (WHERE/WHAT/WHY/DONE), checked by `make check-human PR=<n>`. Related: [[0010-shared-mongo-event-module]].
