# Deployment Refactor — Helm + Multi-Env + minikube

**Date:** 2026-08-01
**Status:** Approved design — pending implementation plan
**Spec author:** brainstorming session (user + agent)
**Related:** `k8s/CLAUDE.md` (scars), `k8s/README.md`, `scripts/aws/RUNBOOK.md`

## Problem

The current deployment structure couples three environments through tangled,
divergent code paths:

| Target | Entry | Config/secrets | Seed logic | Infra install |
|---|---|---|---|---|
| docker-compose | `make up/down` | `docker/vault-configs/*.json` → Vault | `scripts/seed/*.sh` | `scripts/infra/up.sh` |
| kind k8s (local) | `make k8s-*` | `k8s/infra/jobs/03-vault-seed/seed.sh` (hand-copied) | `k8s/infra/jobs/*` + `scripts/seed/k8s-*.sh` | `k8s/infra/install.sh` |
| AWS EKS | `make aws-*` | AWS Secrets Manager + ESO | `scripts/aws/seed-*.sh` (third copy) | `scripts/aws/infra-up.sh` (partial copy) |

Concrete pain points (documented as crashloops in `k8s/CLAUDE.md`):

- **Vault secrets duplicated 2×** — `k8s/infra/jobs/03-vault-seed/seed.sh` is a
  hand-written reimplementation of `docker/vault-configs/*.json`. The scar doc
  lists 3+ crashloops caused by drifted keys (missing `authorization-server`
  block, missing `spring.kafka.properties.schema.registry.url`, missing
  `spring.data.mongodb.database`). A third path (AWS Secrets Manager/ESO) adds a
  third source.
- **Install scripts diverged** — `k8s/infra/install.sh` vs
  `scripts/aws/infra-up.sh` overlap ~60% but each carries env-specific guards
  (`if [[ "$CTX" != "microecom-eks" ]]; then abort`).
- **Kustomize overlays asymmetric** — `overlays/local` is a 29-line thin patch;
  `overlays/aws` is a generated tree (`gen-aws-overlay.sh`) with ESO + IRSA +
  volume mounts, and its README still says "NOT YET IMPLEMENTED" despite ~80%
  being done.
- **Hardcoded env values in base manifests** — `localhost:5001`,
  `VAULT_TOKEN=root`, `microecom.local` baked into
  `k8s/apps/base/*/deployment.yaml`.
- **Tooling is mixed and unclear** — Kustomize for apps, plain YAML for
  stateful infra (migrated off Bitnami), Helm only for 7 charts, Terraform for
  AWS.
- **No CI/CD for deploys** — `.github/workflows/` only has frontend +
  error-catalog.
- **Three command dialects** — `make up` (compose), `make k8s-bootstrap` (kind),
  `make aws-up` (aws). A newcomer must learn all three.

## Goals

1. Use Helm charts for flexibility — one umbrella chart, env = one values file.
2. Refactor deploy + infrastructure to adapt to many envs cleanly.
3. Migrate from kind to minikube.
4. Refactor deploy scripts for newcomer comprehension and ease of use.
5. Structure for modularity, cohesion, separation of concerns.
6. Make future CI/CD pipeline implementation straightforward.

## Decisions (from brainstorming)

| # | Decision | Choice | Rationale |
|---|---|---|---|
| Q1 | Environments | **B: three first-class targets** — docker-compose (fast loop) + minikube (k8s-integration) + EKS (prod/staging) | docker-compose stays for fast inner-loop; minikube replaces kind; EKS is the cloud target |
| Q2 | Helm scope | **A: one umbrella chart for everything (k8s)** — infra + apps as subcharts, env = one values file, Kustomize retires | maximum flexibility, single `helm upgrade`, cleanest for pipeline |
| Q3 | Secrets | **B: per-env backend, abstracted by chart** — Vault for compose + minikube, ESO → Secrets Manager for EKS, `secret.backend: vault\|eso` in values picks the path | preserves EKS ESO investment, keeps prod in AWS-native storage, doesn't force dev onto ESO |
| Q4 | Images | **B: parametrize + EKS immutable tags** — minikube keeps local registry `:dev`, EKS ECR images tagged by git-sha | keeps multi-node minikube option, gives EKS rollback/audit for pipeline |
| Q5 | Namespaces | **A: keep 4 namespaces** — `infra`, `apps`, `monitoring`, `bootstrap` with current roles | well-justified split (stateful vs app vs obs vs one-shot), k9s hotkeys + RBAC + scripts already encode it |
| Q6 | Seed | **B: canonical seed scripts, env-aware, run outside Helm** — one `scripts/seed/` set with `--env` flag, Helm owns manifests, scripts own data | separation of concerns; sidesteps Helm-hook-vs-app-rollout ordering problem (mysql seed before schema exists = crash) |

## Architecture

### Three envs, two deployment mechanisms, one set of shared artifacts

docker-compose is not k8s — it cannot be Helm-managed. So "one umbrella chart
for everything" means *one chart for everything k8s* (minikube + EKS).
Docker-compose keeps its compose files but shares the canonical artifacts
(secret definitions, seed data, image build) with the k8s envs.

```
                        ┌─────────────────────────────────┐
                        │       SHARED ARTIFACTS          │
                        │  deploy/secrets/  (canonical)   │
                        │  deploy/seed/     (canonical)   │
                        │  deploy/images/   (Dockerfiles) │
                        └──────────┬──────────┬───────────┘
                                   │          │
                    ┌──────────────┘          └──────────────┐
                    ▼                                        ▼
         ┌─────────────────────┐              ┌──────────────────────────┐
         │   docker-compose     │              │   Helm umbrella chart    │
         │   (fast inner loop)  │              │   deploy/charts/microecom │
         │                     │              │                          │
         │  docker/compose/*.yml│              │  helm upgrade microecom \ │
         │  + scripts that read │              │    -f envs/local-k8s.yaml │
         │    shared secrets/   │              │    -f envs/aws.yaml       │
         │    seed/             │              │                          │
         └─────────────────────┘              └──────────────────────────┘
                    │                                        │
                    ▼                                        ▼
         local-compose                            minikube        EKS
         (localhost:3306 etc)                  (local registry)  (ECR + Terraform)
```

### Secret flow (Q3-B: per-env backend, abstracted)

```
deploy/secrets/*.yaml (canonical definitions — ONE source of truth)
        │
        ├── compose/minikube:  scripts/secrets-seed.sh → Vault (KV v2)
        │                       apps read via Spring Cloud Vault
        │
        └── aws:               scripts/secrets-seed.sh → AWS Secrets Manager
                                ESO syncs → k8s Secret → configtree mount
```

The canonical `deploy/secrets/*.yaml` files replace the three current copies
(`docker/vault-configs/*.json`, `k8s/infra/jobs/03-vault-seed/seed.sh`,
`scripts/aws/seed-secrets.sh`). One YAML per service, same keys, env-agnostic
values where possible (e.g. kafka topic names), with placeholders for
env-specific values (e.g. JDBC URLs, S3 endpoints) that the seed script fills
from env context.

### Seed flow (Q6-B: canonical scripts, env-aware, outside Helm)

```
deploy/seed/ (canonical data — moved from docker/)
   ├── ecommerce.sql, product.json, product-quantity-history.json, api_role.json
   │
   └── scripts/seed.sh --env=compose   → localhost:3306 / mongo:27017 / minio:9000
       scripts/seed.sh --env=k8s       → kubectl exec mysql-0 / mongo-0 / minio-0
       scripts/seed.sh --env=aws       → RDS endpoint / mongo Service / S3 bucket
```

One `seed.sh` with a `--env` flag. The env determines *how to reach the data
store* (localhost vs kubectl-exec vs RDS-endpoint), not *what data to insert*
(that's always the same canonical files). The "seed after apps create schema via
ddl-auto" ordering stays an explicit step after deploy, matching the current
correct behavior.

### Image flow (Q4-B: parametrize, EKS immutable tags)

```
deploy/images/build.sh
   ├── compose:  docker build → local image (docker compose uses it directly)
   ├── k8s:      docker build → push to local registry (:dev, imagePullPolicy: Always)
   └── aws:      docker build → push to ECR (:<git-sha>, values file pins the tag)
```

### Cross-namespace communication

Namespaces are organizational, not security boundaries. Every `Service` gets a
DNS name `<service>.<namespace>.svc.cluster.local`. Same-namespace calls use
the short name; cross-namespace calls use the FQDN. The stack already relies on
this: `mysql.infra.svc.cluster.local:3306` (apps → infra),
`vault.infra.svc.cluster.local:8200` (apps → infra), etc. A plain `ClusterIP`
Service is reachable from any namespace in the cluster. The Helm chart makes
namespace names values-driven (`global.namespaces.*`) so FQDNs are generated
consistently via a helper template rather than hardcoded.

## Directory structure

```
deploy/
├── charts/
│   └── microecom/                    # umbrella Helm chart
│       ├── Chart.yaml
│       ├── values.yaml               # base defaults (shared across envs)
│       ├── envs/
│       │   ├── local-k8s.yaml        # minikube: local registry, hostPort ingress, VAULT_TOKEN=root
│       │   └── aws.yaml              # EKS: ECR images, ALB ingress, ESO, RDS, IRSA
│       ├── charts/
│       │   ├── infra/                # stateful services + upstream chart deps
│       │   │   ├── Chart.yaml
│       │   │   ├── values.yaml
│       │   │   ├── templates/        # mysql, mongo, redis, kafka, minio (from current manifests)
│       │   │   └── Chart.lock
│       │   └── apps/                 # 8 JVM services + frontend + mock-paypal
│       │       ├── Chart.yaml
│       │       ├── values.yaml
│       │       ├── templates/
│       │       │   ├── _helpers.tpl  # shared service template (deployment+service+hpa)
│       │       │   ├── deployment.yaml
│       │       │   ├── service.yaml
│       │       │   ├── hpa.yaml
│       │       │   ├── ingress.yaml
│       │       │   ├── externalsecret.yaml  # rendered only when secret.backend=eso
│       │       │   └── vault-rbac.yaml      # gateway discovery RBAC (k8s envs only)
│       │       └── values.yaml
│       └── templates/
│           ├── namespaces.yaml       # infra, apps, monitoring, bootstrap
│           └── _helpers.tpl
├── compose/                          # docker-compose env (moved from docker/)
│   ├── mysql.yml
│   ├── redis.yml
│   ├── mongodb.yml
│   ├── kafka.yml
│   ├── vault.yml
│   └── minio.yml
├── terraform/                        # AWS infra-as-code (moved from aws/)
│   ├── bootstrap/
│   └── main/
├── secrets/                          # canonical secret definitions (NEW)
│   ├── ecommerce.yaml
│   ├── core-s3.yaml
│   ├── authorization-server.yaml
│   ├── gateway.yaml
│   ├── product-service.yaml
│   ├── inventory-service.yaml
│   ├── order-service.yaml
│   ├── payment-service.yaml
│   ├── orchestrator-service.yaml
│   ├── bff-service.yaml
│   ├── mock-paypal-service.yaml
│   ├── contexts/
│   │   ├── compose.yaml
│   │   ├── k8s.yaml
│   │   └── aws.yaml
│   └── jwk.private.json              # the RSA private JWK — single source
├── seed/                             # canonical seed data (moved from docker/)
│   ├── ecommerce.sql
│   ├── product.json
│   ├── product-quantity-history.json
│   └── api_role.json
├── scripts/                          # env-aware deploy scripts (consolidated)
│   ├── lib/
│   │   ├── colors.sh
│   │   ├── env.sh                    # env detection + validation + kubectl context guard
│   │   └── helm.sh                   # values file resolution, release name helpers
│   ├── cluster.sh                    # minikube start/stop/nuke
│   ├── deploy.sh                     # helm upgrade (k8s/aws) or docker compose up (compose)
│   ├── teardown.sh                   # helm uninstall / compose down / terraform destroy
│   ├── seed.sh                       # --env flag → routes to right backend, same data
│   ├── secrets-seed.sh               # --env flag → Vault (compose/k8s) or Secrets Manager (aws)
│   ├── secrets-validate.sh           # key-set consistency check (drift prevention)
│   ├── image-build.sh                # --env flag → local / registry push / ECR push
│   ├── status.sh                     # --env flag → right status output
│   ├── bootstrap.sh                  # chains the above in env-correct order
│   └── rebuild.sh                    # build one svc + redeploy (the inner loop)
├── images/                           # Dockerfiles + build.sh (moved from k8s/images/)
│   ├── Dockerfile.jvm
│   ├── Dockerfile.cores
│   └── build.sh
└── README.md                         # newcomer onboarding (the one doc to read)
```

The old `k8s/`, `aws/`, `docker/vault-configs/`, `docker/ecommerce.sql` etc.
all fold into `deploy/`. `docker/` keeps only the Dockerfiles + compose files
that move to `deploy/compose/`. The `scripts/` directory at root stays for
non-deploy scripts (maven, error-catalog, etc.) — only deploy-related scripts
move to `deploy/scripts/`.

## Helm chart structure

### Umbrella chart (`deploy/charts/microecom/`)

Two subcharts. Values cascade: `values.yaml` (base defaults) →
`envs/local-k8s.yaml` or `envs/aws.yaml` (env overrides). The umbrella owns
namespaces + global config; subcharts own their resources.

### Values schema

```yaml
# values.yaml — base defaults (shared)
global:
  namespaces: { infra: infra, apps: apps, monitoring: monitoring, bootstrap: bootstrap }
  image:
    registry: localhost:5000
    tag: dev
    pullPolicy: Always
  secret:
    backend: vault          # vault | eso — picks the chart's secret template branch
  vault:
    uri: http://vault.infra.svc.cluster.local:8200
    token: root
  ingress:
    className: nginx
    hosts: { storefront: microecom.local, api: api.microecom.local, media: media.microecom.local }

# ── infra subchart ──
infra:
  mysql:          { enabled: true, replicas: 1, storage: 5Gi }
  mysqlReplica:   { enabled: true, replicas: 2, storage: 5Gi }
  mongodb:        { enabled: true, storage: 4Gi }
  redis:          { enabled: true }
  kafka:          { enabled: true, storage: 10Gi }
  minio:          { enabled: true, storage: 10Gi }
  schemaRegistry: { enabled: true }
  kafkaConnect:   { enabled: true }
  ingressNginx:     { enabled: true }
  metricsServer:    { enabled: true }
  victoriaMetrics:  { enabled: true }
  grafana:          { enabled: true }
  kubeStateMetrics: { enabled: true }
  vault:            { enabled: true }
  externalSecrets:  { enabled: false }   # EKS only

# ── apps subchart ──
apps:
  gateway:                 { enabled: true, port: 6868, managementPort: 19093, replicas: 1, rbac: true }
  authorization-server:    { enabled: true, port: 6666, managementPort: 19666, replicas: 1 }
  product-service:         { enabled: true, port: 7777, managementPort: 19777, replicas: 1, s3Consumer: true }
  inventory-service:       { enabled: true, port: 6969, managementPort: 19696, replicas: 1, grpcPort: 9090, s3Consumer: true }
  order-service:           { enabled: true, port: 9696, managementPort: 19969, replicas: 1 }
  payment-service:         { enabled: true, port: 8484, managementPort: 19848, replicas: 1 }
  orchestrator-service:    { enabled: true, port: 9999, managementPort: 19999, replicas: 1 }
  bff-service:             { enabled: true, port: 8087, managementPort: 19087, replicas: 1 }
  mock-paypal-service:     { enabled: true, port: 8585, managementPort: 19585, replicas: 1 }
  frontend:                { enabled: true, port: 80, replicas: 1 }
```

### Env overrides

```yaml
# envs/aws.yaml — the differences, nothing else
global:
  image:
    registry: 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com
    tag: ""              # filled by deploy.sh with git-sha
    pullPolicy: IfNotPresent
  secret:
    backend: eso         # → renders ExternalSecret + configtree volume, not Vault env vars
  vault: { enabled: false }
  ingress:
    className: alb
    hosts: { storefront: shop.microecom.click }

infra:
  mysql:          { enabled: false }   # RDS replaces
  mysqlReplica:   { enabled: false }   # RDS multi-AZ replaces
  redis:          { enabled: false }   # ElastiCache replaces
  minio:          { enabled: false }   # S3 replaces
  ingressNginx:   { enabled: false }   # ALB controller replaces
  vault:          { enabled: false }   # ESO replaces
  externalSecrets:{ enabled: true }    # ESO on
  grafana:        { ingress: { enabled: false } }  # port-forward on EKS
  victoriaMetrics:{ server: { ingress: { enabled: false } } }
```

```yaml
# envs/local-k8s.yaml — minikube = nearly the base defaults
global:
  image:
    registry: localhost:5000      # local registry (minikube addon)
    tag: dev
    pullPolicy: Always
  ingress:
    className: nginx
    hosts: { storefront: microecom.local, api: api.microecom.local, media: media.microecom.local }
# infra: all enabled (base defaults), metricsServer needs --kubelet-insecure-tls
```

### Infra subchart — two kinds of resources

1. **Upstream chart dependencies** (7): declared in `charts/infra/Chart.yaml`
   under `dependencies:`, each gated by `{{- if .Values.infra.<name>.enabled }}`.
   Their values files move into the subchart and are merged with env overrides.
   AWS's `--set ingress.enabled=false` overrides become entries in
   `envs/aws.yaml` under the same path.

2. **Plain-manifest stateful services** (5 + 2: mysql, mysql-replica, mongodb,
   redis, kafka, minio, schema-registry, kafka-connect): the current
   `k8s/infra/manifests/*.yaml` become templates in `charts/infra/templates/`,
   each wrapped in `{{- if .Values.infra.<name>.enabled }}`. Storage size,
   replica count, and the mysql replication setup are templated from values.
   The mongodb-keyfile secret creation moves to a template. The mysql
   replication configuration (currently inline in `install.sh`) becomes a
   post-install Job template in the subchart.

### Apps subchart — one shared template renders all 11 services

- `templates/_helpers.tpl` defines `microecom.deployment` — takes a service
  name + its values slice, renders a Deployment + Service + (conditionally) HPA.
  Image, ports, resources, probes, env vars all come from values. No
  per-service YAML files.
- `templates/deployments.yaml` loops:
  `{{- range $name, $svc := .Values.apps }}{{- if $svc.enabled }}---{{ include "microecom.deployment" (dict "name" $name "svc" $svc "root" $) }}{{- end }}{{- end }}`
- `templates/externalsecret.yaml` — rendered only when
  `global.secret.backend == eso`, loops the same services, creates one
  ExternalSecret per service pulling from `app/<name>` in Secrets Manager.
- `templates/vault-rbac.yaml` — gateway's ServiceAccount + RBAC, rendered when
  `apps.gateway.rbac == true` (both k8s envs).
- `templates/ingress.yaml` — env-specific: nginx-class for local (per-service
  host rules), ALB-class for AWS (the single `gateway-alb` ingress with all
  service prefixes). Selected by `global.ingress.className`.

### Secret backend branching (the Q3-B abstraction)

In the deployment template:

```yaml
{{- if eq .Values.global.secret.backend "vault" }}
  env:
    - { name: VAULT_TOKEN, value: {{ .Values.global.vault.token | quote }} }
    - { name: SPRING_CLOUD_VAULT_URI, value: {{ .Values.global.vault.uri | quote }} }
    - { name: SPRING_PROFILES_ACTIVE, value: k8s }
{{- else if eq .Values.global.secret.backend "eso" }}
  env:
    - { name: SPRING_PROFILES_ACTIVE, value: k8s }
  volumes:
    - name: app-config
      secret: { secretName: {{ $name }}-config }
  volumeMounts:
    - { name: app-config, mountPath: /etc/app-config, readOnly: true }
{{- end }}
```

One template, two paths, selected by one value. No if-else scattered across
scripts.

### Cross-namespace DNS helper

```yaml
# _helpers.tpl
{{- define "microecom.fqdn" -}}
{{- printf "%s.%s.svc.cluster.local" .name .namespace -}}
{{- end -}}
```

So when the apps subchart templates a service that needs MySQL:

```yaml
- name: SPRING_DATASOURCE_MASTER_URL
  value: jdbc:mysql://{{ include "microecom.fqdn" (dict "name" "mysql" "namespace" .Values.global.namespaces.infra) }}:3306/ecommerce_dev
```

## minikube migration (kind → minikube)

The migration is mostly about cluster lifecycle — everything inside the cluster
(manifests, services, seed) is now Helm-managed and env-agnostic, so it's
identical between kind and minikube. Only the cluster creation + local registry
+ ingress-to-host wiring changes:

| Concern | kind (current) | minikube (new) |
|---|---|---|
| Cluster create | `kind create cluster --config k8s/kind/cluster.yaml` | `minikube start --nodes=4 --cpus=4 --memory=6g --driver=docker` |
| Topology | 1 control-plane + 3 workers (hardcoded in cluster.yaml) | 1 control-plane + 3 workers (`--nodes=4`); single-node viable for lighter dev |
| Local registry | manual `registry.sh` — starts a `kind-registry` container, writes `hosts.toml` per node (containerd 2.x workaround) | `minikube addons enable registry` — built-in, auto-wires containerd, no manual hosts.toml |
| Registry port | `localhost:5001` | `localhost:5000` (minikube default) |
| Ingress → host :80/:443 | `extraPortMappings` in cluster.yaml (hostPort bound to control-plane) | `minikube tunnel` (background process, assigns `127.0.0.1` as EXTERNAL-IP to the ingress-nginx LoadBalancer Service) |
| Image preload | `preload-images.sh` (docker pull + `kind load` per node) | `minikube image load <img>` (pushes to all nodes) OR pull via registry |
| Pause | `docker stop <kind-nodes>` | `minikube stop` (or `minikube pause` — lighter) |
| Resume | `docker start` + re-seed Vault + bounce apps | `minikube start` + re-seed Vault + bounce apps (same logic, different cluster-up) |
| kubectl context | `kind-microecom` | `minikube` (minikube creates this automatically) |
| Delete cluster | `kind delete cluster --name microecom` | `minikube delete` |

**The `minikube tunnel` caveat:** unlike kind's hostPort (which is always-on
once the cluster starts), `minikube tunnel` must run as a background process
for the entire session. The `cluster.sh` script starts it after
`minikube start` and prints a note. If tunnel dies, ingress stops responding
on :80 — `cluster.sh tunnel` restarts it.

**`/etc/hosts` — no change.** minikube tunnel assigns `127.0.0.1` as the
ingress EXTERNAL-IP, so the existing entries work:
```
127.0.0.1 microecom.local api.microecom.local media.microecom.local grafana.microecom.local vm.microecom.local
```

**The registry port change (5001 → 5000)** is the one breaking change for
existing muscle memory. The chart's `values.yaml` sets
`global.image.registry: localhost:5000` for the k8s env; the old
`localhost:5001` references in scripts/docs all go away.

## Script consolidation — the newcomer UX

### Unified command pattern

```
# ── one-shot full setup (chains cluster → build → deploy → seed) ──
make bootstrap ENV=compose     # docker-compose: infra-up → vault → build → deploy → seed
make bootstrap ENV=k8s         # minikube: cluster-up → build → helm upgrade → seed
make bootstrap ENV=aws         # EKS: terraform → build → helm upgrade → seed

# ── daily loop ──
make deploy ENV=compose        # docker compose up (infra + apps)
make deploy ENV=k8s            # helm upgrade microecom -f envs/local-k8s.yaml
make deploy ENV=aws            # helm upgrade microecom -f envs/aws.yaml

make teardown ENV=compose      # docker compose down
make teardown ENV=k8s          # helm uninstall + minikube stop
make teardown ENV=aws          # helm uninstall + terraform destroy

# ── per-concern (composable) ──
make seed ENV=compose          # seed data into localhost MySQL/Mongo/MinIO
make seed ENV=k8s              # seed data via kubectl exec into minikube pods
make seed ENV=aws              # seed data into RDS/Mongo/S3

make status ENV=compose        # docker compose ps + service health
make status ENV=k8s            # kubectl get pods across 4 namespaces
make status ENV=aws            # kubectl get pods + ALB URL

make build ENV=compose [svc=…] # docker build (local images)
make build ENV=k8s    [svc=…] # docker build + push to localhost:5000
make build ENV=aws    [svc=…] # docker build + push to ECR :<git-sha>

# ── cluster lifecycle (k8s envs only) ──
make cluster-up ENV=k8s        # minikube start + tunnel + registry addon
make cluster-down ENV=k8s      # minikube delete (full wipe)
make cluster-stop ENV=k8s      # minikube stop (pause, data preserved)
make cluster-start ENV=k8s     # minikube start + re-seed Vault + bounce apps

# ── secrets (usually called by bootstrap, but available standalone) ──
make secrets-seed ENV=compose  # load deploy/secrets/*.yaml → local Vault
make secrets-seed ENV=k8s      # load deploy/secrets/*.yaml → in-cluster Vault
make secrets-seed ENV=aws      # load deploy/secrets/*.yaml → AWS Secrets Manager

# ── rebuild one service after code change (the inner loop) ──
make rebuild svc=order-service ENV=k8s   # build + push + helm upgrade (or rollout restart)

# ── AWS-only one-time + terraform ──
make aws-bootstrap             # one-time: TF state bucket + ECR repos + budget
make aws-leak-check            # confirm nothing billing after teardown
```

**The mental model for a newcomer:** one verb (`deploy`, `teardown`, `seed`,
`status`, `build`), one selector (`ENV=compose|k8s|aws`). No prefix dialects.
`bootstrap` is the one-shot that chains everything.

### Script structure

```
deploy/scripts/
├── lib/
│   ├── colors.sh              # shared logging (moved from scripts/lib/)
│   ├── env.sh                 # ENV detection + validation + kubectl context guard
│   └── helm.sh                # values file resolution, release name helpers
├── cluster.sh                 # minikube lifecycle: up/down/stop/start/tunnel
├── deploy.sh                  # helm upgrade (k8s/aws) or docker compose up (compose)
├── teardown.sh                # helm uninstall / compose down / terraform destroy
├── seed.sh                    # --env flag → routes to right backend, same data
├── secrets-seed.sh            # --env flag → Vault (compose/k8s) or Secrets Manager (aws)
├── secrets-validate.sh        # key-set consistency check (drift prevention)
├── image-build.sh             # --env flag → local / registry push / ECR push
├── status.sh                  # --env flag → right status output
├── bootstrap.sh               # chains the above in env-correct order
└── rebuild.sh                 # build one svc + redeploy (the inner loop)
```

### The env.sh guard

This replaces the scattered `if [[ "$CTX" != "microecom-eks" ]]; then abort`
checks:

```bash
# lib/env.sh — sourced by every deploy script
validate_env() {
  local env="${1:?}"
  case "$env" in
    compose) ;;
    k8s)
      command -v minikube >/dev/null || { echo "minikube not installed"; exit 1; }
      command -v helm >/dev/null    || { echo "helm not installed"; exit 1; }
      kubectl config current-context 2>/dev/null | grep -q "^minikube$" \
        || { echo "kubectl context is not 'minikube'. Run: make cluster-up ENV=k8s"; exit 1; }
      ;;
    aws)
      command -v aws >/dev/null || { echo "aws CLI not installed"; exit 1; }
      kubectl config current-context 2>/dev/null | grep -q "^microecom-eks$" \
        || { echo "kubectl context is not 'microecom-eks'. Run: aws eks update-kubeconfig --alias microecom-eks"; exit 1; }
      ;;
    *) echo "Unknown ENV '$env' — use: compose, k8s, or aws"; exit 1 ;;
  esac
}
```

One guard, sourced everywhere. No more per-script context checks that drift.

### The seed.sh consolidation

One `seed.sh` with env-specific transport functions. The seed *steps* (what
data, what order, what idempotency guards) are identical across envs. Only
the transport differs:

```bash
# deploy/scripts/seed.sh
mysql_exec() {  # mysql_exec <sql>
  case "$ENV" in
    compose) docker exec mysql-master mysql -uroot -proot -e "$1" ;;
    k8s)     kubectl -n infra exec mysql-0 -- mysql -uroot -proot -e "$1" ;;
    aws)     mysql -h "$RDS_PRIMARY" -u admin -p"$DB_PASS" -e "$1" ;;
  esac
}

mongo_import() { ... }   # docker exec / kubectl exec / kubectl exec (self-hosted on EKS)
minio_upload() { ... }   # docker exec / kubectl exec / aws s3 cp
```

Currently this logic is triplicated; the refactor collapses it to one script
with three transport functions.

## Canonical secrets consolidation

### The three copies today, side by side

Comparing the same key across the three current sources:

```
spring.datasource.master.url:
  compose:  jdbc:mysql://localhost:3306/ecommerce_dev?...
  k8s:      jdbc:mysql://mysql.infra.svc.cluster.local:3306/ecommerce_dev?...
  aws:      jdbc:mysql://<rds-primary-endpoint>:3306/ecommerce_dev?...

spring.data.redis.host:
  compose:  localhost
  k8s:      redis.infra.svc.cluster.local
  aws:      <elasticache-primary-endpoint>

spring.kafka.properties.schema.registry.url:
  compose:  http://localhost:8091
  k8s:      http://schema-registry.infra.svc.cluster.local:8081
  aws:      http://schema-registry.infra.svc.cluster.local:8081

s3.endpoint:
  compose:  http://localhost:9000
  k8s:      http://minio.infra.svc.cluster.local:9000
  aws:      ""   (SDK default chain → S3)

server.port:  6666  ← same everywhere (env-INVARIANT)
application.kafka.topics.*:  ← same everywhere (env-INVARIANT)
application.jwk:  ← same everywhere (env-INVARIANT, must be byte-identical)
```

Every key falls into one of three categories:

| Category | Example | Handling |
|---|---|---|
| **Env-invariant** | server.port, kafka topics, JWK, token lifetimes, mail host | plain value in canonical file |
| **Env-specific** | datasource URLs, redis host, s3 endpoint, gateway route URIs | placeholder `{{env.value}}` filled by seed script |
| **User-owned** | PayPal creds, mail creds | env-var reference, sourced from `.env` |

### Canonical secret file format

One YAML file per service in `deploy/secrets/`. Keys are the exact dotted
Spring property names (same as today — Vault KV v2 and ESO configtree both use
them verbatim). Values are either plain (env-invariant) or templated
(env-specific). Example:

```yaml
# deploy/secrets/ecommerce.yaml — the shared config consumed by ALL services
# (currently: docker/vault-configs/ecommerce-common.json + seed.sh's "ecommerce" block + aws's "app/ecommerce")

# ── env-invariant: same value in every env ──
spring.datasource.master.driver-class-name: com.mysql.cj.jdbc.Driver
spring.mail.host: smtp.gmail.com
spring.mail.port: "587"
eureka.client.enabled: "false"

# ── env-specific: filled by secrets-seed.sh from env context ──
spring.datasource.master.url:   "jdbc:mysql://{{mysql.master.host}}:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"
spring.datasource.master.username: "{{mysql.username}}"
spring.datasource.master.password: "{{mysql.password}}"

spring.data.redis.host: "{{redis.host}}"
spring.data.redis.port: "{{redis.port}}"

spring.data.mongodb.uri: "mongodb://ecommerce:{{mongo.password}}@{{mongo.host}}:27017/ecommerce_inventory?authSource=admin"
spring.kafka.bootstrap-servers: "{{kafka.bootstrap-servers}}"
spring.kafka.properties.schema.registry.url: "{{schema-registry.url}}"

spring.mail.username: "{{mail.username}}"    # from .env: APPLICATION_MAIL_USERNAME
spring.mail.password: "{{mail.password}}"    # from .env: APPLICATION_MAIL_PASSWORD
```

### Env context files

The placeholders (`{{mysql.master.host}}`, `{{redis.host}}`, etc.) are resolved
by `secrets-seed.sh` from an env context file — one per env, defining the
transport-specific values:

```yaml
# deploy/secrets/contexts/compose.yaml
mysql.master.host: localhost
mysql.slave1.host: localhost:3307
mysql.username: root
mysql.password: ecommerce_master
redis.host: localhost
redis.port: "6379"
redis.password: ecommerce_redis
mongo.host: localhost
mongo.password: ecommerce_mongo
kafka.bootstrap-servers: localhost:9092
schema-registry.url: http://localhost:8091
s3.endpoint: http://localhost:9000
s3.public-base-url: http://localhost:9000/ecommerce-media
jwk.private: @file:deploy/secrets/jwk.private.json
frontend.base-url: http://localhost:5173
paypal.base-url: https://api-m.sandbox.paypal.com
paypal.tunnel-url: "${PAYPAL_TUNNEL_URL}"
paypal.client-id: "${PAYPAL_CLIENT_ID}"
paypal.client-secret: "${PAYPAL_CLIENT_SECRET}"
```

```yaml
# deploy/secrets/contexts/k8s.yaml
mysql.master.host: mysql.infra.svc.cluster.local
mysql.slave1.host: mysql-replica.infra.svc.cluster.local
mysql.username: root
mysql.password: root
redis.host: redis.infra.svc.cluster.local
mongo.host: mongodb.infra.svc.cluster.local
mongo.password: ecommerce_mongo
kafka.bootstrap-servers: kafka.infra.svc.cluster.local:9092
schema-registry.url: http://schema-registry.infra.svc.cluster.local:8081
s3.endpoint: http://minio.infra.svc.cluster.local:9000
s3.public-endpoint: http://media.microecom.local
s3.public-base-url: http://media.microecom.local/ecommerce-media
jwk.private: @file:deploy/secrets/jwk.private.json
frontend.base-url: http://microecom.local
paypal.base-url: http://mock-paypal-service.apps.svc.cluster.local:8585/mock-paypal-service
paypal.tunnel-url: http://api.microecom.local
gateway.routes.authorization-server.uri: http://authorization-server.apps.svc.cluster.local:6666
# ... (all routes use cluster DNS)
```

```yaml
# deploy/secrets/contexts/aws.yaml
# Values that come from terraform outputs are marked — secrets-seed.sh reads them at runtime
mysql.master.host: "<terraform:rds_primary_endpoint>"
mysql.slave1.host: "<terraform:rds_replica_endpoint>"
mysql.username: admin
mysql.password: "<terraform:db_master_password>"
redis.host: "<terraform:redis_primary_endpoint>"
redis.password: "<terraform:redis_auth_token>"
redis.ssl: "true"
mongo.host: mongodb.infra.svc.cluster.local
kafka.bootstrap-servers: kafka.infra.svc.cluster.local:9092
s3.endpoint: ""
s3.bucket: "<terraform:s3_bucket_name>"
s3.public-base-url: "<terraform:s3_public_base_url>"
jwk.private: @file:deploy/secrets/jwk.private.json
paypal.tunnel-url: "<terraform:shop_url>"
gateway.routes.authorization-server.uri: http://authorization-server.apps.svc.cluster.local:6666
# ... (same cluster DNS as k8s — EKS self-hosted services use same ns)
```

### The JWK — single source

The JWK is the most painful drift risk (the gateway caches JWKS by `kid`; a
different key breaks every token). Today it's hardcoded in
`docker/vault-configs/authorization-server.json`, re-hardcoded in
`k8s/infra/jobs/03-vault-seed/seed.sh`, and extracted from seed.sh by
`scripts/aws/seed-secrets.sh`. The refactor moves it to one file:

```
deploy/secrets/jwk.private.json   # the RSA private JWK — the single source
```

All three env contexts reference it: `jwk.private: @file:deploy/secrets/jwk.private.json`.
The `secrets-seed.sh` script reads the file and substitutes. No more
extraction-from-seed.sh hacks.

### secrets-seed.sh — the one script that replaces three

```bash
# deploy/scripts/secrets-seed.sh
ENV="${1:?usage: secrets-seed.sh <compose|k8s|aws>}"
validate_env "$ENV"

# 1. Load the env context (resolves placeholders)
#    For aws, read terraform outputs and substitute <terraform:*> refs first
CTX=$(load_context "$ENV")

# 2. Load .env for user-owned creds
load_dotenv   # PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET, APPLICATION_MAIL_*, etc.

# 3. For each service, resolve placeholders → push to backend
for svc_file in "$SECRETS_DIR"/*.yaml; do
  svc_name=$(basename "$svc_file" .yaml)
  resolved=$(resolve_placeholders "$svc_file" "$CTX" "$ENV")

  case "$ENV" in
    compose|k8s)  vault_kv_put "$svc_name" "$resolved" ;;
    aws)          aws_secrets_put "app/$svc_name" "$resolved" ;;
  esac
done
```

### What this eliminates

| Scar | Root cause | How this prevents it |
|---|---|---|
| "vault-seed must mirror docker/vault-configs key-for-key" | hand-written reimplementation dropped keys | one canonical file per service — there is no second copy to drift |
| "missing authorization-server block → crashloop" | seed.sh omitted a key | the key is in `deploy/secrets/authorization-server.yaml`; the script reads the file, doesn't reimplement it |
| "missing spring.kafka.properties.schema.registry.url → crashloop" | seed.sh omitted it from the common block | it's in `deploy/secrets/ecommerce.yaml` — always present |
| "put_if_missing per-PATH — second block is no-op" | vault seed split one service across two blocks | the script does one `vault kv put` per service file — no split blocks possible |
| "JWK must be byte-identical" | three copies of the JWK, one extracted from another | one `jwk.private.json` file, all envs reference it |

### The validation guard — preventing drift from re-emerging

A check script that fails CI / pre-commit if the backends would diverge:

```bash
# deploy/scripts/secrets-validate.sh
# Ensures every deploy/secrets/*.yaml has the same key SET as the canonical list.
# Catches: a key added to one env's context but not the secret file, or vice versa.
```

This runs in `make secrets-seed ENV=<any>` as a pre-flight, and can be wired
into CI. It's the structural enforcement of the scar lesson — not a
documentation note, but a check that fails the build.

## CI/CD pipeline readiness

The design is structured so a future CI/CD pipeline is wiring commands into a
workflow, not building new machinery. Every concept the pipeline needs already
exists as a script target:

```
┌─ build ──────────────────────────────────────────────┐
│ make build              # mvn install                │
│ make image-build ENV=aws svc=all                     │
│   → docker build → push ECR :<git-sha>               │
└──────────────────────────────────────────────────────┘
         │ git-sha written into aws.yaml by deploy.sh
         ▼
┌─ deploy ─────────────────────────────────────────────┐
│ make secrets-seed ENV=aws   # sync Secrets Manager    │
│ make deploy ENV=aws         # helm upgrade            │
│   → helm upgrade microecom deploy/charts/microecom \  │
│       -f envs/aws.yaml --set global.image.tag=<sha>   │
└──────────────────────────────────────────────────────┘
         │
         ▼
┌─ seed (only on first deploy or schema change) ───────┐
│ make seed ENV=aws           # idempotent              │
└──────────────────────────────────────────────────────┘
         │
         ▼
┌─ verify ─────────────────────────────────────────────┐
│ make status ENV=aws         # pods + ALB health       │
│ make k8s-storefront-smoke ENV=aws  # k6 gate          │
└──────────────────────────────────────────────────────┘
```

| Pipeline need | How the design provides it |
|---|---|
| **Rollback** | `helm rollback microecom <revision>` — Helm tracks release history. ECR images are immutable git-sha tags, so a rollback pulls the exact prior image. |
| **Promote env→env** | Same chart, different values file. `dev` (k8s) → `staging` (aws) → `prod` (aws). Add `envs/staging.yaml` when needed. |
| **Secret rotation** | `make secrets-seed ENV=aws` re-runs anytime; ESO syncs within `refreshInterval` (1h). No app restart for value changes. |
| **Partial deploy** | `helm upgrade --set apps.payment-service.enabled=true` or values override. Or `make rebuild svc=payment-service ENV=aws`. |
| **Pre-flight validation** | `make secrets-validate` catches key drift before deploy. `helm template` + `helm lint` in CI before any apply. |
| **Branch-based env targeting** | `main` → `envs/aws.yaml` (prod), `staging` branch → `envs/staging.yaml`, PRs → build only. |
| **Audit trail** | Helm release history + ECR immutable tags + Secrets Manager CloudTrail = who deployed what, when. |

## Migration plan — phased, risk-ordered

Build-new-alongside-old, verify per env, then cut over and delete old. Each
phase leaves a working deploy.

### Phase 0 — Scaffold (no behavior change)

Create the `deploy/` directory tree. Move nothing yet. The old `k8s/`, `aws/`,
`docker/` paths still work. Pure scaffolding — zero risk.

**Deliverable:** empty `deploy/` tree + a `deploy/README.md` placeholder.

### Phase 1 — minikube migration (cluster lifecycle only)

Replace kind with minikube, keeping the existing kustomize manifests. Proves
minikube works before touching the manifest system.

1. Write `deploy/scripts/cluster.sh` — `minikube start --nodes=4 --driver=docker`,
   enable registry addon, start `minikube tunnel` in background
2. Update `k8s/kind/cluster.yaml` references → minikube in the Makefile's
   `k8s-cluster-up/down/stop/start` targets
3. Change `localhost:5001` → `localhost:5000` in existing
   `k8s/apps/base/*/deployment.yaml` (one-time sed)
4. Update `k8s/images/build.sh` to push to `localhost:5000`
5. Verify: `make k8s-bootstrap` works end-to-end on minikube with existing
   kustomize

**Risk:** low — only cluster lifecycle + registry port change. Manifests
unchanged. If minikube has issues, kind still works (revert the Makefile).

**Deliverable:** minikube replaces kind. Kustomize still in place.

### Phase 2 — Helm chart: infra subchart

Convert `k8s/infra/manifests/*.yaml` + `k8s/infra/install.sh` →
`deploy/charts/microecom/charts/infra/`.

1. Create `Chart.yaml` for the umbrella + infra subchart
2. Move each manifest → `charts/infra/templates/`, wrap in
   `{{- if .Values.infra.<name>.enabled }}`
3. Move `k8s/infra/values/*.yaml` → subchart values, wire as chart dependencies
4. Move the mysql replication setup (currently inline in `install.sh`) → a
   post-install Job template
5. Move the mongodb-keyfile secret creation → a template
6. Write `envs/local-k8s.yaml` (all infra enabled, nginx ingress, local registry)
7. Verify: `helm upgrade microecom deploy/charts/microecom -f envs/local-k8s.yaml`
   brings up infra on minikube, equivalent to old `make k8s-infra`

**Risk:** medium — manifest conversion. But the manifests are already plain
YAML; templating them is mechanical. Verify against the running minikube
cluster.

**Deliverable:** infra deployable via Helm on minikube. Apps still via kustomize.

### Phase 3 — Helm chart: apps subchart

Convert `k8s/apps/base/*/` + `k8s/apps/overlays/` →
`deploy/charts/microecom/charts/apps/`.

1. Write `_helpers.tpl` — the shared `microecom.deployment` template
2. Convert each service's `deployment.yaml` → values entries (ports, resources,
   probes, replicas)
3. Write the loop template (`deployments.yaml`, `services.yaml`, `hpas.yaml`)
4. Move gateway's `rbac.yaml`, `ingress.yaml` → templates gated by values
5. Move the nginx ingress rules (per-service hosts) → `ingress.yaml` template
6. Implement the secret-backend branch: `vault` path (env vars) vs `eso` path
   (volume mount)
7. Verify: `helm upgrade microecom deploy/charts/microecom -f envs/local-k8s.yaml`
   brings up all 11 services on minikube

**Risk:** medium — the shared template is the most complex part. But it
eliminates 11× duplicated YAML. Verify per-service readiness against the
running cluster.

**Deliverable:** full stack deployable via one `helm upgrade` on minikube.
Kustomize retired for k8s env.

### Phase 4 — Canonical secrets consolidation

Replace `docker/vault-configs/*.json` + `k8s/infra/jobs/03-vault-seed/seed.sh`
+ `scripts/aws/seed-secrets.sh` → `deploy/secrets/*.yaml` +
`deploy/secrets/contexts/*.yaml` + `deploy/scripts/secrets-seed.sh`.

1. Convert each `docker/vault-configs/*.json` → `deploy/secrets/*.yaml` with
   `{{placeholder}}` for env-specific values
2. Extract the JWK to `deploy/secrets/jwk.private.json` (single source)
3. Write `deploy/secrets/contexts/{compose,k8s,aws}.yaml`
4. Write `deploy/scripts/secrets-seed.sh` — resolves placeholders, pushes to
   Vault (compose/k8s) or Secrets Manager (aws)
5. Write `deploy/scripts/secrets-validate.sh` — key-set consistency check
6. Verify: `make secrets-seed ENV=k8s` seeds Vault identically to the old
   `03-vault-seed` Job. Diff the resulting Vault keys.
7. Verify: `make secrets-seed ENV=compose` seeds local Vault identically to
   old `make vault-import`. Diff keys.

**Risk:** high — this is where the drift scars are. But the verification (diff
old vs new Vault contents) is strong evidence. Run on minikube first, then
compose.

**Deliverable:** one canonical secret source, one seed script, three env
contexts.

### Phase 5 — Seed script consolidation

Replace `scripts/seed/all.sh` + `scripts/seed/k8s-*.sh` +
`scripts/aws/seed-*.sh` → `deploy/scripts/seed.sh --env=<env>`.

1. Move `docker/ecommerce.sql`, `docker/*.json` → `deploy/seed/`
2. Write `deploy/scripts/seed.sh` with env-specific transport functions
   (`mysql_exec`, `mongo_import`, `minio_upload`)
3. Wire the "seed after apps create schema" ordering as an explicit post-deploy
   step
4. Verify: `make seed ENV=k8s` on minikube produces the same DB state as the
   old `make k8s-seed` + `k8s-seed-mysql` + `k8s-seed-inventory`

**Risk:** medium — the data is the same, only transport changes. Verify by row
counts.

**Deliverable:** one seed script, three env transports.

### Phase 6 — Unified Makefile + script consolidation

Replace the three command dialects → unified `make <verb> ENV=<env>`.

1. Write `deploy/scripts/{deploy,teardown,status,image-build,bootstrap,rebuild}.sh`
2. Rewrite the Makefile — `ENV=`-parameterized targets, thin wrappers over
   `deploy/scripts/`
3. Move `aws/bootstrap/` + `aws/main/` → `deploy/terraform/`
4. Move `docker/*.yml` (compose files) → `deploy/compose/`
5. Move `k8s/images/` → `deploy/images/`
6. Verify: `make bootstrap ENV=k8s` (one-shot), `make deploy ENV=k8s`,
   `make seed ENV=k8s`, `make status ENV=k8s`, `make teardown ENV=k8s` all
   work on minikube
7. Verify: `make deploy ENV=compose`, `make seed ENV=compose` work on
   docker-compose

**Risk:** low — the scripts already work (built in phases 1-5); this is
rewiring the entry points.

**Deliverable:** unified UX. Newcomer reads `deploy/README.md`, runs
`make bootstrap ENV=k8s`.

### Phase 7 — AWS env cut-over

Make `ENV=aws` work with the new chart.

1. Write `envs/aws.yaml` — disable self-hosted mysql/redis/minio/vault/
   ingress-nginx, enable ESO, set ECR registry, ALB ingress class,
   `shop.microecom.click` host
2. Port the AWS overlay's per-service ExternalSecrets → chart's `eso`
   secret-backend branch (already built in phase 3)
3. Port the `s3-irsa-serviceaccounts.yaml` + IRSA role ARN stamping → chart
   templates
4. Port the `ingress-gateway.yaml` (ALB ingress) → chart's ingress template
   (ALB branch)
5. Verify: `make deploy ENV=aws` on EKS, `make secrets-seed ENV=aws`,
   `make seed ENV=aws`

**Risk:** medium — AWS-specific templates. But the ESO path is already designed
(phase 3), and the existing AWS overlay is ~80% done.

**Deliverable:** all three envs working via the new structure.

### Phase 8 — Cleanup

Delete the old structure.

1. Delete `k8s/` (entire directory — superseded by `deploy/charts/`)
2. Delete `aws/` (moved to `deploy/terraform/`)
3. Delete `docker/vault-configs/` (moved to `deploy/secrets/`)
4. Delete `docker/ecommerce.sql`, `docker/*.json` (moved to `deploy/seed/`)
5. Delete `docker/*.yml` (moved to `deploy/compose/`)
6. Delete `scripts/aws/` (consolidated into `deploy/scripts/`)
7. Delete `scripts/seed/k8s-*.sh`, `scripts/seed/all.sh` (consolidated into
   `deploy/scripts/seed.sh`)
8. Update root `CLAUDE.md` + `k8s/CLAUDE.md` (move scars to `deploy/CLAUDE.md`)
9. Update `scripts/services.list` references if needed

**Risk:** low — everything is verified working in phases 1-7. Deletion is the
final irreversible step; do it only after a full `make bootstrap ENV=k8s` +
`make bootstrap ENV=aws` pass.

**Deliverable:** clean `deploy/` tree. No leftover `k8s/` or `aws/` directories.

### Phase 9 — (Future) CI/CD pipeline

Not part of this refactor, but the structure is ready. When ready:

1. Add `.github/workflows/deploy.yml` — `on: push to main`, calls
   `make image-build ENV=aws` → `make deploy ENV=aws` → `make seed ENV=aws` →
   `make status ENV=aws`
2. Add `.github/workflows/pr.yml` — `on: PR`, calls `make build` +
   `helm template` + `helm lint` + `make secrets-validate`
3. Add branch→env mapping in workflow logic

## What gets deleted vs moved

### Deleted (replaced by Helm chart + unified scripts)

```
k8s/kind/                        → minikube (cluster.sh)
k8s/apps/base/                   → chart apps subchart templates
k8s/apps/overlays/               → chart envs/*.yaml values
k8s/infra/manifests/             → chart infra subchart templates
k8s/infra/values/                → chart values (merged into subchart values)
k8s/infra/install.sh             → helm upgrade
k8s/infra/jobs/                  → deploy/scripts/seed.sh (seed outside Helm)
scripts/aws/gen-aws-overlay.sh   → Helm renders per-service (no kustomize)
scripts/aws/infra-up.sh          → helm upgrade with aws.yaml
scripts/aws/seed-*.sh            → deploy/scripts/seed.sh --env=aws
scripts/aws/seed-secrets.sh      → deploy/scripts/secrets-seed.sh --env=aws
scripts/aws/up-all.sh            → deploy/scripts/bootstrap.sh --env=aws
scripts/aws/up.sh / down.sh      → terraform directly via Makefile targets
```

### Moved (location change, same content)

```
aws/bootstrap/          → deploy/terraform/bootstrap/
aws/main/               → deploy/terraform/main/
docker/*.yml            → deploy/compose/
docker/vault-configs/   → deploy/secrets/         (canonical secret defs, JSON→YAML)
docker/ecommerce.sql    → deploy/seed/
docker/product.json     → deploy/seed/
docker/api_role.json    → deploy/seed/
docker/product-quantity-history.json → deploy/seed/
scripts/lib/colors.sh   → deploy/scripts/lib/colors.sh  (copy; original stays)
k8s/images/             → deploy/images/
```

### Stays (not deploy-related)

```
scripts/maven/          — Maven build (not deploy)
scripts/services.list   — service registry for docker-compose svc-start/stop
scripts/services/       — docker-compose service lifecycle (stays for compose env)
scripts/kafka/          — Kafka topic/connector management (used by compose)
scripts/vault/          — Vault init/unseal (used by compose; k8s vault is chart-managed)
scripts/seed/           — current compose seed scripts (some consolidate into deploy/scripts/seed.sh)
scripts/error-catalog*  — not deploy
```

## Open questions (to resolve during implementation)

1. **minikube tunnel reliability** — does `minikube tunnel` stay stable for
   long sessions, or does it need a watchdog? Phase 1 verification will reveal
   this; if flaky, add a `cluster.sh tunnel-watch` background process.

2. **Helm chart dependency gating** — upstream chart dependencies
   (ingress-nginx, vault, etc.) are typically enabled/disabled via their own
   values, not via `dependencies[].condition`. Need to verify the cleanest
   way to gate them with `infra.<name>.enabled` — likely via `condition:` in
   `Chart.yaml` referencing the subchart values path.

3. **AWS terraform output resolution** — the `<terraform:*>` placeholders in
   `contexts/aws.yaml` require `secrets-seed.sh` to run `terraform output` at
   seed time. This couples the seed script to terraform state. Alternative:
   a `terraform-outputs.json` file generated by `make aws-up` that the context
   reads. Decide during Phase 4/7.

4. **mongodb-keyfile rotation safety** — the current install.sh creates the
   keyfile only if missing (re-runs must not rotate it). The Helm template
   needs the same guard — use a `lookup` function or a pre-install hook to
   avoid overwriting.

5. **k6 stress test Jobs** — currently in `k8s/apps/base/k6-stress/`. These
   are opt-in Jobs, not always-on Deployments. Decide: include in the apps
   subchart (gated by `apps.k6-stress.enabled: false` by default) or keep as
   standalone scripts outside the chart.

## Non-goals (explicitly out of scope)

- **Changing the application code** — the services, their Spring profiles,
  their configtree/Vault reading logic stays as-is. This is a deploy
  refactor, not an app refactor.
- **Adding new environments** (staging, dev) — the structure supports them
  (add `envs/staging.yaml`), but we're not creating them now.
- **Migrating to GitOps** (ArgoCD, Flux) — the Helm chart is GitOps-ready,
  but we're not deploying a GitOps controller as part of this refactor.
- **NetworkPolicies** — namespaces remain organizational, not security
  boundaries. Adding NetworkPolicies is a separate security hardening effort.
- **Rewriting the Terraform** — `aws/main/` and `aws/bootstrap/` move
  location but keep their content. Terraform refactoring is out of scope.
