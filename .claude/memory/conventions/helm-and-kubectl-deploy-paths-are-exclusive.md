---
name: helm-and-kubectl-deploy-paths-are-exclusive
description: make k8s-apps-helm cannot run after make k8s-bootstrap — the Helm and kubectl bring-up paths are mutually exclusive on one cluster, despite the "runs alongside" comments
metadata: { type: convention, date: 2026-08-07 }
---

The Makefile comments say the Helm targets "run ALONGSIDE" the kubectl ones. That means both
*code paths are maintained*, *not* that both can be applied to the same cluster. On a cluster
brought up with `make k8s-bootstrap`, `make k8s-apps-helm` aborts before creating anything.

Two independent blockers, found live on a 4-node minikube (2026-08-07):

1. **Namespaces.** `deploy/charts/microecom/templates/namespaces.yaml` ranges over
   `global.namespaces` and skips only `infra` (the release namespace), so it renders `apps`,
   `bootstrap` and `monitoring`. Helm refuses to adopt a pre-existing object lacking
   `app.kubernetes.io/managed-by=Helm` + the two `meta.helm.sh/release-*` annotations.
   `k8s-app-secrets` originally stamped only `apps`, so the abort moved to `bootstrap` rather
   than going away. Fixed — it now stamps all three.

2. **Vendored charts vs standalone releases.** `k8s-apps-helm` sets `apps.enabled=true` but never
   sets `infra.enabled=false`, and `infra.enabled` defaults to **true** (`values.yaml:51`). So it
   renders the whole infra subchart, which vendors grafana at
   `charts/infra/charts/grafana` — while `k8s-platform` has already installed grafana as its
   **own** standalone Helm release. Helm will not adopt `ServiceAccount/grafana` out of release
   `grafana` into release `microecom`. Same shape applies to the other platform releases
   (ingress-nginx, metrics-server, kube-state-metrics). This one is not fixable by stamping.

**How to apply:** the Helm app path is reachable only on a cluster brought up the Helm way —
`make k8s-cluster-up && make k8s-infra-helm && make k8s-apps-helm`. Do not treat
`k8s-apps-helm` as a drop-in after `k8s-bootstrap`, and do not read its name as "apps only" — it
installs the entire umbrella. Recovery if you try it anyway: `make k8s-apps` re-applies the
kustomize path cleanly (verified: 10/10 pods, catalog HTTP 200).

**Why the render tests miss it:** the apps subchart has 268 passing render tests and every one is
still correct — they assert the *generated YAML*, which is fine. The conflict is between that
YAML and pre-existing cluster state, so `helm template` can never reach it. Related:
[[cold-cluster-image-pulls-outgrow-rollout-timeouts]], [[0003-deploy-refactor-helm-umbrella-three-envs]].
