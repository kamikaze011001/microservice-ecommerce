---
name: 0008-unexercised-paths-run-in-checkpoints-not-one-shot
description: the first live AWS bring-up runs the RUNBOOK's nine steps as four checkpoints grouped by failure vocabulary, instead of one make aws-all
metadata: { type: decision, date: 2026-08-21 }
---

`make aws-all` runs `scripts/aws/up-all.sh`'s nine steps in one shot. The first live run
instead stops at four checkpoints: infra (steps 0–1), images + platform (2–3), secrets +
apps (4–6), data + acceptance + teardown (7–9).

**Why:** the boundaries were chosen by **what breaks in each**, not by step count.
Checkpoint 1 fails for AWS reasons — quotas, spot capacity, IAM propagation, subnets.
Checkpoint 2 fails for credential and storage reasons — ECR auth, IRSA trust, PVCs
pending on a missing StorageClass. Checkpoint 3 fails for Kubernetes reasons —
crashloops, unresolved ExternalSecrets, readiness gates. These are different error
vocabularies, and knowing *which kind* of problem you are looking at is most of
debugging. Letting two layers fail in one run means reading two unrelated languages at
once — the main obstacle for someone learning the stack.

Secondary reason: money. A one-shot run that dies at step 6 has been billing for half an
hour with a half-built stack. Each checkpoint is a clean stop — continue, or tear down.

**How to apply:** every step already has its own entry point (`make aws-up`,
`make aws-push`, `make aws-infra-up`, `deploy/scripts/seed.sh`,
`deploy/scripts/secrets-seed.sh`, `make aws-deploy-apps`), so the grouping costs nothing
to adopt. Use the same shape for any path that has never executed. Related:
[[first-install-cannot-verify-a-deploy-path]],
[[an-unexercised-path-fails-where-nothing-rendered-it]], [[0007-first-aws-run-keeps-k8s-1-31]].
