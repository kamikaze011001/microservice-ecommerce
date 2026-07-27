---
name: eks-gp3-storageclass-must-precede-pvcs
description: Fresh EKS ships gp2 as default; our infra statefulsets name no storageClassName, so the gp3 SC MUST be applied before any PVC or the whole bring-up stalls
metadata: { type: convention, date: 2026-07-24 }
---

The AWS infra statefulsets (`k8s/infra/manifests/{mongodb,kafka}.yaml`) carry
`volumeClaimTemplates` with **no `storageClassName`** — by design, so the same
manifest binds `local-path` on kind and real EBS on EKS via whatever the cluster's
**default** StorageClass is.

**The trap:** a *fresh* EKS cluster ships **gp2** as the default (in-tree
`kubernetes.io/aws-ebs`, ext4 → hits Kafka's `lost+found` crash), and our correct
class `gp3` (`k8s/infra/overlays/aws/storageclass-gp3.yaml`: ebs.csi.aws.com, xfs,
encrypted, `WaitForFirstConsumer`) was **never applied by anything** in the
`make aws-all` flow. Result: PVCs `data-kafka-0`/`data-mongodb-0` sit `Pending`,
the pods stay `Pending`, and `infra-up.sh`'s `kubectl rollout status --timeout=8m`
times out. Because the script runs under `set -euo pipefail`, that non-zero exit
**aborts the entire script** — Schema Registry, Kafka Connect, VictoriaMetrics,
Grafana, and the CDC connector never get applied. One missing SC = ~60% of Step 3
silently skipped.

**Fix (durable, shipped this session):** `scripts/aws/infra-up.sh` now applies the
gp3 SC and demotes gp2 **right after namespace creation**, before any statefulset:
```bash
kubectl apply -f k8s/infra/overlays/aws/storageclass-gp3.yaml
kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true
```
Both are idempotent, so re-runs are safe.

**Why a live patch was enough to unblock the running cluster:** K8s 1.28+
`RetroactiveDefaultStorageClass` (GA) — a `Pending` PVC with nil `storageClassName`
**retroactively adopts** a newly-added default class, so applying gp3 after the fact
bound the already-created PVCs without recreating them.

**Rule:** the default StorageClass must exist *before* the first PVC. Never rely on
"the cluster probably has a good default" — a fresh EKS does not. Related:
[[nested-claude-md-loads-only-in-scope]].
