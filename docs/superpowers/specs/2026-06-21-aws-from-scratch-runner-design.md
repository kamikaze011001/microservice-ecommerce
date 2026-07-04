# AWS From-Scratch Bring-Up Runner — Design

**Date:** 2026-06-21
**Branch:** `feat/aws-deploy` (scripts/docs grown from that workstream — no new branch)
**Status:** Approved design → ready for implementation plan

## Goal

Provide a single orchestrated path to bring the whole stack up on AWS/EKS **from
nothing** — after a `make aws-down`, or on a fresh account — without having to
remember the ordered, dependency-laden sequence of steps. The cloud twin of
`make k8s-bootstrap`.

## Problem

There is no all-in-one AWS bring-up. The existing targets (`aws-up`, `aws-push`,
`aws-infra-up`, `seed-secrets.sh`, `seed-rds.sh`) are correct building blocks, but
the operator must run them in the right order, satisfy inter-step dependencies by
hand (RDS endpoints exist only after apply; ESO must exist before app
ExternalSecrets resolve; SQL data seeds need the apps' Hibernate `ddl-auto` to
have created the schema first), and remember which data stores still need seeding.
Two gaps in the prior mental model, both surfaced during review:

1. **MongoDB was not being seeded at all.** Mongo stays self-hosted on EKS in
   Phase 4 (only MySQL/Redis/MinIO move to managed services). Without the
   `api_role` collection the gateway 403s every route; without `product` the
   catalog is empty.
2. **Inventory stock was not being seeded.** `inventory_product` +
   `product_quantity_history` in RDS are what make cart/checkout show real
   availability instead of "0 available."

## What persists across `aws-down` (so the runner can skip work)

`aws-down` runs `terraform destroy` on **`aws/main` only**. The separate,
persistent `aws/bootstrap` stack — **ECR repos**, the Terraform state S3 bucket,
and the DynamoDB lock table — is untouched. Therefore **pushed container images
survive a teardown.** That is why image push defaults to *reuse*: a from-scratch
re-run after `aws-down` does not need to rebuild images unless code changed.

| Layer | Stack | Survives `aws-down`? |
|---|---|---|
| ECR images, TF state, lock table | `aws/bootstrap` | **Yes** |
| VPC, EKS, ALB, RDS, ElastiCache (4b), S3 (4c) | `aws/main` | No (rebuilt) |

## Architecture

A thin orchestration layer over existing leaf scripts. `up-all.sh` is pure
sequencing — it never reimplements Terraform/kubectl/AWS calls, it delegates to
the same scripts the individual `make` targets call. The inter-step dependencies
are enforced as explicit gates (preflight fail-fast; rollout-status before SQL
seeds). `RUNBOOK.md` documents the identical sequence for the by-hand path.

```
make aws-all ──▶ scripts/aws/up-all.sh
  0. preflight     creds (docker/.env, k8s/.env, seed.sh JWK) + tfvars db pw — fail fast
  1. up.sh         cluster + RDS                          [= make aws-up]
  2. push-images   PUSH=reuse (default) | all             [= make aws-push svc=all]
  3. infra-up.sh   Mongo + Kafka + ESO + CDC connector    [= make aws-infra-up]
  4. seed-mongo.sh api_role + product + qty-history → Mongo      ★ NEW, pre-apps
  5. seed-secrets  RDS JDBC URLs + app config → Secrets Manager
  6. apps          kubectl apply -k k8s/apps/overlays/aws
                   └─ GATE: rollout status auth-server AND inventory-service (required)
  7. seed-rds.sh   accounts/roles/users → RDS             ★ post-apps
  8. seed-inventory inventory_product + product_quantity_history → RDS  ★ NEW, post-apps
  9. [Phase 4c]    S3 product images — echo "deferred (no bucket until 4c)", skip
     footer        Gateway ALB hostname + login-verify hint + aws-down cost reminder
```

## Components

### New files

- **`scripts/aws/up-all.sh`** — the orchestrator. `set -euo pipefail`,
  `AWS_PROFILE` default `microecom`, per-step banners. Contains the preflight
  (credential loader + tfvars check) and the rollout gate. Calls the leaf scripts
  in order. On failure it stops; re-run from the top resumes (steps are
  idempotent). `PUSH` env: `reuse` (default) | `all`.

- **`scripts/aws/seed-mongo.sh`** — runs the existing `k8s/infra/jobs/02-mongo-seed`
  Job against the EKS cluster (Mongo is in-cluster, so the Job is reusable
  verbatim): create configmap `mongo-seed-scripts` from the Job's `seed.sh`,
  configmap `mongo-seed-data` from `docker/api_role.json` + `docker/product.json`
  + `docker/product-quantity-history.json`, apply `job.yaml` in the `bootstrap`
  namespace, wait `--for=condition=complete`. Idempotent (delete+recreate Job).

- **`scripts/aws/seed-inventory.sh`** — RDS stock seed, mirroring `seed-rds.sh`'s
  pattern (one-shot `mysql:8.0` pod in `apps`, `MYSQL_PWD` to keep the password
  off argv, host/password from `terraform output`). Loads `inventory_product` +
  `product_quantity_history` (the AWS twin of `scripts/seed/k8s-inventory.sh` /
  `scripts/seed/mysql-inventory-products.sh` + `mysql-product-quantity-history.sh`).
  Guards on a row-count so a re-run skips. Requires inventory-service's tables to
  exist first (enforced by the step-6 rollout gate).

- **`scripts/aws/RUNBOOK.md`** — the by-hand path for interview-prep learning. Per
  step: the command, *why it sits in this position* (the dependency it satisfies),
  and a *verify gate* before moving on. Includes the "what persists vs. what
  rebuilds across `aws-down`" note.

### Modified files

- **`Makefile`** — add `aws-all` target (`@scripts/aws/up-all.sh`) and append
  `aws-all` to the AWS `.PHONY` line. `aws-up` / `aws-push` / `aws-infra-up`
  unchanged.

### Reused unchanged

`up.sh`, `push-images.sh`, `infra-up.sh` (already registers the Mongo CDC
connector), `seed-secrets.sh`, `seed-rds.sh`, the committed
`k8s/apps/overlays/aws` overlay, the `02-mongo-seed` Job.

## Credential handling

The runner re-enters **nothing** — all secrets already exist in the repo from
local setup. A preflight credential loader resolves each, preferring an
already-exported env var, then falling back to the canonical source, then failing
loud with the exact file/var to populate.

| Secret | Source | User action |
|---|---|---|
| `PAYPAL_CLIENT_ID` / `_SECRET` | `docker/.env` (gitignored) | already filled for local |
| `APPLICATION_MAIL_USERNAME` / `_PASSWORD` | `k8s/.env` (gitignored) | already filled for local |
| `APPLICATION_JWK` | extracted from `k8s/infra/jobs/03-vault-seed/seed.sh` (committed) | **none — auto** |
| `db_master_password` | `aws/main/terraform.tfvars` (gitignored) | the one AWS-specific fill |

Resolution order per secret:
1. Use the value if already exported (ad-hoc override).
2. Else source `docker/.env` (PayPal) / `k8s/.env` (mail).
3. JWK: always extract from `seed.sh` (single source of truth — guarantees
   byte-identical to local, which the gateway requires since it caches JWKS by
   `kid`); an exported `APPLICATION_JWK` overrides.
4. If still empty → exit non-zero naming the file + var to fill.

`db_master_password` is verified present in `terraform.tfvars` (a grep, not a read
into logs) before the ~15-min apply.

## Seed model — full storefront parity with `k8s-bootstrap` (minus S3)

| Local `k8s-bootstrap` seed | AWS equivalent | Where |
|---|---|---|
| `02-mongo-seed` (api_role+product+qty-history) | `seed-mongo.sh` (same Job) | step 4, pre-apps |
| `03-vault-seed` (secrets) | `seed-secrets.sh` → Secrets Manager | step 5 |
| `04-kafka-connect-register` (saga CDC) | inside `infra-up.sh` | step 3 |
| `05-minio-bootstrap` (bucket) | S3 — **Phase 4c** | step 9 slot (skipped) |
| `k8s-seed-mysql` (accounts) | `seed-rds.sh` | step 7, post-apps |
| `k8s-seed-inventory` (stock) | `seed-inventory.sh` | step 8, post-apps |
| `k8s-seed-perftest` (k6 fixtures) | optional | out of scope |

### Why S3 images are deferred (not an oversight)

There is no object store on AWS until Phase 4c: `infra-up.sh` explicitly excludes
MinIO, `aws/manifests/` has no MinIO manifest, and `seed-secrets.sh` still points
`s3.endpoint` at a `minio.infra.svc.cluster.local` Service that is not deployed.
An image seeder now would upload to nothing. The catalog renders with broken
`<img>` links until 4c, but **browse, cart, and checkout work without images.**
Step 9 is a labeled, explicitly-skipped slot so the Phase-4c image seed drops in
without restructuring the sequence.

## Error handling

- **Fail-fast preflight** (step 0): missing cred or tfvars password aborts before
  any billable apply, so you never strand a running cluster on a missing var.
- **`set -euo pipefail`**: first failure stops the run.
- **Idempotent resume**: re-run from the top — `apply` is a no-op if current,
  `seed-secrets` overwrites, `apply -k` reconciles, `seed-mongo`/`seed-rds`/
  `seed-inventory` guard on existing data. No checkpoint/state file (it would
  drift from reality the moment you `aws-down`).
- **The one hard sequencing guarantee**: the step-6 rollout gate waits on
  `auth-server` (schema for accounts) and `inventory-service` (tables for stock)
  as *required* before the post-apps SQL seeds; the remaining deployments are
  waited best-effort (non-fatal).

## Verification

Offline gates only (no AWS spend; Claude runs these):
- `bash -n` on `up-all.sh`, `seed-mongo.sh`, `seed-inventory.sh`.
- `kubectl kustomize k8s/apps/overlays/aws` builds clean.
- `make -n aws-all` dry-run.

The billed end-to-end run is the user's:
- `make aws-all` from a clean teardown → all steps green.
- Verify: login returns a JWT (clears Phase-4a "Bug B"); catalog lists products;
  cart shows real stock.
- `make aws-down` + `make aws-leak-check` after.

## Out of scope

- S3 image seed + bucket + IRSA (Phase 4c — the step-9 slot fills in there).
- ElastiCache Redis swap (Phase 4b).
- k6 perftest fixtures.
- Any change to `aws-down` / teardown (already works).

## Operating constraints

All steps bill AWS (account `583178372344` / profile `microecom` / region
`ap-southeast-1`) — the user runs `make aws-all`; Claude writes the scripts and
runs only the offline gates. Never log secrets. Never commit tfvars / state /
`.terraform`. Commit messages end with the Co-Authored-By trailer.
