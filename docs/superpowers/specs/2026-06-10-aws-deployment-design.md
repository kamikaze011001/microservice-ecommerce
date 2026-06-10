# AWS Deployment Design — Ephemeral EKS Environment

**Date:** 2026-06-10
**Status:** Approved (brainstorming session)
**Goal:** Deploy the full microservice e-commerce stack to AWS as an *ephemeral, fully IaC-driven* environment, optimized for learning AWS and for interview-grade explainability — not for always-on production.

## 1. Context & Constraints

- **Primary purpose: interview prep.** Every architecture decision must be defensible out loud. The written rationale is part of the deliverable.
- **Ephemeral usage pattern.** Spin up → smoke test → tear down, in sessions of a few hours. Nothing bills meaningfully while down. This forces 100% of the environment into code (Terraform + kustomize) — no click-ops survives teardown.
- **Operator is an AWS beginner** (strong Java/Spring + local k8s background). The phased path teaches IAM/VPC/EKS fundamentals in order.
- **Full stack in scope:** all 9 JVM services + frontend + mock-paypal + supporting infra. The local kind setup (`k8s/`) is the porting source — manifests, seed jobs, and the k6 smoke suite (PR #19) are reused.

## 2. Topology Decision — "B+ Hybrid"

Three options were considered:

| Option | Shape | Verdict |
|---|---|---|
| A — Lift-and-shift | Only VPC/EKS/ECR/ALB from AWS; all infra as pods | Rejected: cheapest but weakest learning + "you self-host MySQL in prod?" is indefensible |
| **B+ — Hybrid (chosen)** | Managed data tier (RDS, S3, Secrets Manager, ElastiCache); Kafka/Mongo/observability self-hosted on EKS | Best explainability-per-dollar; ~35 min spin-up; ~$5–8/session |
| C — Full managed | + MSK, DocumentDB | Rejected: MSK adds 30–40 min provisioning per session; DocumentDB is not real MongoDB and likely breaks the Mongo-CDC saga trigger |

**Governing rule (the interview answer):** *manage the layer where data loss hurts; self-host what is cheap and rebuildable.* MySQL holds orders/payments → RDS. Kafka topics and the Mongo CDC stream are re-seedable in this app → pods. The doc explicitly records "in production I would evaluate MSK; migration path = config + auth change behind the same bootstrap-servers property."

## 3. Target Architecture

Region **ap-southeast-1**, one VPC (10.0.0.0/16), 2 AZs.

- **Public subnets:** ALB + a **single NAT gateway** (deliberate cost cut; prod would run one per AZ for AZ-failure isolation — documented tradeoff).
- **Private subnets:** EKS managed node group — **3× t4g.xlarge Graviton spot**. Runs:
  - Apps (unchanged manifests): gateway, eureka, auth, bff, product, inventory, order, payment, orchestrator, frontend, mock-paypal.
  - Self-hosted infra (ported from kind): Kafka, Schema Registry, Kafka Connect (CDC), MongoDB single-member RS, VictoriaMetrics, Grafana.
  - Add-ons: AWS Load Balancer Controller, External Secrets Operator, EBS CSI driver.
- **DB subnets:** RDS MySQL 8.0 primary + **1 read replica**. The app's master/slave routing keeps working — both slave JDBC URLs point at the single replica. (Replica count is config, not code.)
- **Cache subnets:** ElastiCache Redis, `cache.t4g.micro`.
- **Regional (via IAM/IRSA):** S3 (product images/avatars, replaces MinIO), Secrets Manager (replaces Vault), ECR, CloudWatch, AWS Budgets.
- **Eureka stays.** k8s Services could replace it, but removing it is app surgery orthogonal to this goal; keeping it is the documented tradeoff.

### The four substitutions (everything else ports as-is)

| Local (kind) | AWS | Repo change |
|---|---|---|
| MySQL 1 master + 2 slaves (pods) | RDS primary + 1 read replica | JDBC URLs only |
| MinIO | S3 + IRSA | core-s3 config (endpoint/creds); possibly small code change for credential-less mode (§5) |
| Vault | Secrets Manager + External Secrets Operator | Biggest change — see §5 |
| Redis pod | ElastiCache | host/port config |

## 4. Terraform Layout & Session Lifecycle

```
aws/
├── bootstrap/        # one-time: TF state bucket + lock + AWS Budget alarm ($25/mo, email)
├── main/             # the environment — ONE root module, one apply, one destroy
│   ├── vpc.tf eks.tf rds.tf cache.tf s3.tf ecr.tf secrets.tf outputs.tf …
└── scripts/          # up.sh / down.sh / pre-destroy-cleanup.sh / leak-check.sh
k8s/apps/overlays/aws/  # kustomize overlay: endpoints, ESO resources, ALB ingress
```

- **Single root module, not split state** — deliberate ephemeral simplification. (Documented contrast: at scale you split network/cluster/apps state to shrink blast radius.)
- **Community modules** (`terraform-aws-modules/{vpc,eks,rds}`) for the big primitives; hand-written resources for S3/ECR/Secrets/IAM so raw Terraform is still learned.
- **Persists between sessions:** TF state bucket, ECR images, budget alarm (≪ $1/mo). **Everything else dies**, including RDS data — re-seeded on every `aws-up` by the existing seed jobs.

### Makefile targets

| Target | Action |
|---|---|
| `make aws-bootstrap` | once: state bucket, lock, budget alarm |
| `make aws-up` | terraform apply (~35 min) → push missing images to ECR → `kubectl apply -k overlays/aws` → seed jobs → print gateway URL |
| `make aws-rebuild svc=…` | rebuild + push + rollout one service (mirrors `k8s-rebuild`) |
| `make aws-smoke` | k6 storefront-funnel smoke vs ALB URL |
| `make aws-down` | pre-destroy cleanup → terraform destroy |
| `make aws-leak-check` | list still-billing resources (ALBs, EBS, NAT, EIPs) |

### Teardown gotchas (designed-in)

1. **ALB and EBS volumes are created by in-cluster controllers, not Terraform** — they are invisible to TF state. `down.sh` must `kubectl delete ingress,pvc --all` and wait *before* `terraform destroy`, or VPC deletion hangs on orphaned ENIs/volumes.
2. **Secrets Manager recovery window:** set `recovery_window_in_days = 0` so destroyed secrets can be recreated under the same name next session.
3. ECR repos use `force_delete = true` only in `bootstrap` teardown paths; normal sessions keep images.

## 5. Secrets & Identity

**Flow:** Terraform writes one JSON secret per service to Secrets Manager (`app/<service>`, keys already in `ENV_VAR` form) → External Secrets Operator (IRSA-authenticated) materializes native k8s Secrets → Deployments mount via `envFrom` → Spring **relaxed binding** maps `APPLICATION_PAYPAL_CLIENT_ID` → `application.paypal.client-id`. Env vars outrank `application.yml` in Spring's property-source precedence, so application code is unchanged.

**Why ESO over Spring Cloud AWS:** the JVM only ever sees env vars → the same image runs on kind and EKS; per-environment differences live entirely in the kustomize overlay (12-factor).

**Known work items (verified against real code during planning, not assumed):**

1. Each service's `spring.config.import: vault://` must not fail when Vault is absent — add `optional:` prefix or profile-gate the import under a new `aws` Spring profile. Mechanical, per-service.
2. `core-s3` must support the SDK default credential chain (IRSA) when no static keys are configured — likely a small change to its client builder.

**IRSA roles (least privilege, one per workload):** ALB controller; ESO (`secretsmanager:GetSecretValue` on `app/*`); product-service + authorization-server (`s3:PutObject/GetObject` on the images bucket). No long-lived AWS credentials exist inside the cluster.

**Secret values source:** an uncommitted local tfvars file (gitignored), mirroring the existing `docker/.env` convention.

## 6. Build & Images

- Local Apple Silicon builds → **arm64 images** → **Graviton (arm64) nodes**. No cross-compilation, no exec-format CrashLoops, ~20% cheaper than x86. Temurin bases are multi-arch; Dockerfiles unchanged.
- `aws-up` pushes only ECR-missing images; mock-paypal (Java 25) builds like the rest.
- CI/CD (GitHub Actions → ECR via OIDC, no stored AWS keys) is **stretch phase 6**, not baseline.

## 7. Verification & Cost Guardrails

**Definition of a successful session:** `make aws-smoke` passes the full saga end-to-end — browse → cart → order → mock-paypal approval → payment captured → inventory decremented — against the public ALB URL. Green pods alone don't count.

**Cost defense in depth:**
1. AWS Budget alarm, $25/month, email.
2. `make aws-leak-check` after every teardown.
3. Spot + Graviton + single NAT ⇒ ≈ $1.20–1.60/hour up; ≈ $5–8 per 3–4 h session.

## 8. Phased Path (implementation-plan skeleton)

| Phase | Deliverable | Learning focus |
|---|---|---|
| 0 | IAM admin + MFA, CLI profiles, `bootstrap/` stack, budget alarm | IAM fundamentals, TF state |
| 1 | VPC + EKS + ALB controller; hello-nginx reachable from internet | VPC/subnets/NAT, IRSA, ingress |
| 2 | ECR + self-hosted infra (Kafka, Mongo, observability) + one service | EBS CSI / storage classes, ECR |
| 3 | Secrets Manager + ESO; all 11 workloads up (DBs still pods) | ESO, Spring config precedence |
| 4 | Swaps: RDS + replica, ElastiCache, S3 + IRSA | RDS, security groups, app IRSA |
| 5 | Full saga smoke; teardown/re-up drill; **interview-notes doc** | the rebuild-from-zero story |
| 6 (stretch) | GH Actions → ECR via OIDC; Route53 + ACM TLS | CI/CD, DNS/certs |

Phases 2→4 deliberately run the app on self-hosted DBs first, then substitute managed services — isolating failures to the swap, mirroring real-world managed-service adoption.

Phase 5's interview-notes doc collects every recorded tradeoff (hybrid vs full-managed, one NAT, ESO vs Spring Cloud AWS, Graviton, single root module, Eureka retention) as rehearsed Q&A.

## 9. Out of Scope

- Always-on hosting, custom domain/TLS by default (stretch), multi-region, MSK/DocumentDB, removing Eureka, RDS snapshots between sessions (seeding is scripted), production-grade observability beyond the ported VM/Grafana stack.
