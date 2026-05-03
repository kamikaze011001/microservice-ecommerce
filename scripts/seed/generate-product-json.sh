#!/bin/bash
# Generate docker/product.json from scripts/seed/products-manifest.json.
# Output is committed; re-run when manifest changes.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/seed/products-manifest.json"
OUT="$REPO_ROOT/docker/product.json"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

base_url=$(jq -r '.publicBaseUrl' "$MANIFEST")

# Field names match Product entity (camelCase). Quantity is NOT on the
# Product entity — it's summed from productQuantityHistory by the service
# layer and exposed in ProductResponse via @JsonNaming(SnakeCase). See
# scripts/seed/generate-quantity-history.sh for the quantity seed.
jq --arg base "$base_url" '
  .products | map({
    "_id":        { "$oid": .productId },
    "_class":     "org.aibles.ecommerce.product_service.entity.Product",
    "name":       .name,
    "price":      .price,
    "category":   .category,
    "attributes": .attributes,
    "imageUrl":   ($base + "/products/" + .productId + "/" + .slug + ".jpg")
  })
' "$MANIFEST" > "$OUT"

log_ok "Wrote $(jq 'length' "$OUT") products to $OUT"
