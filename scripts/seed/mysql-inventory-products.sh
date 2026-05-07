#!/bin/bash
# Seed MySQL ecommerce_dev.inventory_product from docker/product.json.
#
# Why: inventory-service's `inventory_product` table is normally populated by a
# Kafka `ProductUpdate` listener fired when product-service saves a product.
# Local seed bypasses product-service (mongoimport straight into MongoDB), so
# the listener never fires and the table stays empty — making every cart item
# render as 0-stock / unavailable. This script mirrors the same product list
# into the MySQL table so the gRPC stock lookup returns rows.
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
JSON_FILE="$REPO_ROOT/docker/product.json"

[ -f "$JSON_FILE" ] || { log_err "Missing $JSON_FILE"; exit 1; }
command -v jq >/dev/null 2>&1 || { log_err "jq is required (brew install jq)"; exit 1; }

# Ensure the table exists (Hibernate creates it once inventory-service has run).
table_exists=$(docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" -N -B "$DB" \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB' AND table_name='inventory_product';" 2>/dev/null || echo 0)
if [ "${table_exists:-0}" -eq 0 ]; then
    log_warn "inventory_product table not yet created — start inventory-service once, then re-run"
    exit 0
fi

count=$(docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" -N -B "$DB" \
    -e "SELECT COUNT(*) FROM inventory_product;" 2>/dev/null || echo 0)

if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    log_warn "inventory_product already seeded ($count rows) — skipping"
    exit 0
fi

log_info "Generating INSERT statements from $JSON_FILE…"
# image_url must be seeded: order-service snapshots it via gRPC from
# inventory_product into order_item at order create, and BFF surfaces it on
# the order detail page. Skipping it leaves image_url null all the way down.
sql=$(jq -r '
  .[] |
  "INSERT INTO inventory_product (id, name, price, image_url) VALUES ("
  + "\"" + ._id."$oid" + "\", "
  + "\"" + (.name | gsub("\""; "\\\"")) + "\", "
  + (.price | tostring) + ", "
  + (if .imageUrl then "\"" + (.imageUrl | gsub("\""; "\\\"")) + "\"" else "NULL" end)
  + ");"
' "$JSON_FILE")

inserted=$(printf '%s\n' "$sql" | wc -l | tr -d '[:space:]')
log_info "Importing $inserted rows into $DB.inventory_product…"
printf '%s\n' "$sql" | docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" "$DB"
log_ok "inventory_product seeded ($inserted rows)"
