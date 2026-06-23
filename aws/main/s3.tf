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
resource "aws_s3_bucket" "media" {
  bucket        = "${var.project}-media-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}
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
resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_policy     = false
  restrict_public_buckets = false
  ignore_public_acls      = true
  block_public_acls       = true
}

resource "aws_s3_bucket_policy" "media" {
  bucket     = aws_s3_bucket.media.id
  policy     = data.aws_iam_policy_document.media.json
  depends_on = [aws_s3_bucket_public_access_block.media]
}

data "aws_iam_policy_document" "media" {
  statement {
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.media.arn}/products/*", "${aws_s3_bucket.media.arn}/avatars/*"]
  }
}
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
resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  cors_rule {
    allowed_methods = ["PUT", "GET"]
    allowed_origins = ["http://microecom.local", "https://microecom.local"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}
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
resource "aws_iam_policy" "s3_media" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject"]
      Resource = ["${aws_s3_bucket.media.arn}/products/*", "${aws_s3_bucket.media.arn}/avatars/*"]
    }]
  })
}
module "s3_irsa" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "~> 5.0"
  role_name = "${var.project}-s3-media"
  role_policy_arns = {
    media = aws_iam_policy.s3_media.arn
  }
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["apps:product-service", "apps:authorization-server"]
    }
  }
}
# ─────────────────────────────────────────────────────────────────────────────
# PART E — [HUMAN ✍️]  outputs (consumed by the seed scripts + up-all.sh)
#   output "s3_bucket_name"     { value = aws_s3_bucket.media.bucket }
#   output "s3_irsa_role_arn"   { value = module.s3_irsa.iam_role_arn }
#   output "s3_public_base_url" {
#     # virtual-hosted URL — the bucket moves INTO the host, so the seeded
#     # `.../ecommerce-media/...` path segment is DROPPED by the rewrites.
#     value = "https://${aws_s3_bucket.media.bucket}.s3.${var.region}.amazonaws.com"
#   }
output "s3_bucket_name" { value = aws_s3_bucket.media.bucket }
output "s3_irsa_role_arn" { value = module.s3_irsa.iam_role_arn }
output "s3_public_base_url" { value = "https://${aws_s3_bucket.media.bucket}.s3.${var.region}.amazonaws.com" }
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
