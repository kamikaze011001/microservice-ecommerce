---
name: 0003-deploy-refactor-helm-umbrella-three-envs
description: Deploy structure consolidates into deploy/ — one Helm umbrella chart for k8s (minikube + EKS), docker-compose kept as the fast inner loop, all three envs sharing canonical secrets/seed/images
metadata: { type: decision, date: 2026-08-01 }
---
The three deployment targets (docker-compose, local k8s, AWS EKS) collapse into one `deploy/`
tree: **one Helm umbrella chart** (`deploy/charts/microecom`, `infra` + `apps` subcharts,
env = one values file) for both k8s targets, docker-compose keeping its compose files, and all
three reading the **same canonical artifacts** — `deploy/secrets/*.yaml` (+ per-env
`contexts/*.yaml`), `deploy/seed/`, `deploy/images/`. Kustomize retires. kind → minikube. Entry
points unify to `make <verb> ENV=compose|k8s|aws`. Full design + 9-phase migration:
`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`.

The six choices, each with its alternative rejected:
- **Three first-class envs** (not "drop compose", not "compose-only + cloud") — compose is the
  fast inner loop, minikube is k8s-integration, EKS is the cloud target.
- **One umbrella chart for everything k8s** (not per-service charts, not keep-kustomize) — a
  single `helm upgrade` per env, and Helm release history gives free rollback.
- **Per-env secret backend abstracted by the chart** (`secret.backend: vault|eso`) — not
  ESO-everywhere (forces dev onto AWS), not Vault-everywhere (drags prod secrets out of
  Secrets Manager). One template, two branches, one value selects.
- **Parametrized images, immutable EKS tags** — minikube keeps `:dev` + `pullPolicy: Always`;
  EKS pins `:<git-sha>` so a Helm rollback pulls the exact prior bytes.
- **Keep the 4 namespaces** (`infra`, `apps`, `monitoring`, `bootstrap`) — the stateful/app/obs/
  one-shot split is already encoded in k9s hotkeys, RBAC, and scripts; namespace names become
  values-driven so cross-namespace FQDNs render from one helper.
- **Canonical seed scripts run outside Helm** with `--env` — Helm hooks cannot express "seed
  MySQL only after the apps' ddl-auto created the schema"; seeding via a hook crashes.

**Why now:** the divergence is not cosmetic, it has already shipped bugs. `k8s/CLAUDE.md`
documents 3+ crashloops caused purely by the hand-written Vault seed drifting from
`docker/vault-configs/` (missing `authorization-server` block, missing
`spring.kafka.properties.schema.registry.url`, missing `spring.data.mongodb.database`), and the
RSA JWK exists in three places where a single byte of difference breaks every token in the
system. One canonical file per service removes the second copy that can drift, and
`deploy/scripts/secrets-validate.sh` turns the lesson into a build failure instead of a comment.
Secondary driver: there is no deploy CI/CD yet, and this structure makes the pipeline pure
wiring (`make image-build ENV=aws` → `make deploy ENV=aws`) rather than new machinery.

**How to apply:** during the migration, build new alongside old — every phase must leave a
working deploy, and the `k8s/` + `aws/` deletion is the last phase, gated on a full
`make bootstrap ENV=k8s` **and** `ENV=aws` pass. Explicitly out of scope: changing application
code (Spring profiles + configtree/Vault reading logic stay), new envs (staging/dev), GitOps,
NetworkPolicies, and rewriting the Terraform (it moves, its content does not change).
