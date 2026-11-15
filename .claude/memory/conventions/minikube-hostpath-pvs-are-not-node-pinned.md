---
name: minikube-hostpath-pvs-are-not-node-pinned
description: minikube's standard class makes hostPath PVs with no nodeAffinity; a stateful pod that moves node silently gets an empty/stale copy
metadata: { type: convention, date: 2026-10-21 }
---

On a multi-node minikube, `standard` (k8s.io/minikube-hostpath) PVs have **no
`nodeAffinity`**. The data lives on the node the pod first ran on; a pod scheduled
elsewhere mounts the same path on the new node, which is empty or stale. Nothing
errors. Copies of `data-mysql-0` existed on three nodes. During the fix, the
registry restarted onto an empty directory while its 2.9 GB sat on m04.

Fixed in PR #87:
- `cluster.sh ensure_pinned_storage`: `local-path` (storage-provisioner-rancher
  addon) is the default class, so new PVs carry `nodeAffinity`.
- `make k8s-pin-volumes`: one-off for existing PVs (immutable affinity → recreate the PV).

Rules learned while pinning:
- Set the PV to **Retain before deleting the PVC**, or `Delete` wipes the directory.
- Pick the node by **where the data is**, not where the pod runs now. A pod that just
  restarted may already be on the wrong copy.
- Wait on pods that **mount the claim**, not on the selector: the registry
  Deployment's selector also matches the registry-proxy DaemonSet.

**How to apply:** before restarting or resizing anything stateful on minikube, check
`kubectl get pv -o jsonpath='{..nodeAffinity}'`. Prove data survived with
service-level fingerprints (row counts, git HEAD, repo counts), not file counts:
MinIO clears `.minio.sys/tmp` on start. Related: [[a-capped-docker-node-reports-the-whole-vm]],
[[minikube-hostpath-ignores-fsgroup]].
