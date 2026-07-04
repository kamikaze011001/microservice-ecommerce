# AWS S3 Product Images + IRSA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision a real Amazon S3 bucket + IRSA so `core-s3` stops pointing at the undeployed in-cluster MinIO — product images and avatars upload (presign→PUT) and serve (anonymous GET) on AWS, the seeded catalog renders with real images, and `up-all.sh` step 9 stops being a deferred stub.

**Architecture:** A public-read S3 bucket (`microecom-media-<acct>`) with two anonymous-read prefixes (`products/*`, `avatars/*`) and a CORS rule for browser PUTs. The two JVM services that touch S3 (product-service, authorization-server) get AWS creds via **IRSA** — a dedicated SA per service annotated with one shared IAM role ARN; no static keys. The Java seam is a **blank-key sentinel**: when `s3.access-key` is empty, `S3Config` falls back to `DefaultCredentialsProvider` (resolves the IRSA web-identity token); a non-blank key keeps `StaticCredentialsProvider` so local MinIO is untouched. Three seed scripts rewrite the seeded `localhost:9000/ecommerce-media/...` image URLs to the S3 virtual-hosted host, and a new `seed-images.sh` uploads the sample JPGs.

**Tech Stack:** Terraform (`terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks ~> 5.0`, native `aws_s3_bucket*` + `aws_iam_policy`), AWS SDK for Java v2 (`software.amazon.awssdk.auth.credentials`), Kustomize overlays, bash + `jq` + `aws s3 cp` seed scripts, Spring Cloud + External Secrets Operator.

**Coworking-learning mode:** `aws/main/s3.tf` is a `[CHECKPOINT — HUMAN ✍️]` — Claude scaffolds the PART A–E skeleton (comment guidance + `TODO(HUMAN)` markers, **NO resource bodies**), the USER writes the Terraform himself for interview prep, then Claude reviews. Everything else Claude owns.

**Verification model (no AWS spend):** This is infra + scripts, not unit-testable code. The TDD analog is **offline gates** — `terraform fmt -check`, `mvn -pl core/core-s3 compile`, `bash -n`, `kubectl kustomize <dir>`, `grep`. The billed cores/service image rebuilds and `make aws-all` are the USER's, run later out of band. Branch: `feat/aws-deploy`.

---

## File Structure

| File | Disposition | Responsibility |
|------|-------------|----------------|
| `core/core-s3/.../S3Config.java` | Modify (Claude) | Blank-key → `DefaultCredentialsProvider` fallback (the IRSA seam) |
| `aws/main/s3.tf` | Create (**HUMAN**) | Bucket, public-read policy, CORS, IAM policy, IRSA role, outputs |
| `aws/main/data.tf` | Modify (**HUMAN**, inside Task 2) | Add `data.aws_caller_identity.current` for the account-id suffix |
| `k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml` | Create (Claude) | Both IRSA SAs (`apps:product-service`, `apps:authorization-server`), stamped imperatively |
| `k8s/apps/overlays/aws/product-service/patch-sa.yaml` | Create (Claude) | `serviceAccountName: product-service` on the Deployment |
| `k8s/apps/overlays/aws/authorization-server/patch-sa.yaml` | Create (Claude) | `serviceAccountName: authorization-server` on the Deployment |
| `k8s/apps/overlays/aws/product-service/kustomization.yaml` | Modify (Claude) | Register `patch-sa.yaml` |
| `k8s/apps/overlays/aws/authorization-server/kustomization.yaml` | Modify (Claude) | Register `patch-sa.yaml` |
| `scripts/aws/seed-secrets.sh` | Modify (Claude) | Flip `core-s3` secret block to real S3 (blank creds, path-style false) |
| `scripts/aws/seed-mongo.sh` | Modify (Claude) | Rewrite catalog `imageUrl` host to S3 before the Mongo seed |
| `scripts/aws/seed-inventory.sh` | Modify (Claude) | Retarget the `inventory_product.image_url` rewrite to S3 |
| `scripts/aws/seed-images.sh` | Create (Claude) | Upload sample JPGs to `s3://<bucket>/products/...` |
| `scripts/aws/up-all.sh` | Modify (Claude) | Stamp S3 role ARN onto SAs before apps apply; swap step-9 stub for `seed-images.sh` |
| `scripts/aws/RUNBOOK.md` | Modify (Claude) | Replace the step-9 "DEFERRED" section |

**Why the SAs are applied imperatively (not via kustomize):** the IRSA mutating webhook injects the web-identity token when a pod is *admitted*, based on the SA's `role-arn` annotation. The annotated SA must therefore exist **before** the app pods are created. Applying the SA in the same `kubectl apply -k` batch as the Deployment races that ordering. So — exactly like `infra-up.sh` does for the ESO SA — `up-all.sh` `sed`-stamps the real ARN and applies the SA manifest *before* `kubectl apply -k`. The `serviceAccountName` Deployment patch lives in kustomize (declarative); the SA object itself does not.

---

## Task 1: Java IRSA seam — blank-key credential fallback

**Files:**
- Modify: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java:54-57`

**Context for the implementer:** `S3Config` builds both an `S3Client` (server-side: post-upload HEAD check) and an `S3Presigner` (browser-facing). Both call the private `credentials(props)` helper, which today always returns a `StaticCredentialsProvider` from `s3.access-key`/`s3.secret-key`. Local MinIO sets those (`minioadmin`/`minioadmin`); real AWS S3 with IRSA will set them **blank**. The change: when the access key is null/blank, return `DefaultCredentialsProvider.create()` — the AWS SDK default chain, which on EKS resolves the IRSA web-identity token (`AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN`, injected by the pod-identity webhook). A non-blank key keeps the static provider, so MinIO is byte-for-byte unchanged. `S3Properties` is Lombok `@Data`, so `getAccessKey()` already exists.

- [ ] **Step 1: Add the `DefaultCredentialsProvider` import**

In the import block (after line 8, `StaticCredentialsProvider`), add:

```java
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
```

- [ ] **Step 2: Replace the `credentials` helper**

Replace lines 54-57:

```java
    private static AwsCredentialsProvider credentials(S3Properties props) {
        return StaticCredentialsProvider.create(
            AwsBasicCredentials.create(props.getAccessKey(), props.getSecretKey()));
    }
```

with:

```java
    private static AwsCredentialsProvider credentials(S3Properties props) {
        // Blank access-key is the AWS sentinel: fall back to the SDK default
        // credential chain, which on EKS resolves the IRSA web-identity token
        // (the pod's ServiceAccount is annotated with an IAM role ARN). A
        // non-blank key means local MinIO — keep the static provider untouched.
        if (props.getAccessKey() == null || props.getAccessKey().isBlank()) {
            return DefaultCredentialsProvider.create();
        }
        return StaticCredentialsProvider.create(
            AwsBasicCredentials.create(props.getAccessKey(), props.getSecretKey()));
    }
```

- [ ] **Step 3: Compile the module (offline gate)**

Run: `mvn -q -pl core/core-s3 -am compile`
Expected: `BUILD SUCCESS` (the `software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider` symbol resolves against the already-on-classpath AWS SDK auth jar).

- [ ] **Step 4: Commit**

```bash
git add core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java
git commit -m "feat(core-s3): IRSA credential fallback when s3.access-key is blank

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> ⚠️ **Image-rebuild note (for the controller, not a step):** this change is baked into the `cores` image and therefore the `product-service` + `authorization-server` images. The billed rebuild (`SVC=cores` then those two services, FORCE_BUILD) + `make aws-all` are the USER's — do **not** run them here. See [[project_k8s_cores_image_rebuild]].

---

## Task 2: `[CHECKPOINT — HUMAN ✍️]` — `aws/main/s3.tf` (Claude scaffolds, HUMAN writes bodies)

**Files:**
- Create: `aws/main/s3.tf` (Claude writes the comment scaffold; HUMAN writes the resource bodies)
- Modify: `aws/main/data.tf` (HUMAN adds `data "aws_caller_identity" "current" {}`)

**Context for the implementer (Claude's scaffold only — DO NOT write resource bodies):** This file is the storage twin of the existing IRSA work in `aws/main/storage.tf` (EBS CSI) and `aws/main/secrets.tf` (ESO). The user has written that pattern three times and is doing this one himself for interview prep. Claude writes ONLY the PART A–F comment guidance + `# TODO(HUMAN): ...` markers, mirroring the teaching style of `storage.tf` (read it for tone). The IRSA module differs from EBS/ALB in one way: S3 has no `attach_*` convenience flag, so it needs a hand-rolled `aws_iam_policy` wired via `role_policy_arns = { media = aws_iam_policy.s3_media.arn }`.

- [ ] **Step 1 (Claude): Write the scaffold to `aws/main/s3.tf`**

Create `aws/main/s3.tf` with exactly this content (comments + TODO markers, **no `resource`/`module` bodies**):

```hcl
# aws/main/s3.tf  —  [CHECKPOINT — HUMAN ✍️]  (Phase 4c, Task 2)
#
# WHY THIS FILE EXISTS
# core-s3 (product images + user avatars) currently points at the in-cluster
# MinIO, which we never deployed on AWS. This file provisions the real object
# store: a public-read S3 bucket whose `products/*` and `avatars/*` prefixes serve
# anonymously, plus the IRSA plumbing so product-service and authorization-server
# can presign uploads with the pod's temporary STS credentials — no static keys.
#
# This is the IRSA twin of storage.tf (EBS CSI) and secrets.tf (ESO). Open
# storage.tf side-by-side: the IRSA module shape is identical. The ONE difference:
# S3 has no `attach_*` convenience flag (EBS used attach_ebs_csi_policy), so you
# hand-write an aws_iam_policy and pass it via `role_policy_arns`.
#
# ─────────────────────────────────────────────────────────────────────────────
# PREREQ — [HUMAN ✍️] in aws/main/data.tf
#   Add a caller-identity data source so the bucket name can carry the account id
#   (S3 bucket names are GLOBALLY unique; the account id makes ours collision-proof):
#
#     data "aws_caller_identity" "current" {}
#
# ─────────────────────────────────────────────────────────────────────────────
# PART A — [HUMAN ✍️]  the bucket
#   resource "aws_s3_bucket" "media" {
#     bucket        = "${var.project}-media-${data.aws_caller_identity.current.account_id}"
#     force_destroy = true   # demo stack: let `terraform destroy` empty it
#   }
#   (Expect name: microecom-media-583178372344.)
#
# ─────────────────────────────────────────────────────────────────────────────
# PART B — [HUMAN ✍️]  public-read on the two prefixes
#   By default a bucket blocks all public access. We need anonymous GET on the
#   served objects, so:
#   1. aws_s3_bucket_public_access_block "media" — set block_public_policy = false
#      and restrict_public_buckets = false (the other two can stay true).
#   2. aws_s3_bucket_policy "media" — a bucket policy with a single Allow stmt:
#        Principal "*", Action "s3:GetObject",
#        Resource [ "${aws_s3_bucket.media.arn}/products/*",
#                   "${aws_s3_bucket.media.arn}/avatars/*" ]
#      Add `depends_on = [aws_s3_bucket_public_access_block.media]` so the policy
#      is applied AFTER the block is relaxed (else AccessDenied on apply).
#
# ─────────────────────────────────────────────────────────────────────────────
# PART C — [HUMAN ✍️]  CORS (browser PUTs to the presigned URL are cross-origin)
#   Real S3 enforces CORS (MinIO didn't by default). Without this the browser's
#   direct PUT to the presigned upload URL fails preflight, while GETs still work
#   — a half-broken state that's easy to miss.
#   aws_s3_bucket_cors_configuration "media" with one cors_rule:
#     allowed_methods = ["PUT", "GET"]
#     allowed_origins = ["http://microecom.local", "https://microecom.local"]
#     allowed_headers = ["*"]
#     max_age_seconds = 3000
#
# ─────────────────────────────────────────────────────────────────────────────
# PART D — [HUMAN ✍️]  IAM policy + IRSA role
#   1. aws_iam_policy "s3_media" — Allow s3:PutObject + s3:GetObject on
#        "${aws_s3_bucket.media.arn}/products/*" and ".../avatars/*".
#        (PutObject is what the presigned-upload SigV4 covers; GetObject lets the
#        server-side HEAD check read its own writes.)
#   2. module "s3_irsa" — same module/version as storage.tf's ebs_csi_irsa:
#        source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#        version = "~> 5.0"
#        role_name        = "${var.project}-s3-media"
#        role_policy_arns = { media = aws_iam_policy.s3_media.arn }   # <- no attach_* flag fits S3
#        oidc_providers = {
#          main = {
#            provider_arn               = module.eks.oidc_provider_arn
#            namespace_service_accounts = ["apps:product-service", "apps:authorization-server"]
#          }
#        }
#      Both SAs share ONE role (both need the same two-prefix access).
#
# ─────────────────────────────────────────────────────────────────────────────
# PART E — [HUMAN ✍️]  outputs (consumed by the seed scripts + up-all.sh)
#   output "s3_bucket_name"     { value = aws_s3_bucket.media.bucket }
#   output "s3_irsa_role_arn"   { value = module.s3_irsa.iam_role_arn }
#   output "s3_public_base_url" {
#     # virtual-hosted URL — the bucket moves INTO the host, so the seeded
#     # `.../ecommerce-media/...` path segment is DROPPED by the rewrites.
#     value = "https://${aws_s3_bucket.media.bucket}.s3.${var.region}.amazonaws.com"
#   }
#
# ─────────────────────────────────────────────────────────────────────────────
# 🎓 Interview prep — be ready to explain:
#   - IRSA vs static keys: the pod assumes a role via an OIDC web-identity token
#     (projected SA token) → STS → short-lived creds. No long-lived secret to leak.
#   - Why the presign still works with temp creds: the presigned PUT URL embeds the
#     STS session token (X-Amz-Security-Token) and is valid for the 5-min TTL.
#   - Why serving needs no creds: the prefix is anonymous-read via the bucket policy.
#   - Why CORS is needed on S3 but not MinIO; why the path segment drops in the
#     virtual-hosted URL (path-style=false).
#
# Write the data source (data.tf) + PARTS A–E below, then tell Claude "review".

# TODO(HUMAN): PART A — aws_s3_bucket "media"
# TODO(HUMAN): PART B — aws_s3_bucket_public_access_block + aws_s3_bucket_policy "media"
# TODO(HUMAN): PART C — aws_s3_bucket_cors_configuration "media"
# TODO(HUMAN): PART D — aws_iam_policy "s3_media" + module "s3_irsa"
# TODO(HUMAN): PART E — outputs s3_bucket_name / s3_irsa_role_arn / s3_public_base_url
```

- [ ] **Step 2 (Claude): Verify the scaffold parses as a comment-only file**

Run: `terraform fmt -check aws/main/s3.tf` (a comment-only `.tf` is valid HCL)
Expected: exit 0 (no diff). If it reformats, run `terraform fmt aws/main/s3.tf` and re-check.

- [ ] **Step 3: `[CHECKPOINT — HUMAN ✍️]` — the user writes PARTS A–E + the data source**

Hand off with the coworking header (`## What I did` / `## What YOU need to write`). The user adds `data "aws_caller_identity" "current" {}` to `aws/main/data.tf` and fills PARTS A–E in `aws/main/s3.tf`. **Claude does NOT write these.** Wait for the user to say "review".

- [ ] **Step 4 (Claude): Review the user's Terraform — offline gate**

When the user reports done, run:
- `terraform fmt -check aws/main/s3.tf aws/main/data.tf` — expected exit 0.
- `grep -nE 'aws_s3_bucket\b|aws_s3_bucket_public_access_block|aws_s3_bucket_policy|aws_s3_bucket_cors_configuration|aws_iam_policy|module "s3_irsa"|aws_caller_identity' aws/main/s3.tf aws/main/data.tf` — expected: all seven resources/module present.
- `grep -nE 'output "s3_bucket_name"|output "s3_irsa_role_arn"|output "s3_public_base_url"' aws/main/s3.tf` — expected: all three outputs (the seed scripts depend on these exact names).

Read the file and review for: bucket policy `depends_on` the public-access-block; CORS `allowed_methods` includes PUT; IRSA `namespace_service_accounts` lists both `apps:product-service` and `apps:authorization-server`; `provider_arn = module.eks.oidc_provider_arn`. Do **NOT** run `terraform validate`/`plan`/`apply` (billed/online). Report findings; if anything is off, hand back to the user (don't fix it yourself).

- [ ] **Step 5: Commit (after the user's bodies pass review)**

```bash
git add aws/main/s3.tf aws/main/data.tf
git commit -m "feat(aws): S3 media bucket + public-read prefixes + IRSA role

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: ServiceAccount wiring for the two S3 services

**Files:**
- Create: `k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml`
- Create: `k8s/apps/overlays/aws/product-service/patch-sa.yaml`
- Create: `k8s/apps/overlays/aws/authorization-server/patch-sa.yaml`
- Modify: `k8s/apps/overlays/aws/product-service/kustomization.yaml`
- Modify: `k8s/apps/overlays/aws/authorization-server/kustomization.yaml`

**Context for the implementer:** product-service and authorization-server need a dedicated, IRSA-annotated ServiceAccount (the default `apps:default` SA has no role). The SA object is applied **imperatively** by `up-all.sh` (Task 8) with the real ARN `sed`-stamped in — mirroring `k8s/infra/manifests/external-secrets-sa.yaml`, which uses `PLACEHOLDER_ESO_ROLE_ARN`. So the SA manifest here carries `PLACEHOLDER_S3_ROLE_ARN` and is **NOT** referenced in any kustomization (kustomize only includes files listed under `resources:`, so an unreferenced file is ignored). The Deployment's `serviceAccountName` is set declaratively via a kustomize patch (mirrors the existing `patch-volume.yaml` strategic-merge style).

- [ ] **Step 1: Create the shared SA manifest**

Create `k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml`:

```yaml
# Two ServiceAccounts that are IRSA targets for the S3 media bucket. Applied
# IMPERATIVELY by scripts/aws/up-all.sh (which sed-stamps the real role ARN from
# `terraform output s3_irsa_role_arn`) BEFORE `kubectl apply -k` the apps overlay
# — the IRSA mutating webhook injects the web-identity token when a pod is
# admitted based on its SA annotation, so the annotated SA must exist first.
# Annotating after the pods are running would need a restart. Mirrors
# k8s/infra/manifests/external-secrets-sa.yaml (the ESO SA, same pattern).
#
# These are deliberately NOT in any kustomization.yaml: the apps overlay must not
# create them with the literal PLACEHOLDER. The Deployments reference them by name
# via each service's patch-sa.yaml. Name/namespace MUST match the
# namespace_service_accounts entries in aws/main/s3.tf.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: product-service
  namespace: apps
  annotations:
    eks.amazonaws.com/role-arn: PLACEHOLDER_S3_ROLE_ARN
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: authorization-server
  namespace: apps
  annotations:
    eks.amazonaws.com/role-arn: PLACEHOLDER_S3_ROLE_ARN
```

- [ ] **Step 2: Create the product-service serviceAccountName patch**

Create `k8s/apps/overlays/aws/product-service/patch-sa.yaml`:

```yaml
# Point the product-service pods at the IRSA ServiceAccount (created imperatively
# by up-all.sh from s3-irsa-serviceaccounts.yaml). The SA's role-arn annotation is
# what the IRSA webhook reads to inject the web-identity token for S3 presign.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: product-service
  namespace: apps
spec:
  template:
    spec:
      serviceAccountName: product-service
```

- [ ] **Step 3: Create the authorization-server serviceAccountName patch**

Create `k8s/apps/overlays/aws/authorization-server/patch-sa.yaml`:

```yaml
# Point the authorization-server pods at the IRSA ServiceAccount (created
# imperatively by up-all.sh). Needed for the user-avatar presign flow.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authorization-server
  namespace: apps
spec:
  template:
    spec:
      serviceAccountName: authorization-server
```

- [ ] **Step 4: Register the patch in product-service kustomization**

In `k8s/apps/overlays/aws/product-service/kustomization.yaml`, change the `patches:` block from:

```yaml
patches:
  - path: patch-volume.yaml
```

to:

```yaml
patches:
  - path: patch-volume.yaml
  - path: patch-sa.yaml
```

- [ ] **Step 5: Register the patch in authorization-server kustomization**

In `k8s/apps/overlays/aws/authorization-server/kustomization.yaml`, apply the identical change (`patch-volume.yaml` → add `- path: patch-sa.yaml`).

- [ ] **Step 6: Offline gate — render both overlays and assert serviceAccountName**

Run:
```bash
kubectl kustomize k8s/apps/overlays/aws/product-service | grep -n 'serviceAccountName: product-service'
kubectl kustomize k8s/apps/overlays/aws/authorization-server | grep -n 'serviceAccountName: authorization-server'
```
Expected: each prints one matching line (the patch merged into the Deployment). The SA objects themselves do NOT appear in the render — that is correct (they are applied imperatively, not via kustomize).

- [ ] **Step 7: Commit**

```bash
git add k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml \
        k8s/apps/overlays/aws/product-service/patch-sa.yaml \
        k8s/apps/overlays/aws/product-service/kustomization.yaml \
        k8s/apps/overlays/aws/authorization-server/patch-sa.yaml \
        k8s/apps/overlays/aws/authorization-server/kustomization.yaml
git commit -m "feat(aws): IRSA ServiceAccounts for product-service + authorization-server S3 access

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Flip the `core-s3` secret block to real S3

**Files:**
- Modify: `scripts/aws/seed-secrets.sh:42-45` (add two tf_out reads), `:61-69` (the `put core-s3` block)

**Context for the implementer:** `seed-secrets.sh` pushes each service's config into AWS Secrets Manager as JSON keyed by dotted Spring property names; ESO materializes it into a k8s Secret the pod reads via configtree. The `core-s3` block currently seeds the **MinIO** values (`minioadmin` creds, `path-style=true`, the `media.microecom.local` ingress host). For AWS it must become: blank endpoint/public-endpoint (SDK default = real S3), blank creds (the **blank-key sentinel** that triggers Task 1's `DefaultCredentialsProvider`), `path-style=false`, real region, and the bucket + public-base-url read from the terraform outputs (Task 2 PART E). The file already has a `tf_out` helper (lines 38-41) and reads RDS/Redis outputs the same way (lines 42-45) — mirror that exactly. `presign-ttl`/`max-upload-size`/`allowed-types` are unchanged.

- [ ] **Step 1: Add the two S3 output reads**

After line 45 (`DB_PASS="$(tf_out db_master_password)"`), add:

```bash
S3_BUCKET="$(tf_out s3_bucket_name)"
S3_BASE_URL="$(tf_out s3_public_base_url)"
```

- [ ] **Step 2: Replace the `put core-s3` block**

Replace lines 61-69:

```bash
put core-s3 "$(jq -n '{
  "s3.endpoint":"http://minio.infra.'"$DNS"':9000",
  "s3.public-endpoint":"http://media.microecom.local",
  "s3.region":"us-east-1","s3.bucket":"ecommerce-media",
  "s3.access-key":"minioadmin","s3.secret-key":"minioadmin","s3.path-style":"true",
  "s3.public-base-url":"http://media.microecom.local/ecommerce-media",
  "s3.presign-ttl":"PT5M","s3.max-upload-size":"5242880",
  "s3.allowed-types":"image/jpeg,image/png,image/webp"
}')"
```

with:

```bash
# Phase 4c — real AWS S3. Blank endpoint/public-endpoint ⇒ AWS SDK default
# (the public S3 host, signed correctly for the browser presign). Blank
# access-key is the sentinel that flips S3Config to DefaultCredentialsProvider
# (IRSA web-identity) instead of static keys — see core-s3 S3Config.java. The
# bucket + public-base-url come from terraform so they can't drift.
put core-s3 "$(jq -n --arg bucket "$S3_BUCKET" --arg base "$S3_BASE_URL" '{
  "s3.endpoint":"",
  "s3.public-endpoint":"",
  "s3.region":"ap-southeast-1","s3.bucket":$bucket,
  "s3.access-key":"","s3.secret-key":"","s3.path-style":"false",
  "s3.public-base-url":$base,
  "s3.presign-ttl":"PT5M","s3.max-upload-size":"5242880",
  "s3.allowed-types":"image/jpeg,image/png,image/webp"
}')"
```

- [ ] **Step 3: Offline gates**

Run:
```bash
bash -n scripts/aws/seed-secrets.sh
grep -nE 's3.access-key":""|s3.path-style":"false"|S3_BUCKET=|S3_BASE_URL=' scripts/aws/seed-secrets.sh
```
Expected: `bash -n` exits 0; grep shows the blank access-key, `path-style=false`, and both new variable reads.

- [ ] **Step 4: Commit**

```bash
git add scripts/aws/seed-secrets.sh
git commit -m "feat(aws): seed core-s3 secret for real S3 (blank creds → IRSA, path-style false)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Rewrite the Mongo catalog `imageUrl` host to S3

**Files:**
- Modify: `scripts/aws/seed-mongo.sh` (add tf_out read + jq rewrite + temp file; retarget the configMap)

**Context for the implementer:** `seed-mongo.sh` loads `docker/product.json` **verbatim** into the Mongo `product` collection — the collection the storefront browse/detail pages read `imageUrl` from. `docker/product.json` ships the local MinIO URL `http://localhost:9000/ecommerce-media/products/...`. On AWS that host is unreachable from a browser, so every catalog `<img>` 404s. Fix: read `s3_public_base_url` from terraform, `jq`-rewrite the host into a temp file (dropping the `ecommerce-media/` path segment — it moves into the virtual-hosted bucket host), and feed the temp file to the existing imperative configMap with the key forced to `product.json` (the Job's `seed.sh` reads that exact filename). The other two data files (`api_role.json`, `product-quantity-history.json`) are unchanged. This is the Mongo twin of Task 6's inventory rewrite — both must point at the same S3 URL.

- [ ] **Step 1: Add the terraform read + a jq guard near the top**

After line 25 (`JOB_DIR="$ROOT/k8s/infra/jobs/02-mongo-seed"`), add:

```bash
TF="$ROOT/aws/main"

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
S3_BASE_URL="$(terraform -chdir="$TF" output -raw s3_public_base_url 2>/dev/null)" \
  || { echo "ERROR: terraform output 's3_public_base_url' missing — run 'terraform apply' (Phase 4c) first" >&2; exit 1; }
```

- [ ] **Step 2: Build the host-rewritten product.json before the configMap**

Immediately before the `echo "▶ (re)creating mongo-seed configmaps ..."` line (line 31), add:

```bash
# The seeded imageUrl points at local MinIO (http://localhost:9000/ecommerce-media/
# products/...). On AWS the storefront reads imageUrl straight from this Mongo
# `product` collection, so rewrite the host to the S3 virtual-hosted URL — the
# bucket moves into the host, so the `ecommerce-media/` path segment is dropped.
PRODUCT_JSON_AWS="$(mktemp "${TMPDIR:-/tmp}/product-aws.XXXXXX")"
trap 'rm -f "$PRODUCT_JSON_AWS"' EXIT
jq --arg base "$S3_BASE_URL" '
  map(if (.imageUrl // "" | length) > 0
      then .imageUrl |= gsub("http://localhost:9000/ecommerce-media/"; $base + "/")
      else . end)
' "$ROOT/docker/product.json" > "$PRODUCT_JSON_AWS"
```

- [ ] **Step 3: Point the configMap at the rewritten file**

In the `mongo-seed-data` configMap (lines 34-38), change the product line from
`--from-file="$ROOT/docker/product.json"` to `--from-file=product.json="$PRODUCT_JSON_AWS"`. The block becomes:

```bash
kubectl -n bootstrap create configmap mongo-seed-data \
  --from-file="$ROOT/docker/api_role.json" \
  --from-file=product.json="$PRODUCT_JSON_AWS" \
  --from-file="$ROOT/docker/product-quantity-history.json" \
  --dry-run=client -o yaml | kubectl apply -f -
```

(The `key=path` form keeps the configMap key as `product.json` — what the Job's `seed.sh` mongoimports — even though the source file has a random temp name.)

- [ ] **Step 4: Offline gates**

Run:
```bash
bash -n scripts/aws/seed-mongo.sh
grep -nE 'product.json="\$PRODUCT_JSON_AWS"|s3_public_base_url|ecommerce-media/' scripts/aws/seed-mongo.sh
```
Expected: `bash -n` exits 0; grep shows the keyed `--from-file`, the terraform read, and the gsub source containing `ecommerce-media/`.

- [ ] **Step 5: Commit**

```bash
git add scripts/aws/seed-mongo.sh
git commit -m "feat(aws): rewrite Mongo catalog imageUrl host to S3 before seeding

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Retarget the inventory `image_url` rewrite to S3

**Files:**
- Modify: `scripts/aws/seed-inventory.sh:35-36` (add tf_out read), `:68-79` (the comment + the rewrite)

**Context for the implementer:** `seed-inventory.sh` builds `INSERT IGNORE` rows for `inventory_product` from `docker/product.json`. order-service snapshots `inventory_product.image_url` into `order_item` at order-create, so a stale host there ends up in saved orders and 404s. The current jq rewrites only the host (`http://localhost:9000/` → `http://media.microecom.local/`), **leaving** the `ecommerce-media/` path segment — correct for the path-style MinIO ingress, wrong for S3 virtual-hosted (bucket in host, no path segment). Retarget it to the same `s3_public_base_url` the Mongo seed uses, dropping `ecommerce-media/`. The file already reads other outputs via `terraform -chdir="$TF" output -raw` (lines 35-36) — mirror that bare style.

- [ ] **Step 1: Read the S3 base URL alongside the other outputs**

After line 36 (`DB_PASS="$(terraform -chdir="$TF" output -raw db_master_password)"`), add:

```bash
S3_BASE_URL="$(terraform -chdir="$TF" output -raw s3_public_base_url)"
```

- [ ] **Step 2: Update the stale comment (lines 68-71)**

Replace:

```bash
# Build INSERT IGNORE statements. Same jq as scripts/seed/k8s-inventory.sh; the
# image_url host rewrite mirrors seed-mongo.sh's catalog rewrite so order_item
# snapshots match the catalog. (S3 isn't wired until Phase 4c, so the host is a
# placeholder either way — kept consistent with Mongo.)
```

with:

```bash
# Build INSERT IGNORE statements. Same jq as scripts/seed/k8s-inventory.sh; the
# image_url host rewrite mirrors seed-mongo.sh's catalog rewrite so order_item
# snapshots match the catalog — both point at the S3 virtual-hosted URL (the
# bucket lives in the host, so the ecommerce-media/ path segment is dropped).
```

- [ ] **Step 3: Retarget the jq rewrite**

The `SQL_PRODUCTS` jq currently takes no `--arg`. Change its invocation and the `gsub`. Replace lines 72-79:

```bash
SQL_PRODUCTS="$(jq -r '
  .[] |
  "INSERT IGNORE INTO inventory_product (id, name, price, image_url) VALUES ("
  + "\"" + ._id."$oid" + "\", "
  + "\"" + (.name | gsub("\""; "\\\"")) + "\", "
  + (.price | tostring) + ", "
  + (if (.imageUrl // "" | length) > 0 then "\"" + (.imageUrl | gsub("\""; "\\\"") | gsub("http://localhost:9000/"; "http://media.microecom.local/")) + "\"" else "NULL" end)
  + ");"' "$PRODUCTS_JSON")"
```

with:

```bash
SQL_PRODUCTS="$(jq -r --arg base "$S3_BASE_URL" '
  .[] |
  "INSERT IGNORE INTO inventory_product (id, name, price, image_url) VALUES ("
  + "\"" + ._id."$oid" + "\", "
  + "\"" + (.name | gsub("\""; "\\\"")) + "\", "
  + (.price | tostring) + ", "
  + (if (.imageUrl // "" | length) > 0 then "\"" + (.imageUrl | gsub("\""; "\\\"") | gsub("http://localhost:9000/ecommerce-media/"; $base + "/")) + "\"" else "NULL" end)
  + ");"' "$PRODUCTS_JSON")"
```

- [ ] **Step 4: Offline gates**

Run:
```bash
bash -n scripts/aws/seed-inventory.sh
grep -nE 'S3_BASE_URL=|--arg base|ecommerce-media/"; \$base' scripts/aws/seed-inventory.sh
```
Expected: `bash -n` exits 0; grep shows the new read, the `--arg base`, and the retargeted gsub.

- [ ] **Step 5: Commit**

```bash
git add scripts/aws/seed-inventory.sh
git commit -m "feat(aws): retarget inventory image_url rewrite to S3 virtual-hosted URL

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: New `seed-images.sh` — upload sample JPGs to S3

**Files:**
- Create: `scripts/aws/seed-images.sh` (executable)

**Context for the implementer:** the sample product images live at `docker/seed-images/<category>/<slug>.jpg` (30 JPGs across apparel/footwear/accessories). The local-dev twin `scripts/seed/k8s-product-images.sh` streams them into the in-cluster MinIO via `mc cp`. On AWS the bucket is a public AWS API, so we `aws s3 cp` straight from the host — no pod. The object key MUST be `products/<productId>/<slug>.jpg` (the key the stored `imageUrl` points at). The slug→productId→category mapping is in `scripts/seed/products-manifest.json` under `.products[]`. The bucket name comes from the terraform `s3_bucket_name` output. Idempotent (`aws s3 cp` overwrites); warn-and-continue on a missing file; tally uploaded/missing. Use `jq -r '... | @tsv'` to emit the mapping (jq is already a dependency of the other seed scripts).

- [ ] **Step 1: Create the script**

Create `scripts/aws/seed-images.sh`:

```bash
#!/usr/bin/env bash
# Upload the sample product images (docker/seed-images/<category>/<slug>.jpg) to
# the AWS S3 media bucket at products/<productId>/<slug>.jpg — the object key the
# stored imageUrl points at. AWS twin of scripts/seed/k8s-product-images.sh, which
# streams into the in-cluster MinIO via `mc cp`; here the bucket is a public AWS
# API so we `aws s3 cp` straight from the host — no pod.
#
# slug → productId → category mapping comes from scripts/seed/products-manifest.json.
# The bucket name comes from the terraform `s3_bucket_name` output so it can never
# drift from what was provisioned. Idempotent: `aws s3 cp` overwrites; safe to
# re-run. Run AFTER `terraform apply` (Phase 4c) created the bucket.
#
# Usage:  AWS_PROFILE=microecom scripts/aws/seed-images.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT/aws/main"
MANIFEST="$ROOT/scripts/seed/products-manifest.json"
SEED_DIR="$ROOT/docker/seed-images"

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "Missing $MANIFEST" >&2; exit 1; }

BUCKET="$(terraform -chdir="$TF" output -raw s3_bucket_name 2>/dev/null)" \
  || { echo "ERROR: terraform output 's3_bucket_name' missing — run 'terraform apply' (Phase 4c) first" >&2; exit 1; }

echo "▶ uploading product images to s3://${BUCKET}/products/ ..."
uploaded=0
missing=0
# Emit "category<TAB>slug<TAB>productId" per product from the manifest.
while IFS=$'\t' read -r category slug productId; do
  src="$SEED_DIR/$category/$slug.jpg"
  if [ ! -f "$src" ]; then
    echo "  WARN missing $src"; missing=$((missing + 1)); continue
  fi
  aws s3 cp "$src" "s3://${BUCKET}/products/${productId}/${slug}.jpg" \
    --content-type image/jpeg >/dev/null
  uploaded=$((uploaded + 1))
done < <(jq -r '.products[] | [.category, .slug, .productId] | @tsv' "$MANIFEST")

echo "✅ product images seeded (uploaded=${uploaded} missing=${missing})."
```

- [ ] **Step 2: Make it executable + offline gates**

Run:
```bash
chmod +x scripts/aws/seed-images.sh
bash -n scripts/aws/seed-images.sh
jq -r '.products[] | [.category, .slug, .productId] | @tsv' scripts/seed/products-manifest.json | wc -l
```
Expected: `bash -n` exits 0; the jq line prints `30` (the manifest yields 30 product rows, matching the 30 JPGs on disk).

- [ ] **Step 3: Commit**

```bash
git add scripts/aws/seed-images.sh
git commit -m "feat(aws): seed-images.sh — upload sample product JPGs to S3

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Wire `up-all.sh` (ARN stamp + step-9 swap) and update RUNBOOK

**Files:**
- Modify: `scripts/aws/up-all.sh` (header comment line 26; insert ARN stamp before line 121; replace step-9 stub lines 150-153)
- Modify: `scripts/aws/RUNBOOK.md:84-86` (replace the step-9 DEFERRED section)

**Context for the implementer:** `up-all.sh` chains the ordered bring-up. Two changes: (1) before the apps `kubectl apply -k` (line 121), stamp the real S3 IRSA role ARN onto the two SA manifests and apply them — mirroring `infra-up.sh`'s ESO stamp — so the annotated SAs exist before app pods are admitted; (2) replace the deferred step-9 echo with a real call to the new `seed-images.sh`. Also fix the ORDER comment (line 26) and the RUNBOOK step-9 section. The context guard (lines 115-120) already ensures the kubectl context is `microecom-eks` before any apply, so the stamp inherits that safety by sitting after it.

- [ ] **Step 1: Update the ORDER comment (line 26)**

Replace line 26:

```bash
#   9 [Phase 4c]   S3 product images — skipped (no bucket until 4c)
```

with:

```bash
#   9 seed-images  upload sample product JPGs to the S3 media bucket (Phase 4c)
```

- [ ] **Step 2: Insert the ARN stamp before the apps apply**

Between the context-guard block (ending line 120, `fi`) and `kubectl apply -k "$ROOT/k8s/apps/overlays/aws"` (line 121), insert:

```bash
# Stamp the S3 IRSA role ARN onto the product-service + authorization-server
# ServiceAccounts and apply them BEFORE the apps overlay (mirror infra-up.sh's ESO
# stamp). The IRSA webhook injects the web-identity token when a pod is admitted
# based on its SA annotation, so the annotated SA must exist before app pods are
# created — annotating after would need a restart. The context guard above already
# pinned us to microecom-eks.
S3_ROLE_ARN="$(terraform -chdir="$TF" output -raw s3_irsa_role_arn)" \
  || { echo "ERROR: 'terraform output s3_irsa_role_arn' failed — run step 1 (terraform apply) first" >&2; exit 1; }
sed "s|PLACEHOLDER_S3_ROLE_ARN|${S3_ROLE_ARN}|g" \
  "$ROOT/k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml" | kubectl apply -f -

```

- [ ] **Step 3: Replace the step-9 stub**

Replace lines 150-153:

```bash
# ── Step 9 — S3 product images (Phase 4c) ─────────────────────────────────────
banner "Step 9/9 · S3 product images — DEFERRED"
echo "▶ skipped: no object store on AWS until Phase 4c (S3 + IRSA). The catalog"
echo "  renders with broken <img> links; browse/cart/checkout work without images."
```

with:

```bash
# ── Step 9 — S3 product images (Phase 4c) ─────────────────────────────────────
banner "Step 9/9 · seed S3 product images"
"$ROOT/scripts/aws/seed-images.sh"
```

- [ ] **Step 4: Update the RUNBOOK step-9 section**

In `scripts/aws/RUNBOOK.md`, replace lines 84-86:

```markdown
### 9. S3 product images — DEFERRED to Phase 4c
No object store on AWS yet (no bucket/IRSA; `core-s3` still points at an
undeployed MinIO). Catalog images 404 until 4c; browse/cart/checkout work.
```

with:

```markdown
### 9. S3 product images — `scripts/aws/seed-images.sh`
Uploads the 30 sample JPGs (`docker/seed-images/<category>/<slug>.jpg`) to
`s3://<bucket>/products/<productId>/<slug>.jpg` — the key the seeded `imageUrl`
points at. The bucket name comes from the `s3_bucket_name` terraform output;
`core-s3` reaches S3 via IRSA (blank `s3.access-key` → SDK default chain). The
bucket has `force_destroy = true`, so it is emptied + destroyed by `aws-down`
(re-run this step after a fresh `aws-up`). Idempotent (`aws s3 cp` overwrites).
**Verify:** `aws s3 ls s3://<bucket>/products/ --recursive --profile microecom`
lists the objects; the storefront catalog renders real images.
```

- [ ] **Step 5: Offline gates**

Run:
```bash
bash -n scripts/aws/up-all.sh
grep -nE 'PLACEHOLDER_S3_ROLE_ARN|seed-images.sh|s3_irsa_role_arn' scripts/aws/up-all.sh
```
Expected: `bash -n` exits 0; grep shows the sed-stamp of `PLACEHOLDER_S3_ROLE_ARN`, the `seed-images.sh` call, and the `s3_irsa_role_arn` output read.

- [ ] **Step 6: Commit**

```bash
git add scripts/aws/up-all.sh scripts/aws/RUNBOOK.md
git commit -m "feat(aws): up-all.sh stamps S3 IRSA SAs + runs seed-images (step 9 no longer deferred)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

These are the cumulative offline gates — re-run them once at the end to confirm nothing regressed (none bill AWS):

```bash
mvn -q -pl core/core-s3 -am compile
terraform fmt -check aws/main/s3.tf aws/main/data.tf
kubectl kustomize k8s/apps/overlays/aws/product-service      | grep 'serviceAccountName: product-service'
kubectl kustomize k8s/apps/overlays/aws/authorization-server | grep 'serviceAccountName: authorization-server'
for f in seed-secrets seed-mongo seed-inventory seed-images up-all; do bash -n "scripts/aws/$f.sh"; done
```

**Billed work that remains the USER's (NOT part of this plan's execution):**
1. Rebuild the `cores` image (Task 1 baked in), then the `product-service` + `authorization-server` images — `SVC=cores` build, then `FORCE_BUILD`/`PUSH=all` for the two services. See [[project_k8s_cores_image_rebuild]].
2. `terraform apply` (creates the bucket/IRSA — happens inside `make aws-all` / `up.sh`).
3. `make aws-all` (or a full `up-all.sh`) end-to-end, then verify: presign→PUT upload works, the catalog renders real images, and `aws s3 ls s3://<bucket>/products/` lists the objects.
```
```

---

## Notes for the executor

- **Task ordering & the HUMAN gate:** Tasks 1 and 3–8 are Claude-owned and reference the terraform output *names* fixed by Task 2's scaffold (`s3_bucket_name`, `s3_irsa_role_arn`, `s3_public_base_url`) — so they can be implemented before the user finishes writing the Task 2 bodies. But Task 2's **commit** (Step 5) must wait for the user's bodies to pass review. A clean sequence: do Task 1, scaffold Task 2 (Steps 1-2) and hand off the HUMAN checkpoint, then proceed through Tasks 3–8 while the user writes the Terraform, and circle back to Task 2 Steps 4-5 (review + commit) when they say "review".
- **Coworking handoff (Task 2 Step 3):** lead with the `## What I did` / `## What YOU need to write` header before any context — the user is Java-backend-only doing the Terraform for interview prep; the AI/HUMAN boundary must be at the top.
- **Never run** `terraform apply/destroy/validate/plan/init`, `aws` (except the user), `kubectl` against the live cluster, `helm`, or `make aws-*` — all bill account `583178372344`. Allowed offline: `bash -n`, `grep`, `jq`/`sed` on local files, `terraform fmt`, `mvn compile`, `kubectl kustomize <dir>`, `chmod`, `git`.
