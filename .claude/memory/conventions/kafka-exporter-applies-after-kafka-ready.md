---
name: kafka-exporter-applies-after-kafka-ready
description: kafka-exporter exits immediately when no broker is reachable, so it must be applied after Kafka is Ready, not alongside it
metadata: { type: convention, date: 2026-08-01 }
---

`kafka-exporter` **exits immediately** if it cannot reach a broker at startup. Applying
it in the same `kubectl apply` batch as the other exporters means it races Kafka's
StatefulSet and burns restarts before Kafka is up — often exhausting the Deployment's
progress deadline, after which `rollout status` fails even once Kafka is healthy.

`k8s/infra/install.sh` now:
1. Applies it **after** `rollout status statefulset/kafka` succeeds (moved out of the
   batch `kubectl apply` that still carries `mysqld-exporter.yaml`).
2. Runs `kubectl -n infra rollout restart deployment/kafka-exporter` before waiting, so
   a reconcile of a cluster whose earlier cold start already blew the deadline recovers
   instead of failing permanently.

**Why:** the restart line looks redundant on a fresh install and is easy to "clean up" —
it exists purely for the re-run case, where the Deployment is already wedged in a failed
progress state that a plain apply will not clear.

**How to apply:** any sidecar/exporter that hard-exits on an unreachable dependency needs
the same treatment — order it after the dependency's rollout, and add the restart for
idempotency. Related: [[kafka-internal-topics-need-explicit-compaction]].
