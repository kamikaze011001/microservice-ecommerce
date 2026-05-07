#!/bin/bash
# Run all seed scripts in order. Each is idempotent.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

log_info "Seeding MySQL..."
"$SCRIPT_DIR/mysql.sh"

log_info "Seeding MongoDB api_role..."
"$SCRIPT_DIR/mongo-roles.sh"

log_info "Uploading product images to MinIO..."
"$SCRIPT_DIR/minio-product-images.sh"

log_info "Seeding MongoDB product..."
"$SCRIPT_DIR/mongo-products.sh"

log_info "Seeding MongoDB productQuantityHistory..."
"$SCRIPT_DIR/mongo-product-quantity.sh"

log_info "Seeding MySQL inventory_product..."
"$SCRIPT_DIR/mysql-inventory-products.sh"

log_info "Seeding MySQL product_quantity_history..."
"$SCRIPT_DIR/mysql-product-quantity-history.sh"

log_ok "All seed data imported"
