---
name: k8s-targets-inherit-ambient-kubectl-context
description: The repo's k8s make targets don't pin --context, so they act on whatever cluster kubectl currently points at — which during this branch's own verification was an unrelated live cluster
metadata: { type: convention, date: 2026-08-07 }
---

Nothing in the repo's k8s targets passes `--context`. They inherit whatever
`kubectl config current-context` happens to be. During Phase 4's verification that was a live,
unrelated Azure AKS cluster with no minikube profile present at all — and
`secrets-seed ENV=k8s` would have port-forwarded into it and written secrets there.

`deploy/scripts/secrets-seed.sh` now **refuses to run for `ENV=k8s` unless the context is named
and matches**, and passes the same name to `port-forward` so the check and the action cannot
diverge:

```bash
make secrets-seed ENV=k8s KUBE_CONTEXT=microecom
bash deploy/scripts/secrets-seed.sh --env k8s --context microecom
```

**Why:** a destructive-by-default operation must not select its own target implicitly. This is the
one guard, and it covers only the seeder — every other k8s target in the repo (`make k8s-*`,
`k8s/infra/install.sh`, the seed jobs) still inherits ambient context.

**How to apply:** check `kubectl config current-context` before any `make k8s-*` run, especially
after working on another project. When adding a new cluster-touching script, take the context
explicitly rather than following the existing targets' pattern — the pattern is the hazard.
Related: [[0004-canonical-secrets-resolve-transport-split]],
[[minikube-tunnel-external-ip-is-sticky]].
