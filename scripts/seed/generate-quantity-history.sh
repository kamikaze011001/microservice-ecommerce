#!/bin/bash
# Generate docker/product-quantity-history.json from products-manifest.json.
# One ProductQuantityHistory document per product carrying the manifest
# quantity, so the product-service aggregation surfaces the correct stock
# level on the storefront. Output is committed; re-run when manifest changes.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/seed/products-manifest.json"
OUT="$REPO_ROOT/docker/product-quantity-history.json"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

# Stable _id: prefix `qh` + last 22 hex chars of productId. Reproducible
# across reseeds and visibly tied to the product.
jq '
  .products | map({
    "_id":       ("qh" + (.productId[2:])),
    "_class":    "org.aibles.ecommerce.product_service.entity.ProductQuantityHistory",
    "productId": .productId,
    "quantity":  .quantity,
    "createdAt": { "$date": "2026-05-03T00:00:00Z" }
  })
' "$MANIFEST" > "$OUT"

log_ok "Wrote $(jq 'length' "$OUT") quantity-history docs to $OUT"
