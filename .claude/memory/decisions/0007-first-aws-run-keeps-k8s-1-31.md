---
name: 0007-first-aws-run-keeps-k8s-1-31
description: the first live ENV=aws run pays the EKS extended-support surcharge rather than bumping the cluster version, because the controllers are pinned three minor versions behind
metadata: { type: decision, date: 2026-08-21 }
---

`aws/main/eks.tf` pins `cluster_version = "1.31"`. Standard support for 1.31 ended
2025-11-26, so AWS charges **+$0.60/hr** extended support — taking the stack from
~$0.40/hr to ~$1.00/hr. The first run keeps 1.31 anyway.

**Why:** the controllers are contemporaries of Kubernetes 1.30–1.31 —
`aws-load-balancer-controller` chart `1.8.1` (`alb-controller.tf:65`), `external-dns`
chart `1.15.0` (`external-dns.tf:70`), EKS module `~> 20.0` (`eks.tf:42`). The supported
versions on 2026-08-21 are 1.34, 1.35 and 1.36, so bumping runs 2024-era controllers
three or more minor versions ahead of anything they were tested against. The ALB
controller is not optional: if it fails, no Ingress is reconciled, no load balancer
exists, and the storefront never comes up. Version skew does not fail loudly — a
controller whose watch 404s on a removed API runs happily and does nothing.

The stack has never run on **any** version, so a failure on 1.34 could be the cluster,
the charts, or a genuine defect, with no way to tell which. The delta is ~$2.40 per
four-hour session; a confounded result costs an evening.

**How to apply:** keep 1.31 until the stack is proven working, then bump the cluster
**and** the controllers together as one informed change with a known-good baseline to
diff against. Read current support windows from
`aws eks describe-cluster-versions --query 'clusterVersions[].[clusterVersion,endOfStandardSupportDate]'`
rather than recalling them — the dates move. Related:
[[an-unexercised-path-fails-where-nothing-rendered-it]],
[[0008-unexercised-paths-run-in-checkpoints-not-one-shot]].
