---
name: 0005-aws-infra-stays-outside-the-umbrella-chart
description: AWS infra keeps its own manifests under deploy/aws-infra/ instead of using the chart's infra subchart, because both would share the release name aws-deploy.sh disables infra on
metadata: { type: decision, date: 2026-08-15 }
---

`scripts/aws/infra-up.sh` applies raw manifests from `deploy/aws-infra/` (ESO, Mongo,
Kafka, schema-registry, kafka-connect, the gp3 StorageClass, VM/Grafana values and
dashboards). It does **not** use the umbrella chart's `infra` subchart, even though
`envs/aws.yaml` already configures exactly that set and renders 47 objects.

**Why:** `deploy/scripts/aws-deploy.sh` deploys apps as
`helm upgrade --install microecom … --namespace infra --set infra.enabled=false`. If
`infra-up.sh` installed the infra subchart under that same release, the next apps deploy
would **delete every infra object** — a helm release upgrades as a whole, so
`infra.enabled=false` does not mean "leave infra alone", it means "this release no longer
contains infra". See [[helm-subchart-toggle-deletes-on-a-shared-release]], which is the same
failure this project hit live on the local cluster on 2026-08-15.

Phase 8 deleted `k8s/infra/` while `infra-up.sh` still read it, so the 12 files it actually
consumes were recovered to `deploy/aws-infra/` verbatim rather than repointed at the chart.
Restoring preserves the never-executed AWS path's behaviour exactly; repointing would have
introduced an untested design on a billed path.

**How to apply:** consolidating AWS infra into the chart is still the right end state, but it
requires a release-name decision first — either two releases (`microecom-infra` +
`microecom`) or `aws-deploy.sh` no longer disabling infra, which is how the local path was
fixed. Do it in a phase that can actually run `make aws-all`; **`ENV=aws` has never been
executed**, so nothing about it is verified today. Related:
[[first-install-cannot-verify-a-deploy-path]].
