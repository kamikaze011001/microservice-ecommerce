#!/bin/bash
# Seed MySQL ecommerce_dev.product_quantity_history from
# docker/product-quantity-history.json.
#
# Why: inventory-service's gRPC `list` (called by bff-service when rendering the
# cart) computes available stock as
#   SELECT SUM(quantity) FROM product_quantity_history GROUP BY product_id
# Rows are normally inserted by inventoryService.update() (post-purchase
# decrements) and by the PaymentSuccess Kafka listener — neither runs during
# `make bootstrap`. The existing mongo-product-quantity.sh script populates a
# DIFFERENT collection owned by product-service (used for the storefront
# product list), not inventory-service's MySQL table. So the cart shows every
# item as 0-stock until a real purchase flows through.
#
# Idempotent: skip if table already has rows.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

load_dotenv

DB="${MYSQL_DB_NAME:-ecommerce_dev}"
PASS="${MYSQL_MASTER_PASSWORD:-masterpassword}"
CONTAINER="${MYSQL_CONTAINER:-mysql-master}"
JSON_FILE="$REPO_ROOT/docker/product-quantity-history.json"

[ -f "$JSON_FILE" ] || { log_err "Missing $JSON_FILE"; exit 1; }
command -v jq >/dev/null 2>&1 || { log_err "jq is required (brew install jq)"; exit 1; }

# Ensure the table exists (Hibernate creates it once inventory-service has run).
table_exists=$(docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" -N -B "$DB" \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB' AND table_name='product_quantity_history';" 2>/dev/null || echo 0)
if [ "${table_exists:-0}" -eq 0 ]; then
    log_warn "product_quantity_history table not yet created — start inventory-service once, then re-run"
    exit 0
fi

count=$(docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" -N -B "$DB" \
    -e "SELECT COUNT(*) FROM product_quantity_history;" 2>/dev/null || echo 0)

if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    log_warn "product_quantity_history already seeded ($count rows) — skipping"
    exit 0
fi

log_info "Generating INSERT statements from $JSON_FILE…"
# id reuses the manifest _id so reseeds line up with the Mongo doc; created_at
# is fixed to the manifest date — same behaviour as generate-quantity-history.sh.
sql=$(jq -r '
  .[] |
  "INSERT INTO product_quantity_history (id, product_id, quantity, created_at) VALUES ("
  + "\"" + ._id + "\", "
  + "\"" + .productId + "\", "
  + (.quantity | tostring) + ", "
  + "\"" + (.createdAt."$date" | sub("Z$"; "") | sub("T"; " ")) + "\""
  + ");"
' "$JSON_FILE")

inserted=$(printf '%s\n' "$sql" | wc -l | tr -d '[:space:]')
log_info "Importing $inserted rows into $DB.product_quantity_history…"
printf '%s\n' "$sql" | docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" "$DB"
log_ok "product_quantity_history seeded ($inserted rows)"
