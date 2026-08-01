---
name: minikube-registry-host-5001-pod-5000
description: The local registry is localhost:5001 from the host but localhost:5000 from pods — both addresses, not a typo
metadata: { type: convention, date: 2026-08-01 }
---

The minikube registry addon is reached at **two different ports depending on which
side you are on**, and both are correct:

- **Host side (builds/pushes): `localhost:5001`** — `deploy/scripts/cluster.sh` runs
  `kubectl port-forward -n kube-system service/registry 5001:80` in the background
  (PID file in `deploy/.run/`). `k8s/images/build.sh` defaults `REGISTRY=localhost:5001`,
  and `k8s/images/Dockerfile.jvm`'s `ARG CORES_IMAGE` default is host-side too.
- **Pod side (image pulls): `localhost:5000`** — the addon's `registry-proxy` DaemonSet
  binds `hostPort: 5000` on *every* node and forwards to the ClusterIP Service. So
  `k8s/apps/base/*/deployment.yaml` and the `k8s/apps/overlays/aws/*` image-name
  mappings all reference `localhost:5000/<svc>:dev`.

Both addresses resolve to the **same in-cluster registry**, so the repository paths
match and an image pushed to `:5001` is pullable at `:5000`.

**Why:** the plan originally specified 5000 on both sides, but macOS Control Center
squats on host port 5000 (AirPlay Receiver). 5001 was chosen for the host-side
forward only; the pod side cannot move because the addon hardcodes hostPort 5000.

**How to apply:** do NOT "fix" a `localhost:5001` reference to 5000, or vice versa —
check which side the file runs on first. The Plan 1 acceptance criterion
"no `localhost:5001` references remain anywhere" is **obsolete** and must not be
enforced. If port 5001 is also taken, override with `MINIKUBE_REGISTRY_PORT` rather
than editing manifests. Related: [[eks-gp3-storageclass-must-precede-pvcs]].
