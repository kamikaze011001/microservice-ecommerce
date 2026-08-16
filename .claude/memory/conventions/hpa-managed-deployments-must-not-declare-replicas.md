---
name: hpa-managed-deployments-must-not-declare-replicas
description: a chart that sets spec.replicas on a Deployment with an HPA loses a server-side-apply ownership fight with kube-controller-manager and fails the entire release on the next upgrade
metadata: { type: convention, date: 2026-08-15 }
---

```
UPGRADE FAILED: conflict occurred while applying object apps/gateway
Kind=Deployment: conflict with "kube-controller-manager" with subresource
"scale" using apps/v1: .spec.replicas
```

`charts/apps/templates/deployments.yaml` set `replicas` on all 10 Deployments while
`hpas.yaml` rendered an HPA for 5 of them. Once an HPA scales a Deployment,
kube-controller-manager takes ownership of `.spec.replicas` through the `scale` subresource;
helm's server-side apply then loses that fight and **the whole release fails** — not just the
one object.

Declaring it was also wrong on its own terms: every upgrade would reset the Deployment to the
static count and undo whatever the autoscaler had done.

Fixed by gating the field: `{{- if $s.hpa }}` omits `replicas`, and the HPA's `minReplicas`
governs the initial count.

**Why it survived every earlier check:** it cannot happen on a FIRST install — only on an
upgrade after an HPA has acted. Task 1 deployed the apps chart once, saw 10/10 pods and 30
products, and reasonably called the path verified. See
[[first-install-cannot-verify-a-deploy-path]].

**How to apply:** `deployments.yaml` tests `$s.hpa` (the merged value, inheriting
`$.Values.defaults`) while `hpas.yaml` tests `$svc.hpa` (raw). They agree only because
`defaults` has no `hpa` key today — adding one would strip `replicas` from all 10 while
rendering 5 HPAs. The old kustomize aws overlay still carries the bug, so `aws-diff-test.sh`
declares it as a difference where the chart is more correct, asserted directionally and
composed with the vault-leftover handler on the same 5 objects (each handler must find its
own difference present, so one reverting cannot be masked by its neighbour).
