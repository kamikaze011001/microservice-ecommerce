---
name: cold-cluster-image-pulls-outgrow-rollout-timeouts
description: kafka-connect needs 15m, not 10m — a cold-cluster Confluent image pull blew the rollout wait by 30 seconds and failed the whole bootstrap chain
metadata: { type: convention, date: 2026-08-07 }
---

`make k8s-bootstrap` failed on a fresh 4-node minikube with the opaque
`error: timed out waiting for the condition`. The deployment was healthy — the wait was too
short. Measured on the failing cluster (2026-08-07):

| wait | budget | actual | outcome |
|---|---|---|---|
| `kafka` | 5m | 1m42s | fine |
| `schema-registry` | 10m | 6m11s | ~4m margin |
| `kafka-connect` | 10m | **10m30s** (9m54s of it image pull) | **failed by 30s** |

Both Confluent images are ~1.8GB, but `kafka-connect` pulls *after* schema-registry on an
already-saturated cold cluster, so it cannot share the same budget. `install.sh` now gives it
15m; schema-registry stays at 10m because it has real headroom and no evidence of being tight.

**Why it cost so much:** `k8s-bootstrap` chains nine targets under make's fail-fast, so a 30-second
miss discarded the entire remaining run — image builds, seeds, apps. The cluster and infra
survived, so resuming was cheap, but this is an argument for Phase 6 making the long stages
independently resumable instead of one chain.

**How to apply:** when a `rollout status` / `kubectl wait` times out, get the pod's
`creationTimestamp` and its `Ready` condition `lastTransitionTime` before concluding anything —
the gap tells you whether it was a real failure or a short budget, and
`PodReadyToStartContainers` separates image-pull time from start-up time. Pods being healthy
*now* is not evidence the wait was wrong to fail; the timestamps are. Related:
[[helm-and-kubectl-deploy-paths-are-exclusive]], [[minikube-node-resources-only-apply-at-creation]].
