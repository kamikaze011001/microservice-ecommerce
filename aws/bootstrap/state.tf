# aws/bootstrap/state.tf
#
# Goal: the durable home for EVERY later stack's terraform.tfstate, plus the
# lock that prevents two `terraform apply`s from corrupting it.
#
# ── REQUIREMENT A: S3 bucket for state ───────────────────────────────────────
# Create an S3 bucket named like "${var.project}-tfstate-<account_id>".
#   - Bucket names are GLOBALLY unique → suffix with the account id so it never
#     collides. Get the account id from a data source (hint below).
#   - Turn ON versioning (so a bad apply can be rolled back).
#   - Turn ON server-side encryption (SSE-S3 / AES256 is fine for a sandbox).
#   - BLOCK all public access (state files contain secrets — never public).
#
# In AWS provider v5 these are SEPARATE resources, not bucket sub-blocks:
#   aws_s3_bucket, aws_s3_bucket_versioning,
#   aws_s3_bucket_server_side_encryption_configuration,
#   aws_s3_bucket_public_access_block
#
# ── REQUIREMENT B: DynamoDB lock table ───────────────────────────────────────
# Create an aws_dynamodb_table for state locking.
#   - billing_mode = "PAY_PER_REQUEST" (no idle cost when we're torn down).
#   - hash_key MUST be exactly "LockID" (string) — Terraform's S3 backend
#     hard-codes that attribute name.
#
# ── HINT: account id data source ─────────────────────────────────────────────
# data "aws_caller_identity" "current" {}
# ...then reference data.aws_caller_identity.current.account_id
#
# Docs:
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table
#
# Write your resources below. Ask Claude to review before you apply.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "microecom-state" {
  bucket = format("%s-tfstate-%s", var.project, data.aws_caller_identity.current.account_id)
}

resource "aws_s3_bucket_versioning" "microecom-state-versioning" {
  bucket = aws_s3_bucket.microecom-state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "microecom-state-sse" {
  bucket = aws_s3_bucket.microecom-state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "microecom-state-pab" {
  bucket = aws_s3_bucket.microecom-state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


resource "aws_dynamodb_table" "microecom-state-lock" {
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  name         = format("%s-tfstate-lock", var.project)

  attribute {
    name = "LockID"
    type = "S"
  }
}