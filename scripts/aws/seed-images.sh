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
