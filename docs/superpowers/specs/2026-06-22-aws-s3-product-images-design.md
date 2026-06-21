# AWS S3 Product Images (Phase 4c) — Design

**Date:** 2026-06-22
**Branch:** `feat/aws-deploy` (continuation — full-AWS-ecosystem workstream, no new branch)
**Status:** Approved design → ready for implementation plan

## Goal

Replace the undeployed in-cluster MinIO with real Amazon S3 + IRSA so product
images and user avatars **upload** (presign → direct PUT) and **serve**
(anonymous GET) on AWS, the seeded catalog renders with real images, and
`scripts/aws/up-all.sh` step 9 stops being a deferred stub. `core-s3` stays a
single codebase that serves MinIO locally and S3 on AWS — distinguished only by
config (one blank field), so local dev is untouched.

## Problem

Today on AWS the object store is a phantom:

- `scripts/aws/seed-secrets.sh:61-69` seeds the `core-s3` config pointing at
  `http://minio.infra.svc.cluster.local:9000` with `minioadmin` static creds and
  `path-style=true` — an in-cluster MinIO that `infra-up.sh` never deploys.
- `up-all.sh:150-153` (step 9) is an explicit deferred stub: "no object store on
  AWS until Phase 4c… the catalog renders with broken `<img>` links."
- The seeded image URLs don't resolve on AWS regardless of a bucket:
  - The storefront browses the **Mongo `product` collection**, which
    `seed-mongo.sh:34-38` loads from `docker/product.json` **verbatim** — every
    `imageUrl` is `http://localhost:9000/ecommerce-media/products/...` (the
    dev's own localhost, meaningless behind the ALB).
  - The MySQL `inventory_product` table (order snapshots) is seeded by
    `seed-inventory.sh`, which rewrites that host to `http://media.microecom.local/`
    — a dead local ingress host on AWS.

So Phase 4c must do three things: provision the bucket + access model, make the
pods authenticate to it (IRSA), and point the seeded image URLs at the real S3
URL so the catalog renders "like local."

## Decision: real S3 + IRSA, public-read bucket, image seed

Three decisions, all confirmed with the user:

1. **IRSA, not static IAM keys.** The cluster is already keyless everywhere else
   (EBS CSI, ALB controller, ESO all use IRSA). A long-lived IAM user just for S3
   would be the one un-rotatable credential in an otherwise keyless stack, and the
   interview-incoherent choice. The code cost is small and the code already leans
   toward it (see "The seam" below).
2. **Public-read bucket, not CloudFront.** Local serves both `products/` and
   `avatars/` prefixes anonymously (`docker/minio.yml:30-31`,
   `mc anonymous set download`). A public-read S3 bucket policy on those two
   prefixes is exact parity. CloudFront (distribution + OAC + ACM cert) is real
   production hardening but pure YAGNI for an ephemeral learning stack — a clean
   future phase.
3. **Seed the sample images.** `docker/seed-images/<category>/<slug>.jpg` (20
   products) are uploaded to S3 in step 9, mirroring
   `scripts/seed/k8s-product-images.sh` (which does the same with `mc cp` into
   kind's MinIO), so the catalog renders identically to local.

### The seam: one blank field switches credential modes

`core/core-s3/.../S3Config.java:54` hardcodes `StaticCredentialsProvider`. That is
the only obstacle to IRSA — the presigner (`S3Config.java:38-45`) was *already*
written to fall back to the AWS default endpoint when `public-endpoint` is blank
("Falls back to the internal endpoint when no separate public endpoint is
configured (e.g. real AWS S3)"). The change is to make `credentials()` switch on a
blank access key:

```java
private static AwsCredentialsProvider credentials(S3Properties props) {
    if (props.getAccessKey() == null || props.getAccessKey().isBlank()) {
        return DefaultCredentialsProvider.create();   // resolves the IRSA web-identity token
    }
    return StaticCredentialsProvider.create(
        AwsBasicCredentials.create(props.getAccessKey(), props.getSecretKey()));
}
```

Local MinIO keeps passing `minioadmin` → the static branch, untouched. AWS seeds a
blank key → the default credential chain → the pod's IRSA role. No profile flag,
no second bean — the blank key is the sentinel.

**Why IRSA + presign compose cleanly:** the presigned PUT URL is signed with the
pod's *temporary* STS credentials (it carries `X-Amz-Security-Token`); it stays
valid for the 5-minute presign TTL, well within the credential lifetime. Serving
needs no credentials at all (anonymous-read prefix), so the IAM policy is only
`PutObject` + `GetObject` — nothing else.

## Architecture

S3 lives in the `aws/main` Terraform stack alongside VPC / EKS / ALB / RDS /
ElastiCache. It is created in `up-all.sh` step 1 (`terraform apply`, no added
wall-clock) and destroyed with the stack on `aws-down` (the bucket is
`force_destroy = true`, so teardown never hangs on a non-empty bucket).

```
make aws-all ──▶ up-all.sh
  1. terraform apply (aws/main)   ← NOW also: S3 bucket + public-read policy + CORS + IRSA role
                                     + outputs s3_bucket_name / s3_irsa_role_arn / s3_public_base_url
  2-3. infra-up + seed-mongo      ← seed-mongo rewrites product.json imageUrl host → S3 base
  ...
  5a. [NEW] stamp s3_irsa_role_arn onto 2 ServiceAccount manifests (mirror ESO stamping)
  5b. seed-secrets.sh             ← core-s3 block flips MinIO → real S3 (blank key, path-style=false)
  6.  apps + rollout gate         ← product-service / auth-server pods assume the S3 role via IRSA
  8.  seed-inventory.sh           ← rewrite imageUrl host → S3 base (was media.microecom.local)
  9.  [NEW] seed-images.sh        ← aws s3 cp docker/seed-images/* → s3://.../products/{id}/{slug}.jpg
```

(Exact step numbering/order for 5a/5b and the seed-mongo call-site is confirmed
against `up-all.sh`/`infra-up.sh` during planning; the dependency that matters is
**every script reading a TF output runs after step 1's `terraform apply`** — the
same guard RDS/Redis already rely on.)

| Layer | Stack | Survives `aws-down`? |
|---|---|---|
| ECR images, TF state, lock table | `aws/bootstrap` | Yes |
| VPC, EKS, ALB, RDS, ElastiCache, **S3 bucket** | `aws/main` | No (rebuilt; `force_destroy` wipes objects) |

## Components

### New file — `aws/main/s3.tf` — `[CHECKPOINT — HUMAN ✍️]`

The user writes it (interview-prep learning), mirroring `aws/main/rds.tf` and
`aws/main/elasticache.tf`. Claude scaffolds PART A–E with `TODO(HUMAN)` markers
and reviews; Claude does **not** write the solution. Parts:

- **PART A — `aws_s3_bucket "media"`** — bucket name
  `"${var.project}-media-${data.aws_caller_identity.current.account_id}"`
  (globally-unique, account-suffixed like the tfstate bucket), `force_destroy =
  true`. Requires `data "aws_caller_identity" "current" {}` — add it to
  `aws/main/data.tf` (which today holds only `aws_availability_zones`).
- **PART B — public read** — `aws_s3_bucket_public_access_block` relaxed to permit
  a public **bucket policy** (`block_public_policy = false`,
  `restrict_public_buckets = false`) + `aws_s3_bucket_policy` granting anonymous
  `s3:GetObject` on `${bucket_arn}/products/*` and `${bucket_arn}/avatars/*` only.
  The Terraform equivalent of local's `mc anonymous set download`.
- **PART C — `aws_s3_bucket_cors_configuration`** — allow `PUT` and `GET` from the
  storefront origin (e.g. the ALB host / `http://microecom.local`), with
  `allowed_headers = ["*"]`. **The one thing local MinIO gives for free that real
  S3 does not** — the browser's direct PUT to the presigned URL is cross-origin
  and S3 enforces CORS. Omit it and uploads fail with an opaque CORS error while
  GETs still work (a confusing half-broken state).
- **PART D — IAM** — `aws_iam_policy "s3_media"` (scoped `s3:PutObject` +
  `s3:GetObject` on the two prefixes, authored via an `aws_iam_policy_document`
  data source or `jsonencode`) + `module "s3_irsa"` using
  `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`
  `~> 5.0` (the same module used for EBS/ALB/ESO), with
  `role_policy_arns = { media = aws_iam_policy.s3_media.arn }`,
  `oidc_providers.main.provider_arn = module.eks.oidc_provider_arn`, and
  `namespace_service_accounts = ["apps:product-service",
  "apps:authorization-server"]` (one role, two SAs).
- **PART E — outputs** — `s3_bucket_name` (`= aws_s3_bucket.media.bucket`),
  `s3_irsa_role_arn` (`= module.s3_irsa.iam_role_arn`), and `s3_public_base_url`
  (`= "https://${aws_s3_bucket.media.bucket}.s3.${var.region}.amazonaws.com"`) —
  the single source of truth the three seed scripts read, so the served URL is
  never reconstructed in more than one place.

### Modified — `core/core-s3/.../S3Config.java` — *Claude*

The blank-key fallback shown under "The seam." Adds the
`DefaultCredentialsProvider` import. ~6 lines. Triggers a `cores` image rebuild
(HUMAN, billed) and therefore rebuilds of the two consumer images
(product-service, authorization-server) that bake the cores JARs.

### New — ServiceAccount wiring (AWS overlay only) — *Claude*

product-service and authorization-server currently run with the default SA (only
`gateway` has an SA today, in `k8s/apps/base/gateway/rbac.yaml`). For each of the
two, in its `k8s/apps/overlays/aws/<svc>/` directory:

- `serviceaccount.yaml` — an SA named `<svc>` in the `apps` namespace with
  `annotations: eks.amazonaws.com/role-arn: PLACEHOLDER_S3_ROLE_ARN`, byte-for-byte
  the pattern of `k8s/infra/manifests/external-secrets-sa.yaml`.
- a strategic-merge patch setting `spec.template.spec.serviceAccountName: <svc>`
  on the Deployment.
- both registered in that overlay's `kustomization.yaml`.

AWS-overlay-only, so kind/local Deployments keep the default SA and are untouched.
The SA name/namespace MUST match the `namespace_service_accounts` entries in
`s3.tf` PART D.

### Modified — `scripts/aws/up-all.sh` — *Claude*

1. **Stamp step (new, before the apps apply):** read
   `terraform output -raw s3_irsa_role_arn` and `sed`-replace
   `PLACEHOLDER_S3_ROLE_ARN` in the two SA manifests before `kubectl apply -k`,
   exactly mirroring the ESO ARN stamp in `infra-up.sh:57-61` (fail-loud if the
   output is missing).
2. **Step 9 (replace the stub):** call `scripts/aws/seed-images.sh` instead of the
   "DEFERRED" echo block.

### Modified — `scripts/aws/seed-secrets.sh` core-s3 block — *Claude*

Flip the `put core-s3` block (lines 61-69) from MinIO to real S3, reading the
bucket/URL from the TF outputs (via the existing `tf_out` helper, which already
fails loud on a missing output):

| key | was (MinIO) | now (AWS S3) |
|---|---|---|
| `s3.endpoint` | `http://minio.infra…:9000` | `""` (blank → AWS default endpoint) |
| `s3.public-endpoint` | `http://media.microecom.local` | `""` (blank → presigner uses AWS default host) |
| `s3.region` | `us-east-1` | `ap-southeast-1` |
| `s3.bucket` | `ecommerce-media` | `$(tf_out s3_bucket_name)` |
| `s3.access-key` / `s3.secret-key` | `minioadmin` / `minioadmin` | `""` / `""` (IRSA sentinel) |
| `s3.path-style` | `true` | `false` (virtual-hosted) |
| `s3.public-base-url` | `http://media.microecom.local/ecommerce-media` | `$(tf_out s3_public_base_url)` |

`presign-ttl`, `max-upload-size`, `allowed-types` unchanged.

### Modified — `scripts/aws/seed-mongo.sh` — *Claude* (the critical storefront one)

The Mongo `product` collection is what the storefront browses, and it is seeded
**verbatim** from `docker/product.json` (line 36). Add: read
`S3_BASE="$(tf_out s3_public_base_url)"`, then `jq`-rewrite the `imageUrl` host
(`http://localhost:9000/ecommerce-media/` → `${S3_BASE}/`, dropping the
`ecommerce-media/` path segment because the bucket moves into the virtual-hosted
hostname) into a temp file, and create the configmap with
`--from-file=product.json=<temp>` (the key must stay `product.json` — the Job's
`seed.sh` reads that filename). The rewrite must be null-safe (products with no
`imageUrl`). This adds the first `tf_out` read to seed-mongo.sh — same
post-apply guard as the other seed scripts.

### Modified — `scripts/aws/seed-inventory.sh` — *Claude*

Change the existing host rewrite (currently `gsub("http://localhost:9000/";
"http://media.microecom.local/")`, line ~76) to target the S3 base:
`http://localhost:9000/ecommerce-media/` → `${S3_BASE}/` where
`S3_BASE="$(tf_out s3_public_base_url)"`. Keeps the order_item snapshot URLs
consistent with the Mongo catalog (the comment already promises this consistency).

### New — `scripts/aws/seed-images.sh` — *Claude*

Mirrors `scripts/seed/k8s-product-images.sh` but uses the AWS CLI on the runner
host (no `kubectl exec` into MinIO): for each product in
`scripts/seed/products-manifest.json`,
`aws s3 cp "docker/seed-images/$category/$slug.jpg"
"s3://$(tf_out s3_bucket_name)/products/$productId/$slug.jpg"
--content-type image/jpeg`. Idempotent (cp overwrites), warns on a missing source
file, prints an uploaded/missing tally. Runs with `AWS_PROFILE=microecom`.

### Modified — `scripts/aws/RUNBOOK.md` — *Claude*

Replace the step-9 "DEFERRED to Phase 4c" wording with the real behavior (S3
bucket created in step 1, images seeded in step 9), and add the S3 bucket to the
"what persists across `aws-down`" note (it does **not** persist; `force_destroy`).

### Explicitly unchanged

- **`Makefile`** — `aws-all` already rides `terraform apply` + `up-all.sh`; no new
  target.
- **`scripts/aws/leak-check.sh`** — scans only resources that *escape* Terraform.
  The S3 bucket is TF-managed in `aws/main` with `force_destroy`, so it is
  destroyed cleanly — intentionally **not** added, matching the RDS/ElastiCache
  precedent.
- **Local dev (`docker/`, kind overlays, `core-s3` static path)** — the blank-key
  sentinel means MinIO keeps the static-credentials branch; nothing local changes.

## Data flow (upload, on AWS)

1. Browser → `POST /v1/products/{id}/image/presign`. The product-service pod,
   holding the IRSA role via its annotated SA, signs a PUT URL with its temporary
   STS credentials (valid for the 5-minute TTL).
2. Browser → `PUT` bytes **directly to S3** (CORS-allowed) → object lands at
   `products/{id}/{uuid}.jpg`.
3. Browser → `PUT /v1/products/{id}/image {objectKey}`. The pod HEAD-checks the
   object (IRSA `GetObject`), validates the `products/{id}/` prefix, and stores
   `https://<bucket>.s3.ap-southeast-1.amazonaws.com/products/{id}/{uuid}.jpg`.
4. Any browser GETs that URL anonymously (public-read prefix) — identical to the
   local MinIO serve path. Avatars follow the same flow via authorization-server.

## Error handling

- **Missing TF output fails loud** — every `tf_out` read (bucket, base URL) and the
  ARN stamp abort with an actionable "run `terraform apply` first" message, the
  same guard RDS/Redis use. No silent empty bucket or unstamped SA.
- **CORS is the predictable failure mode** — called out in PART C so it is designed
  in, not discovered at runtime.
- **`force_destroy = true`** keeps `aws-down` from hanging on a non-empty bucket.
- **Idempotent resume** — `terraform apply` is a no-op when current;
  `seed-secrets.sh` overwrites; `aws s3 cp` overwrites; the mongo/inventory rewrites
  are deterministic. A re-run after a mid-way failure is safe.
- **IRSA misconfig surfaces at the rollout gate** — if the SA annotation/role is
  wrong, presign/HEAD calls 403; the step-6 rollout gate already `describe`s the
  failing deployment and points at logs.

## Verification

**Offline gates (Claude, no AWS spend):**
- `terraform fmt -check` on `aws/main/s3.tf` (after the user writes it).
- `mvn -q -pl core/core-s3 compile` (or the project's cores build) for the Java
  change — confirms the `DefaultCredentialsProvider` import resolves.
- `bash -n` on `up-all.sh`, `seed-secrets.sh`, `seed-mongo.sh`, `seed-inventory.sh`,
  `seed-images.sh`.
- `kubectl kustomize k8s/apps/overlays/aws/product-service` and
  `…/authorization-server` — proves the SA manifest + serviceAccountName patch
  build cleanly.
- `grep` proving the `core-s3` block reads `$(tf_out s3_bucket_name)` + a blank
  access key, and that both seed rewrites target `s3_public_base_url`.

**Billed end-to-end (the user's):**
- Rebuild `cores` + product-service + authorization-server images → `make aws-all`
  from a clean teardown → all steps green; step 9 seeds images.
- Verify: catalog lists products **with real images**; uploading a new product
  image through the UI presigns, PUTs, and renders; avatar upload works;
  `make aws-down` wipes the bucket.

## Coworking-learning split

| Artifact | Owner |
|---|---|
| `aws/main/s3.tf` PART A–E (bucket, public-read policy, CORS, IAM policy, IRSA, outputs) + `data.aws_caller_identity` | **HUMAN ✍️** — writes it for interview prep; Claude scaffolds the skeleton + `TODO`s and reviews |
| `core-s3` `S3Config.java` blank-key fallback | Claude |
| Overlay SAs + serviceAccountName patches + kustomization | Claude |
| `up-all.sh` (ARN stamp + step-9 call), `seed-secrets.sh`, `seed-mongo.sh`, `seed-inventory.sh`, `seed-images.sh`, `RUNBOOK.md` | Claude |
| Offline gates | Claude |
| `cores`/service image rebuilds + `make aws-all` (billed) | HUMAN — runs it |

## Out of scope

- **CloudFront / private bucket + OAC + ACM** — public-read is exact local parity;
  a CDN is a clean future phase, not now.
- **Image resizing / thumbnails, lifecycle expiry, object versioning, server-side
  encryption with KMS** — YAGNI for the learning stack (S3 default SSE-S3 applies).
- **Avatar seed images** — only product images have seed bytes locally; avatars
  work via the live upload flow, same as local.
- **Phase 4d (Redis TLS+AUTH)** — unrelated, separate phase.

## Operating constraints

All steps bill AWS (account `583178372344` / profile `microecom` / region
`ap-southeast-1`) — the user runs the image rebuilds and `make aws-all`; Claude
writes the non-Terraform edits and runs only the offline gates. The user writes
`s3.tf`. Never log secrets (signed S3 URLs included). Never commit tfvars / state /
`.terraform` (`.terraform.lock.hcl` **is** committed). Commit messages end with the
`Co-Authored-By: Claude Opus 4.8` trailer. The cluster bills ~$0.25-0.30/hr —
`make aws-down` between sessions.
