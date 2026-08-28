---
name: the-teardown-path-lacks-the-guards-the-creation-path-has
description: up-all.sh passes --context at every seed step while down.sh named no context and swallowed failures with || true, inverting where the risk lives
metadata: { type: convention, date: 2026-08-21 }
---

`scripts/aws/up-all.sh` passes `--context microecom-eks` explicitly at lines 142, 215,
228 and 253, with a comment saying the context is "never inherited from an ambient
context". `scripts/aws/down.sh` — which **destroys infrastructure** — named no context
at all:

```bash
kubectl delete -f "$ROOT/aws/manifests/hello-nginx.yaml" --ignore-not-found=true || true
kubectl delete ingress gateway-alb -n apps --ignore-not-found=true || true
```

Two defects compounding. Pointed at minikube, both deletes run against the wrong
cluster, find nothing, and succeed. Then `terraform destroy` proceeds — and the ALB,
created by the in-cluster Load Balancer Controller rather than by Terraform, is stranded
and keeps billing, invisible to `terraform state list`. Every command exits 0.

The `|| true` is the deeper half. `--ignore-not-found=true` already handles "that
resource is absent", which is safe. The `|| true` on top can therefore only suppress a
*different* class — cluster unreachable, context missing, credentials expired — the
opposite situation, and the one that must abort.

**Why the asymmetry recurs:** creation paths get hardened because their failures are
loud and immediate; the thing you wanted does not appear. Teardown failures are silent
and deferred — you find out on next month's bill. Attention flows to the path that
complains, so the destructive path, where a wrong target is unrecoverable, keeps the
weaker guards.

**How to apply:** a destructive script must prove its target before acting, and must
distinguish "nothing to do" from "could not determine whether there was anything to do".
When you find a guard on a creation path, check whether its teardown counterpart has
one. Related: [[errexit-consumes-a-functions-exit-code]],
[[an-unexercised-path-fails-where-nothing-rendered-it]].
