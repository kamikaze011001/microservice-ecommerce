# Local Kubernetes setup for microservice-ecommerce

**Date:** 2026-05-09
**Status:** Design — pending implementation plan

## Goal

Stand up a local Kubernetes cluster that hosts the existing 9 JVM services plus their stateful dependencies, designed so that:

1. Resource use is reasonable on a 48 GB Mac mini while remaining honest enough for k6 stress testing (real HPA scale-out, real network hops, real probes).
2. The same manifests + overlay structure adapts cleanly to AWS EKS later (kind → EKS, MinIO/Vault → S3/Secrets Manager, in-cluster MySQL → RDS) without app code changes.
3. A single `make k8s-bootstrap` brings up an empty cluster to a fully seeded, ready-to-load state.
4. Implementation is structured as a coworking exercise — the AI builds scaffolding and one example of each layer; the human makes the meaningful per-service decisions.

## Non-goals

- Running the existing master/slave MySQL replication topology in k8s. Replication-lag bugs are a staging-environment concern, not a local-stress concern.
- Refactoring application code beyond what is strictly required to drop Eureka in non-compose environments.
- Producing an EKS overlay that works today. The `overlays/aws/` directory is a placeholder; populating it is a follow-up project.
- Replacing or modifying the existing Docker Compose dev workflow. `make up` and `make k8s-up` coexist.

## Architecture

One kind cluster, three namespaces, two manifest tools:

```
kind cluster (1 control-plane + 3 worker nodes)
│
├── infra namespace        — Helm-managed (Bitnami + Hashicorp + Prometheus charts)
│   mysql, kafka (KRaft), mongodb, redis, minio, vault (dev mode),
│   ingress-nginx, kube-prometheus-stack, metrics-server
│
├── apps namespace         — Kustomize-managed
│   authorization-server, gateway, inventory-service, product-service,
│   order-service, payment-service, orchestrator-service, bff-service,
│   [frontend — opt-in via overlay]
│   (no eureka-server — k8s DNS replaces it)
│
└── monitoring namespace   — Prometheus, Grafana, Alertmanager
```

**Why Helm for infra, Kustomize for apps:**
Bitnami / Hashicorp / Prometheus charts are well-maintained — hand-rolling StatefulSets for MySQL or Kafka is a maintenance trap. The 9 owned services are simple enough that Helm's templating buys nothing; Kustomize overlays read like diffs and are easier to learn.

**Why kind:**
Vanilla upstream Kubernetes (1:1 with EKS), trivial multi-node setup so HPA can actually schedule across nodes during a stress run, and `kind delete cluster && kind create cluster` is a 10-second full reset — important when learning and breaking things.

**Why no Eureka in k8s:**
k8s service DNS (`order-service.apps.svc.cluster.local`) replaces Eureka's role natively. Eureka stays for the existing Docker Compose dev environment but is disabled in every other environment (k8s local, future EKS) via `EUREKA_CLIENT_ENABLED=false`.

## Repository layout

```
k8s/
├── kind/
│   └── cluster.yaml                  # 4-node config, registry mirror wiring
├── infra/
│   ├── values/                       # one Helm values file per chart
│   │   ├── mysql.yaml
│   │   ├── kafka.yaml
│   │   ├── mongodb.yaml
│   │   ├── redis.yaml
│   │   ├── minio.yaml
│   │   ├── vault.yaml
│   │   ├── ingress-nginx.yaml
│   │   └── kube-prometheus-stack.yaml
│   ├── jobs/                         # bootstrap Jobs
│   │   ├── 01-mysql-seed/
│   │   ├── 02-mongo-seed/
│   │   ├── 03-vault-seed/
│   │   ├── 04-kafka-connect/
│   │   └── 05-minio-bootstrap/
│   └── install.sh                    # idempotent helm upgrade --install loop
├── apps/
│   ├── base/                         # one directory per service
│   │   ├── authorization-server/
│   │   ├── gateway/
│   │   ├── inventory-service/
│   │   ├── product-service/
│   │   ├── order-service/
│   │   ├── payment-service/
│   │   ├── orchestrator-service/
│   │   ├── bff-service/
│   │   └── frontend/                 # opt-in via overlay
│   └── overlays/
│       ├── local/                    # kind-specific patches
│       └── aws/                      # placeholder for future EKS
├── images/
│   ├── Dockerfile.jvm                # multi-stage template, parameterized
│   └── build.sh                      # builds all 9 images, tags localhost:5001/<svc>:dev
└── README.md
```

The `docker/` directory remains canonical for SQL and JSON seed data — Kustomize `configMapGenerator` consumes those files directly. No duplication between compose and k8s.

## Cluster topology

- 1 control-plane node, 3 worker nodes (kind config).
- Local Docker registry container (`registry:2` on `localhost:5001`) wired into kind's containerd config so worker nodes pull from it.
- Single ingress-nginx instance bound to `localhost:80` and `localhost:443`.
- `/etc/hosts` entry: `127.0.0.1 microecom.local` for ingress hostname.

## Per-service manifest shape

Each service in `k8s/apps/base/<service>/`:

```
deployment.yaml      # 1 container, image: localhost:5001/<service>:dev
service.yaml         # ClusterIP, port = http port from scripts/services.list
configmap.yaml       # non-secret env (kafka bootstrap, downstream URLs, etc.)
hpa.yaml             # CPU 70%, min=1, max=3 (defaults; one service tuned per Checkpoint 3)
servicemonitor.yaml  # scrapes /actuator/prometheus on management port 9091
kustomization.yaml
```

Three services need extras:
- `inventory-service`: additional Service for gRPC port 9090.
- `gateway`: Ingress resource at host `microecom.local`, path `/api/*`.
- `frontend`: Ingress at host `microecom.local`, path `/`. Enabled only via the `with-frontend` overlay variant.

### Probes

All services share the same probe shape, mapped to the existing Spring Boot Actuator endpoints on management port 9091:

```yaml
startupProbe:    GET /actuator/health           port 9091   (failureThreshold tuned for 30-60s JVM boot)
livenessProbe:   GET /actuator/health/liveness  port 9091
readinessProbe:  GET /actuator/health/readiness port 9091
```

The local-dev port-9091 collision documented in CLAUDE.md vanishes in k8s — every Pod has its own loopback. Port 9091 is not exposed via Service; Prometheus reaches it via `ServiceMonitor` → kubelet → Pod IP.

The `MANAGEMENT_ENDPOINT_HEALTH_PROBES_*` configuration that lists which dependencies a service includes in readiness is a **per-service decision** — see Coworking Checkpoint 1.

### Resource requests and limits

All services use a `requests`/`limits` envelope. Memory limits must leave room for JVM non-heap overhead (metaspace, threads, direct buffers — roughly 25–30%). Formula:

```
limits.memory ≈ -Xmx × 1.3 + 200Mi headroom
```

Picking `-Xmx` per service is Coworking Checkpoint 2.

### HPA

Default per service: CPU at 70% utilization, min replicas 1, max replicas 3. The default is intentionally conservative — `order-service` (the primary k6 target) gets bespoke values per Coworking Checkpoint 3.

Metrics-server is installed as part of `kube-prometheus-stack` and is required for HPA to function.

### Secrets

Vault Agent injects secrets from the in-cluster Vault (dev mode) into Pods at startup. Apps read them as files or env vars at the same paths their existing code already uses (`secret/core-s3`, etc.) — zero application code changes.

For future AWS migration, Vault Agent gets swapped for External Secrets Operator pulling from AWS Secrets Manager. Path layout in Vault becomes path layout in Secrets Manager — picking it well now matters (Coworking Checkpoint 5).

### Service discovery (no Eureka)

Two valid approaches, with the call deferred to Coworking Checkpoint 4:

- **A. Static URL injection.** Each consumer service receives env vars in its ConfigMap pointing to k8s Service DNS (e.g., `ORDER_SERVICE_URL=http://order-service:9696`). Gateway routes override `lb://` URIs the same way. No new dependency. Default starting point.
- **B. `spring-cloud-kubernetes-discovery` dependency.** Replaces the Eureka client wholesale; `lb://order-service` keeps working but resolves via the k8s API. More native to k8s/EKS, requires a new dependency and an RBAC role allowing services to list Endpoints.

Option A is wired as the working default for `bff-service`. The remaining consumers are migrated either way during implementation.

## Bootstrap Jobs

Five Jobs in a `bootstrap` namespace, idempotent, ordered by the bootstrap script:

| Order | Job | Wait condition | Source data |
|-------|-----|----------------|-------------|
| 1 | `01-mysql-seed` | mysql StatefulSet Ready | `docker/ecommerce.sql` |
| 2 | `02-mongo-seed` | mongodb StatefulSet Ready | `docker/api_role.json`, `docker/product.json`, `docker/product-quantity-history.json` |
| 3 | `03-vault-seed` | vault Pod Ready | scripted `vault kv put` calls |
| 4 | `04-kafka-connect` | kafka + connect Ready | `scripts/kafka/mongo-connector.sh` |
| 5 | `05-minio-bootstrap` | minio Pod Ready | scripted bucket + policy creation |

Source files are mounted via Kustomize `configMapGenerator` so `docker/*` stays canonical and editing those files automatically rolls into the next apply.

Idempotency pattern: every Job's entrypoint script first checks whether the work has been done (count of seeded rows / docs, presence of secret, presence of connector) and exits 0 without re-applying if so. The MySQL check is provided as the example; designing the Mongo check is Coworking Checkpoint 6.

The Makefile owns ordering — Jobs are NOT chained via `initContainers`, so each can be re-run independently:

```
make k8s-seed-mysql
make k8s-seed-mongo
make k8s-seed-vault
make k8s-seed-kafka-connect
make k8s-seed-minio
make k8s-seed                  # all five in order
make k8s-reseed-mongo          # delete idempotency marker + re-run #2 only
```

## Make targets

```
make k8s-bootstrap        # one-time: kind create + helm install + seed jobs + image build + apply
make k8s-up               # daily: apply overlay, wait for Ready
make k8s-down             # kind delete cluster (full reset, ~10s)
make k8s-status           # kubectl get pods -A in a friendly table
make k8s-logs svc=<name>  # stream logs for one service
make k8s-rebuild svc=<name>  # rebuild image, push to local registry, kubectl rollout restart
make k8s-shell svc=<name> # kubectl exec -it into a Pod
make k8s-stress test=<n>  # run k6 as in-cluster Job pointing at gateway Service
make k8s-up-with-fe       # apply overlay variant that includes frontend Pod
```

`k8s-down` deletes the whole cluster rather than just stopping Pods. The trade-off is ~30s of infra-image pulls on the next `up` in exchange for a guaranteed-clean slate every morning. Appropriate for a learning environment; revisit if it becomes annoying.

## Stress testing with k6

k6 runs as a Kubernetes Job inside the cluster, not from the host:

- Host → ingress adds NAT/loopback hops that distort numbers.
- In-cluster k6 talks to the gateway via real Pod-to-Pod networking — same path real traffic takes in EKS.
- HPA sees realistic load patterns.

The existing scripts in `k6-tests/` are packaged into a small image, mounted via ConfigMap, and run with `kubectl create job --from=cronjob/k6-stress`. A `k8s-stress-host` target remains available for ad-hoc host-side runs.

## Observability

`kube-prometheus-stack` provides Prometheus, Grafana, Alertmanager, and metrics-server in one chart. Every service ships a `ServiceMonitor` that scrapes `/actuator/prometheus` on port 9091. Default Grafana dashboards for JVM and k8s come with the chart; service-specific dashboards are out of scope for this design.

## AWS portability path

The design is shaped so that moving to EKS is a sequence of small, independent swaps rather than a rewrite:

| Local (kind) | AWS (EKS) | Mechanism |
|--------------|-----------|-----------|
| kind cluster | EKS cluster | new overlay |
| Bitnami MySQL Pod | RDS | Service points at RDS endpoint; app config unchanged |
| Bitnami Kafka Pod | MSK | bootstrap servers come from ConfigMap; chart removed |
| MinIO Pod | S3 | core-s3 Vault config flips endpoint; app code unchanged |
| Vault dev Pod | AWS Secrets Manager | Vault Agent → External Secrets Operator |
| `localhost:5001` registry | ECR | image tag prefix changes |
| ingress-nginx | AWS Load Balancer Controller | overlay-level swap |

`overlays/local/` and `overlays/aws/` differ in patches, not in `base/`. The `base/` manifests must remain environment-neutral.

## Coworking checkpoints

The implementation is paced so the AI builds scaffolding and one worked example per layer, then stops at six points and hands the human the keyboard. Each checkpoint is a focused 5–10 lines of code with a real trade-off.

### Checkpoint 1 — Per-service readiness probe `include` list
**Where:** `k8s/apps/base/<service>/configmap.yaml` (`MANAGEMENT_ENDPOINT_HEALTH_PROBES_*`).
**What:** Decide which subset of `readinessState, db, redis, mongo, kafka, mail, vault` belongs in each of 8 services' readiness probe.
**Why it matters:** Wrong list → Pod stuck NotReady or taking traffic before deps are up. CLAUDE.md explicitly flags this.
**AI provides:** The complete list for `authorization-server` as the example.

### Checkpoint 2 — JVM resource requests and limits
**Where:** `k8s/apps/base/<service>/deployment.yaml`.
**What:** Pick `-Xmx`, `requests.memory`, `limits.memory`, `requests.cpu`, `limits.cpu` for 8 services.
**Why it matters:** Under-request → eviction. Over-request → wasted RAM, fewer Pods, HPA can't scale. The k8s memory limit must leave non-heap headroom.
**AI provides:** Complete settings for `gateway` as the example, plus a starter table of guesses and the headroom formula.

### Checkpoint 3 — HPA tuning for the primary stress target
**Where:** `k8s/apps/base/order-service/hpa.yaml`.
**What:** Decide CPU vs memory metric, threshold, max replicas, and `behavior.scaleUp.stabilizationWindowSeconds` for `order-service`.
**Why it matters:** Determines whether k6 graphs show flat suffering or a clean scale-out shoulder.
**AI provides:** Default HPAs for the other 7 services.

### Checkpoint 4 — Service discovery: A vs B
**Where:** `pom.xml` of consumer services + ConfigMap, or `pom.xml` + new `application-k8s.yml` profile.
**What:** Decide whether to migrate consumers from static env-var URLs (option A) to `spring-cloud-kubernetes-discovery` (option B).
**Why it matters:** This is the call you would actually make on EKS; practicing it locally where blast radius is zero is the point.
**AI provides:** Option A wired and working for `bff-service` as the reference.

### Checkpoint 5 — Vault secret path layout
**Where:** `k8s/infra/jobs/03-vault-seed/seed.sh`.
**What:** Design the path layout for ~6 service secrets — flat (`secret/payment-paypal`) vs nested (`secret/payment/paypal`), one key per service vs per concern.
**Why it matters:** Vault paths in dev become External Secrets Operator paths in prod. Naming inherits forward.
**AI provides:** s3, db, and jwt secret seeds as the baseline.

### Checkpoint 6 — Mongo seed Job idempotency check
**Where:** `k8s/infra/jobs/02-mongo-seed/seed.sh`.
**What:** Design the "is the seed already done?" predicate. Options: count > 0, sentinel marker doc, hash-based detection.
**Why it matters:** Idempotency is the most-asked property of bootstrap automation; "80% right" silently fails six months later.
**AI provides:** The MySQL idempotency check (`information_schema` table count) as the example.

## Out of scope (explicit follow-ups)

- Populating `overlays/aws/` with working EKS manifests.
- Migrating Eureka out of the Docker Compose dev workflow.
- Moving from MySQL StatefulSet replicas=1 to a primary+replica topology in local k8s.
- Custom Grafana dashboards beyond what `kube-prometheus-stack` ships.
- NetworkPolicies (cluster runs allow-all; tighten when moving to EKS).
- CI integration (`make k8s-bootstrap` running in GitHub Actions).
