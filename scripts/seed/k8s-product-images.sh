#!/usr/bin/env bash
# Upload the real product images (docker/seed-images/<category>/<slug>.jpg) into
# the kind cluster's MinIO at products/<productId>/<slug>.jpg — the object key
# the stored imageUrl points at.
#
# k8s analogue of scripts/seed/minio-product-images.sh (docker-network based).
# We stream each JPG into the minio-0 `setup` sidecar (which holds the `local`
# mc alias) via `kubectl exec ... cat > file`, then `mc cp` it into the bucket.
# NOTE: we deliberately do NOT use `kubectl cp` — that requires `tar` inside the
# target container, which the minio/mc image does not have.
#
# slug → productId → category mapping comes from scripts/seed/products-manifest.json.
# Idempotent: mc cp overwrites; safe to re-run. LOCAL-DEV ONLY — real deployments
# upload via the core-s3 presign flow.
# Requires: python3, kubectl, a running kind cluster with minio-0 in infra ns.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

NS=infra
POD=minio-0
SIDECAR=setup
BUCKET=ecommerce-media
MANIFEST=scripts/seed/products-manifest.json
SEED_DIR=docker/seed-images

echo "==> uploading product images to minio://$BUCKET via $POD ($SIDECAR sidecar)"
uploaded=0
missing=0

# Emit "category<TAB>slug<TAB>productId" per product from the manifest.
while IFS=$'\t' read -r category slug productId; do
  src="$SEED_DIR/$category/$slug.jpg"
  if [ ! -f "$src" ]; then
    echo "  WARN missing $src"; missing=$((missing + 1)); continue
  fi
  key="products/$productId/$slug.jpg"
  # Stream the file into the sidecar (no tar/kubectl-cp), then mc cp to bucket.
  kubectl -n "$NS" exec -i "$POD" -c "$SIDECAR" -- sh -c "cat > /tmp/img.jpg" < "$src"
  kubectl -n "$NS" exec "$POD" -c "$SIDECAR" -- \
    mc cp --attr "Content-Type=image/jpeg" /tmp/img.jpg "local/$BUCKET/$key" >/dev/null
  uploaded=$((uploaded + 1))
done < <(python3 -c "
import json
for p in json.load(open('$MANIFEST'))['products']:
    print(p['category'] + '\t' + p['slug'] + '\t' + p['productId'])
")

echo "product images seeded (uploaded=$uploaded missing=$missing)"
