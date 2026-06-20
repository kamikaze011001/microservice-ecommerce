# Vault-on-EKS secrets: AWS Secrets Manager + External Secrets Operator

**Date:** 2026-06-20
**Status:** Approved (design)
**Branch:** `feat/aws-deploy`
**Supersedes:** §5 of `2026-06-10-aws-deployment-design.md` (the `envFrom` + relaxed-binding mechanism — see "Why not envFrom" below)

## Problem

All 11 JVM workloads read their config from Vault via Spring Cloud Vault
(`spring.config.import: optional:vault://` + token auth). On EKS we do not want a
self-managed Vault pod holding production-shaped credentials. The `optional:`
prefix does **not** make Vault optional: `spring.cloud.vault.fail-fast: true`
turns a missing Vault into a fatal `createLeasingPropertySourceFailFast` crash, so
every service `CrashLoopBackOff`s when Vault is absent.

We need a cloud-native secrets path that:

1. lets every service boot on EKS **without** Vault,
2. keeps the **same container image** on kind (Vault) and EKS (AWS) — the only
   difference is the kustomize overlay (12-factor),
3. keeps secret **values** out of Terraform state,
4. handles the **actual** Vault content, which includes map-valued and
   dotted/hyphenated property keys.

## What is actually in Vault

Enumerating all 11 Vault paths (`k8s/infra/jobs/03-vault-seed/seed.sh` /
`docker/vault-configs/*.json`) shows the content is two very different kinds of
data:

| Kind | Examples | ~Count |
|---|---|---|
| **Genuine secrets** | db/mongo/redis passwords, `s3.secret-key`, `application.jwk` (RSA private key), paypal client-id/secret, mail creds | ~12 keys |
| **Non-secret config** | ports, kafka topic names, `grpc.server.host`, `feign.client.*.url`, `gateway.routes.<svc>.uri`, saga timeouts | ~80 keys |

Two facts that shape the design:

- Most of the non-secret config is **in-cluster Service DNS**
  (`inventory-service.apps.svc.cluster.local`, etc.) which is **identical on kind
  and EKS** — k8s DNS resolves the same in both clusters.
- The config contains **map-valued, dotted, hyphenated keys**:
  - `gateway.routes.authorization-server.uri`
  - `application.kafka.topics.inventory-service.product.update`
  - `application.kafka.group-id.payment.success`

## Why not envFrom (correcting the earlier spec)

`2026-06-10-aws-deployment-design.md` §5 chose `envFrom` + Spring **relaxed
binding** (`APPLICATION_PAYPAL_CLIENT_ID` → `application.paypal.client-id`). That
works for flat secret keys, but Spring's relaxed binding **cannot reliably
reconstruct map keys that contain hyphens or dots from environment variables**:
`GATEWAY_ROUTES_AUTHORIZATION_SERVER_URI` is ambiguous — the binder cannot tell
whether the `_` separates a map-key level or is part of the key
`authorization-server`. The simple secrets bind fine; the map keys
(`gateway.routes.*`, the kafka topic/group-id maps) **silently fail to bind**.
This is fatal for the gateway and the saga services.

## Decision: configtree, materialized by ESO from Secrets Manager

**Mechanism:** ESO materializes a k8s Secret whose **keys are the exact dotted
Vault property names** (verbatim — no env translation). The pod mounts that Secret
as a volume and reads it via `SPRING_CONFIG_IMPORT=optional:configtree:/etc/app-config/`.
Spring's configtree treats *filename = property name*, so
`gateway.routes.authorization-server.uri` round-trips perfectly. This is a 1:1
translation of the Vault KV path — same keys, same values, same flat-property
semantics Spring Cloud Vault already produced — and it sidesteps the
relaxed-binding problem entirely.

**Zero source change:** `SPRING_CONFIG_IMPORT` is an env var that *replaces*
`application.yml`'s `optional:vault://` import. Setting it plus
`SPRING_CLOUD_VAULT_ENABLED=false` removes Vault from the boot path in the overlay
only — no `.yml` edit, same image on both clusters.

This stays within "Approach 1" (overlay-only, same image, ESO syncs from Secrets
Manager). The only refinement vs the earlier spec is **consumption**: `configtree`
(a mounted file tree) instead of `envFrom`.

## Architecture

```
                       ┌──────────────── on EKS only ────────────────┐
 Terraform             │                                              │
 (secrets.tf)          │   AWS Secrets Manager        ESO controller  │
 creates EMPTY  ──────────▶  app/<service>   ◀──reads──  (IRSA SA,    │
 secret containers     │   {dotted.key: value}    via    GetSecret)   │
 + ESO IRSA role       │         ▲                  materializes      │
 (recovery=0)          │         │ put-secret-value       │           │
                       │         │                        ▼           │
 seed-secrets.sh ──────┼─────────┘            k8s Secret <svc>-config  │
 (cloud twin of        │                      (data keys = dotted     │
  vault import)        │                       property names)        │
                       │                              │ mount volume   │
                       │                     ┌────────▼─────────┐      │
                       │                     │  Deployment pod  │      │
                       │                     │  SPRING_CONFIG_  │      │
                       │                     │  IMPORT=config-  │      │
                       │                     │  tree:/etc/app-  │      │
                       │                     │  config/         │      │
                       │                     │  SPRING_CLOUD_   │      │
                       │                     │  VAULT_ENABLED=  │      │
                       │                     │  false           │      │
                       │                     └──────────────────┘      │
                       └──────────────────────────────────────────────┘
```

Three independent units, each with one responsibility and a testable seam:

### Unit 1 — Terraform `aws/main/secrets.tf` (HUMAN checkpoint ✍️)

- One `aws_secretsmanager_secret` *container* per service path, mirroring the 11
  Vault paths 1:1: `app/core-s3`, `app/ecommerce`, `app/authorization-server`,
  `app/gateway`, `app/product-service`, `app/inventory-service`,
  `app/order-service`, `app/orchestrator-service`, `app/payment-service`,
  `app/bff-service`, `app/mock-paypal-service`.
- `recovery_window_in_days = 0` so an ephemeral teardown/recreate does not collide
  with AWS's default 30-day soft-delete window.
- ESO IRSA: an IAM role assumable by the ESO ServiceAccount via the cluster OIDC
  provider; policy grants `secretsmanager:GetSecretValue` + `secretsmanager:DescribeSecret`
  scoped to `arn:aws:secretsmanager:ap-southeast-1:583178372344:secret:app/*`.
- **No secret values in this file** → nothing secret lands in tfstate.

### Unit 2 — `scripts/aws/seed-secrets.sh` (cloud twin of `scripts/vault/import-secrets.sh`)

- For each service, `aws secretsmanager put-secret-value` a JSON map whose **keys
  are the exact dotted property names** the app expects, e.g.
  `{"gateway.routes.authorization-server.uri": "http://...:6666", "application.jwk": "{...}"}`.
- Sources the same values the Vault seed uses (single source of truth).
- Idempotent: `put-secret-value` writes a new version, overwriting prior content.

### Unit 3 — ESO + per-service ExternalSecret (`k8s/apps/overlays/aws/`)

- ESO installed via Helm in `scripts/aws/infra-up.sh` (cluster-scoped, `infra` ns).
- One `ClusterSecretStore` (AWS provider, region `ap-southeast-1`, IRSA auth via
  the ESO ServiceAccount).
- Per service: an `ExternalSecret` pulling `app/<service>` and writing a k8s Secret
  `<service>-config` whose data keys = the dotted property names. `dataFrom` with
  the AWS provider's JSON extraction preserves the source JSON keys verbatim.
- Shared Deployment overlay patch: mount `<service>-config` at `/etc/app-config/`,
  set `SPRING_CONFIG_IMPORT=optional:configtree:/etc/app-config/` and
  `SPRING_CLOUD_VAULT_ENABLED=false`.

### Data flow at pod start

```
ESO (every refreshInterval) → GetSecretValue app/<svc> → upsert Secret <svc>-config
                                                                │
pod mounts <svc>-config at /etc/app-config/ (key→file)  ◀───────┘
Spring boot: SPRING_CONFIG_IMPORT=configtree:/etc/app-config/ → flat dotted props
           + SPRING_CLOUD_VAULT_ENABLED=false → Vault never dialed
```

## Failure modes

- **Secret missing / ESO not yet synced** → k8s Secret absent → pod stuck
  `ContainerCreating` (volume won't mount). Loud, not a silent 500. Mitigation:
  `seed-secrets.sh` runs before `apply -k`; readiness probe gates traffic.
- **`configtree:` is `optional:`** → an empty dir lets the app boot, then fail on a
  missing `${…}` placeholder — the same signature as a Vault key gap (documented
  SCAR in `k8s/CLAUDE.md`). Diagnosis is identical: trace the missing-placeholder
  crash to the absent key.
- **IRSA misconfigured** → `kubectl describe externalsecret` shows
  `SecretSyncedError`; the k8s Secret is never created → same ContainerCreating
  signal.
- **Drift between the Vault seed and the Secrets Manager seed** → both derive from
  the same source values; a key-set `diff` check guards against divergence (plan
  task).

## Phasing

### Phase 2 (now) — gateway minimal unblock

The gateway needs **no secrets** to boot and already has in-cluster discovery
(Spring Cloud Kubernetes under the `k8s` profile — `lb://` resolves in-cluster, and
the `gateway.routes.*` URI overrides are belt-and-suspenders, not required). So the
gateway gets **only** `SPRING_CLOUD_VAULT_ENABLED=false` in the AWS overlay — no
ESO, no Secrets Manager yet. This proves the Phase-2 image→pod→ALB path with the
one service that has no secret dependency.

### Phase 3 — full ESO rollout

Units 1–3 for all 11 services; each comes up consuming `configtree`. The gateway's
`SPRING_CLOUD_VAULT_ENABLED=false`-only patch is replaced by the shared ESO patch
(it then gets its route URIs + jwt config from `app/gateway` like every other
service).

## Verification (the gate ladder)

This is infrastructure/config, not unit-testable code. Verification is a ladder
where each rung isolates one unit:

1. **Units 1+2:** `aws secretsmanager get-secret-value --secret-id app/<svc>`
   returns the expected JSON — proves Terraform containers + seed, **before ESO
   exists**.
2. **Unit 3 (ESO):** `kubectl describe externalsecret <svc>` shows `SecretSynced`;
   `kubectl get secret <svc>-config` exists with the dotted keys.
3. **Consumption:** pod `Running 1/1`, readiness probe green.
4. **End-to-end:** the existing storefront smoke path (browse → cart → checkout)
   once all services are up.

## Out of scope

- Secret rotation / versioning policy (sandbox uses static dev-shaped values).
- Moving non-secret config out of Secrets Manager into a ConfigMap — considered and
  rejected for now (two materialization paths; configtree handles both kinds
  uniformly with the JSON blob already mirroring the Vault path).
- KMS CMK for the secrets (default AWS-managed key is fine for the sandbox).
- TLS/ACM on the ALB, real DNS hostnames (separate workstream).
