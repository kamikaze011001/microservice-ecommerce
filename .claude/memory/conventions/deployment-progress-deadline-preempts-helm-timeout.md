---
name: deployment-progress-deadline-preempts-helm-timeout
description: a Deployment's own progressDeadlineSeconds (default 600s) fails the release before helm's --wait --timeout is reached, so raising the helm timeout can never fix a slow cold pull
metadata: { type: convention, date: 2026-08-15 }
---

The first from-scratch `k8s-bootstrap-helm` died with:

```
Error: resource Deployment/infra/kafka-connect not ready.
       status: Failed, message: Progress deadline exceeded
```

Nothing was broken. Measured on that run: `confluentinc/cp-kafka-connect:7.6.1` is **1.66 GB
and took 7m13.8s** to pull; `cp-schema-registry:7.7.1` was still pulling past 8m48s; and
kafka-connect's `wait-for-schema-registry` init container blocks on schema-registry, so the
two compound instead of overlapping. Both pods reached 1/1 on their own minutes after helm
had already given up — which is the proof it was a deadline, not a defect.

**The trap:** `k8s-infra-helm` already passes `--wait --timeout 30m`, which looks like it
covers this. It does not. The **deployment controller** evaluates the Deployment's own
`progressDeadlineSeconds` (Kubernetes default **600s**) and marks it `Failed`; helm reports
that failure immediately, nowhere near its own 30m bound. Two timeouts govern one wait and
the smaller, invisible, defaulted one wins. Raising the helm timeout is the obvious first fix
and is useless.

`charts/infra/values.yaml` now sets `progressDeadlineSeconds: 1800` on **all** infra
Deployments, not just the two that lost the race: any Deployment whose deadline is shorter
than the orchestrating release timeout can fail a release spuriously on a cold node where
every image pulls at once.

**How to apply:** reach for `$.Values` not `.Values` inside a `range` (mysqld-exporter
renders in one, where `.` is rebound and `.Values` is nil). The apps subchart deliberately
keeps the 600s default — its images come from the local registry, not a 1.6 GB internet pull,
and a longer deadline there would only delay a genuine failure. Same family as
[[cold-cluster-image-pulls-outgrow-rollout-timeouts]], which is the kustomize path's version
of this (`kubectl wait`, fixed 10m→15m) — the Helm path never got the equivalent fix because
it had never been run from scratch.
