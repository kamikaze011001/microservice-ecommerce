---
name: a-capped-docker-node-reports-the-whole-vm
description: a minikube node container capped by docker update still reports the whole Docker VM to the kubelet; fix allocatable with systemReserved
metadata: { type: convention, date: 2026-10-21 }
---

`docker update --memory 6g` caps a minikube node container, but the kubelet inside reads
`/proc/meminfo`, which is the **whole Docker VM** (~29.4 GiB here). Until PR #86 every node
advertised 29.4Gi allocatable, so:

- the scheduler packed m03 with 9.5 GiB of limits on a 6 GiB box;
- `kubepods/memory.max` was ≈ the VM size, so pods were never capped as a group;
- `memory.available` eviction can never fire, because it is measured against capacity
  (VM), not the cgroup cap.

At the cap the kernel killed processes at random: the m02 node went down, and mysql-0 was
killed via its liveness probe. `kubectl top nodes` looked harmless (11–16%) the whole time,
because it divides by the wrong capacity. `docker stats` (80% of 6GiB) told the truth.

**Fix (cluster.sh `reserve_node_memory`):** `systemReserved.memory = (VM − cap) + 512Mi`.
`systemReserved` is the one knob that both sets allocatable and caps the `kubepods` cgroup
(with cgroupfs: `/sys/fs/cgroup/kubepods/memory.max`). Don't put the gap in `evictionHard`:
it shrinks allocatable but not the kubepods cap. `minikube start` rewrites
`/var/lib/kubelet/config.yaml`, so this is re-applied on every up/start.

**How to apply:** when a kind/minikube-on-Docker node misbehaves under load, compare
`kubectl get node -o jsonpath='{.status.allocatable.memory}'` against the container's
`/sys/fs/cgroup/memory.max` first. Related: [[minikube-node-resources-only-apply-at-creation]],
[[jvm-malloc-arena]].
