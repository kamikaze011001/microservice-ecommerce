# Project Memory Index — microservice-ecommerce

*One line per memory. Auto-loaded at session start. Keep it compact and grouped.*

## Decisions (decision + rationale, durable)
- [0001 — in-repo memory alongside untouched CLAUDE.md](decisions/0001-in-repo-memory-alongside-untouched-claude-md.md) — kept CLAUDE.md as SSOT, added the `.claude/memory/` lifecycle
- [0002 — root CLAUDE.md delegates to nested module files](decisions/0002-root-claude-md-delegates-to-nested-module-files.md) — root keeps non-derivable + cross-cutting only; module specifics live in `<module>/CLAUDE.md`
- [0003 — deploy refactor: Helm umbrella + three envs](decisions/0003-deploy-refactor-helm-umbrella-three-envs.md) — consolidate under `deploy/`; Helm for minikube/EKS, compose retained, canonical secrets/seed/images shared
- [0004 — canonical secrets: resolve/transport split](decisions/0004-canonical-secrets-resolve-transport-split.md) — one file per service + per-env contexts; pure resolver separate from the seeder, so every env verifies offline without credentials

## Conventions (conventions + gotchas, durable)
- [two-memory-systems-coexist](conventions/two-memory-systems-coexist.md) — global personal auto-memory vs in-repo team-shared `.claude/memory/`; which to use when
- [nested-claude-md-loads-only-in-scope](conventions/nested-claude-md-loads-only-in-scope.md) — nested files load only under their directory, so a cross-cutting rule stays in root even when a nested file repeats it
- [a11y-guards-jsdom-pin-is-insurance](conventions/a11y-guards-jsdom-pin-is-insurance.md) — a11y-step guards pin jsdom as defense-in-depth, NOT because happy-dom breaks axe (that premise was false)
- [migrating-styled-buttons-to-biconbutton](conventions/migrating-styled-buttons-to-biconbutton.md) — styled raw button → BIconButton keeps its look via a retained page class (parent scoped CSS wins the specificity tie)
- [eks-gp3-storageclass-must-precede-pvcs](conventions/eks-gp3-storageclass-must-precede-pvcs.md) — fresh EKS defaults to gp2; gp3 SC must be applied before any PVC or the aws-all Step-3 infra bring-up stalls
- [rds-replica-inherits-source-parameter-groups](conventions/rds-replica-inherits-source-parameter-groups.md) — terraform-aws-modules/rds replica needs create_db_*_group=false or apply fails on missing engine metadata
- [minikube-registry-host-5001-pod-5000](conventions/minikube-registry-host-5001-pod-5000.md) — host pushes :5001, pods pull :5000, same registry; do NOT "fix" either to match the other
- [minikube-hostpath-ignores-fsgroup](conventions/minikube-hostpath-ignores-fsgroup.md) — root-owned PVs break non-root containers; Kafka + MongoDB need chown initContainers (kind didn't)
- [kafka-internal-topics-need-explicit-compaction](conventions/kafka-internal-topics-need-explicit-compaction.md) — auto-created `_schemas`/`connect-*` get cleanup.policy=delete and Schema Registry/Connect then refuse to start
- [kafka-exporter-applies-after-kafka-ready](conventions/kafka-exporter-applies-after-kafka-ready.md) — it hard-exits with no broker; apply after Kafka's rollout + restart it so a wedged reconcile recovers
- [minikube-node-resources-only-apply-at-creation](conventions/minikube-node-resources-only-apply-at-creation.md) — `--cpus/--memory` ignored on resume; cluster.sh re-applies via `docker update` (and is over-subscribed here)
- [minikube-tunnel-external-ip-is-sticky](conventions/minikube-tunnel-external-ip-is-sticky.md) — 3 ways to misjudge tunnel health: sticky `EXTERNAL-IP`, `lsof` blind to the root-owned listener, and `sudo -v` cached per-tty
- [buildkit-cache-mount-shadows-baked-m2](conventions/buildkit-cache-mount-shadows-baked-m2.md) — a cache mount hides the image's baked `/root/.m2`; seed it from a read-only bind with `cp -r` (never `-n`)
- [vault-config-comment-keys-are-really-seeded](conventions/vault-config-comment-keys-are-really-seeded.md) — `_comment*` in `docker/vault-configs/*.json` are live Vault properties, not comments; explains the 94-vs-90 key count
- [cross-env-equality-checks-miss-shared-drift](conventions/cross-env-equality-checks-miss-shared-drift.md) — "all envs agree" stays green when a shared source file moves all of them at once; pair it with an absolute anchor
- [k8s-targets-inherit-ambient-kubectl-context](conventions/k8s-targets-inherit-ambient-kubectl-context.md) — no k8s target pins `--context`; only `secrets-seed` refuses an unnamed one, everything else acts on whatever kubectl points at

## Current
- [HANDOFF](HANDOFF.md) — latest WIP state (overwritten each session)
- [sessions/](sessions/) — progress log per day
