---
name: key-equals-value-config-hides-key-vs-topic-bugs
description: every `application.kafka.topics.<key>` maps to a value identical to its key, so code that sends to the KEY works by coincidence; test fixtures must use different names
metadata: { type: convention, date: 2026-10-08 }
---

In every env (`application.yml`, `deploy/secrets/*`, goldens) the topic properties are
`order-service.order.failed-status: order-service.order.failed-status`. So passing a properties
key straight to `kafkaTemplate.send` works — the old `SagaTimeoutScheduler` did exactly that,
and PR0's first attempt reintroduced it via `CompensationReason.getTopicKey()`. A test fixture
that mirrors key == value can't catch it.

**Why:** the coincidence makes the wrong code indistinguishable from the right code until someone gives a topic an env-specific name.

**How to apply:** always resolve through `topic(key)` / `kafkaProperties.getTopics().get(key)`.
In tests, map keys to deliberately different names (`t.order.failed`) — see
`SagaOrchestrationServiceImplTest` setUp. Related: [[0009-kafka-consumer-scaling-design]].
