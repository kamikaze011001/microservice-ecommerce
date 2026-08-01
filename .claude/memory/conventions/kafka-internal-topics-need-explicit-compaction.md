---
name: kafka-internal-topics-need-explicit-compaction
description: Schema Registry and Kafka Connect refuse to start if auto-created internal topics got cleanup.policy=delete
metadata: { type: convention, date: 2026-08-01 }
---

`_schemas`, `connect-configs`, `connect-offsets`, and `connect-status` **must be
compacted topics**. Kafka's broker-side auto-creation makes them with the broker default
`cleanup.policy=delete`, and Schema Registry / Kafka Connect then refuse to start.

`k8s/infra/install.sh` now creates them explicitly (`--create --if-not-exists`) and then
`kafka-configs.sh --alter --add-config cleanup.policy=compact` on each, **after Kafka is
Ready but before Schema Registry and Kafka Connect are applied**.

**Why:** on a cold boot the dependent services can race ahead of any topic setup and
trigger auto-creation themselves. The failure is confusing because it looks like a
Schema Registry bug, and it is *sticky* — once a topic exists with the wrong policy, a
plain restart never repairs it. The `--alter` step is what makes the fix idempotent and
able to repair a cluster that already raced.

**How to apply:** never rely on auto-creation for these four. If Schema Registry or
Kafka Connect crashloops on a fresh cluster, check the topic policy before suspecting
config. Related: [[kafka-exporter-applies-after-kafka-ready]].
