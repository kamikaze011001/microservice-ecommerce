---
name: minikube-node-resources-only-apply-at-creation
description: minikube start --cpus/--memory are honored only when the profile is created; resumes silently revert to defaults
metadata: { type: convention, date: 2026-08-01 }
---

`minikube start --cpus=N --memory=M` is honored **only on first profile creation**. A
resume (`minikube start -p <profile>` on an existing profile) silently ignores both flags
and the node containers keep whatever Docker defaults they were last given.

`deploy/scripts/cluster.sh` compensates with `apply_node_limits()`, which loops
`minikube node list` and runs `docker update --cpus --memory --memory-swap` on each node
container. It is called on **both** `cmd_up` and `cmd_start`, precisely because the
resume path is the one that would otherwise drift.

**Sizing caveat on this machine:** the script requests 4 nodes × 4 CPUs × 6g = **24 CPUs
/ 24GB**, but Docker Desktop provides only **12 CPUs / 16GB**. This works because
`docker update --memory` sets a *cap*, not a reservation — but it leaves zero headroom.
If pods start getting OOMKilled once all 11 JVM services plus Kafka/MySQL×3/MongoDB are
running, suspect this over-subscription first, not the manifests. Tune via
`MINIKUBE_CPUS` / `MINIKUBE_MEMORY` / `MINIKUBE_NODES` rather than editing the script.

**How to apply:** never assume a resumed minikube profile has the sizing you originally
asked for — verify with `docker stats` or re-run the limits step. Related:
[[jvm-malloc-arena]] for the separate reason JVM pods show inflated RSS.
