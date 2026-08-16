---
name: helm-subchart-toggle-deletes-on-a-shared-release
description: two targets installing the same release name means `--set <subchart>.enabled=false` deletes that subchart's live objects — it does not mean "leave them alone"
metadata: { type: convention, date: 2026-08-15 }
---

`k8s-infra-helm` and `k8s-apps-helm` both run
`helm upgrade --install microecom deploy/charts/microecom --namespace infra`. The apps target
also passed `--set infra.enabled=false`. On the first from-scratch bootstrap this **deleted
MySQL, MongoDB, Kafka, Vault, Redis, MinIO, schema-registry and kafka-connect**, and the 8
JVM services then crashlooped against a stack that no longer existed.

A helm release upgrades **as a whole** — you cannot upgrade half of it. `enabled=false` means
"this release no longer contains that subchart", and helm reconciles by removing what it
owns.

**The part worth remembering: neither target had changed.** The flag was correct when it was
added — infra then came from the kustomize path, was not owned by the release, so there was
nothing to delete and the flag only suppressed an adoption conflict. Wiring `k8s-infra-helm`
into the bootstrap chain made the release the *owner*, and a harmless flag became destructive
without a line of it being edited.

The reported error named only the victims (`8 Deployments not ready`), never the cause.
`helm history` is what settles it: rev 2 `deployed` (infra healthy), rev 3 `failed` with
infra gone.

**How to apply:** an `enabled` toggle is only safe when the caller owns that subchart in that
release. Two lifecycle stages of one chart either share a release and enable everything they
want to persist, or take separate release names. `deploy/scripts/aws-deploy.sh` still passes
`infra.enabled=false` **correctly**, because on AWS the datastores live outside the chart —
see [[0005-aws-infra-stays-outside-the-umbrella-chart]]. Related:
[[helm-and-kubectl-deploy-paths-are-exclusive]].
