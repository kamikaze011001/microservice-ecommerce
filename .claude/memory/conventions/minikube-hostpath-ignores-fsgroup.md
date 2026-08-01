---
name: minikube-hostpath-ignores-fsgroup
description: minikube-hostpath PVs are root-owned and don't honor fsGroup — Kafka and MongoDB need root chown initContainers
metadata: { type: convention, date: 2026-08-01 }
---

On minikube, the default `minikube-hostpath` StorageClass provisions volumes that are
**root-owned and do not reliably honor the pod's `fsGroup`**. Any container running as
a non-root UID that writes to a PVC fails at startup with permission errors.

Two statefulsets needed a `runAsUser: 0` initContainer that `chown`s the data dir before
the main container starts:

- `k8s/infra/manifests/kafka.yaml` — `prepare-data` chowns `/var/lib/kafka/data` to `1000:1000`
  (before Kafka formats storage).
- `k8s/infra/manifests/mongodb.yaml` — `prepare-data` chowns `/data/db` to `999:999`
  (alongside the pre-existing `prepare-keyfile` initContainer).

**Why:** kind's provisioner did honor fsGroup, so this class of failure did not exist
before the kind → minikube migration. It is a property of the provisioner, not of the
workloads — which is why the fix lives in the manifests rather than the images.

**How to apply:** when adding any new statefulset with a PVC whose container runs as
non-root, add the chown initContainer preemptively. Note the contrast with EKS, where
the gp3 CSI driver handles fsGroup correctly and these initContainers are harmless
no-ops. Related: [[eks-gp3-storageclass-must-precede-pvcs]].
