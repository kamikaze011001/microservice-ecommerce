#!/usr/bin/env bash
# Seed inventory-service's MySQL tables in the kind cluster:
#   ecommerce_dev.inventory_product        (from docker/product.json)
#   ecommerce_dev.product_quantity_history (from docker/product-quantity-history.json)
#
# Why: in-cluster these tables are normally written reactively —
# `inventory_product` by the Kafka ProductUpdate listener (only fires when
# product-service SAVES a product), `product_quantity_history` by admin stock
# ops / PaymentSuccess. The k8s catalog is seeded straight into MongoDB
# (02-mongo-seed), bypassing the save path, so neither table is ever populated
# and every cart item renders "0 available". This is the k8s analogue of the
# docker-network scripts/seed/mysql-inventory-products.sh +
# mysql-product-quantity-history.sh, mirroring the SAME source JSON so product
# ids line up with the Mongo catalog.
#
# Idempotent: skips a table that already has rows. LOCAL-DEV ONLY.
# Requires: jq, kubectl, a running kind cluster with mysql-0 in the infra ns.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

NS="${MYSQL_NS:-infra}"
POD="${MYSQL_POD:-mysql-0}"
DB="${MYSQL_DB_NAME:-ecommerce_dev}"
PASS="${MYSQL_ROOT_PASSWORD:-root}"          # configmap default; override via env
PRODUCTS_JSON="docker/product.json"
QTY_JSON="docker/product-quantity-history.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)"; exit 1; }
[ -f "$PRODUCTS_JSON" ] || { echo "Missing $PRODUCTS_JSON"; exit 1; }
[ -f "$QTY_JSON" ]      || { echo "Missing $QTY_JSON"; exit 1; }

# Run a query against the in-cluster MySQL. -N = no column headers.
mysql_q() { kubectl -n "$NS" exec -i "$POD" -- mysql -uroot -p"$PASS" -N -e "$1" 2>/dev/null; }
# Pipe a SQL stream into the target database.
mysql_pipe() { kubectl -n "$NS" exec -i "$POD" -- mysql -uroot -p"$PASS" "$DB"; }

seed_table() {
  local table="$1" json="$2" jq_expr="$3"

  local exists
  exists=$(mysql_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB' AND table_name='$table';")
  if [ "${exists:-0}" -eq 0 ]; then
    echo "  WARN $table not created yet — start inventory-service once, then re-run"
    return 0
  fi

  local count
  count=$(mysql_q "SELECT COUNT(*) FROM $DB.$table;")
  if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    echo "  $table already seeded ($count rows) — skipping"
    return 0
  fi

  local sql rows
  sql=$(jq -r "$jq_expr" "$json")
  rows=$(printf '%s\n' "$sql" | grep -c INSERT || true)
  echo "  seeding $table ($rows rows)…"
  printf '%s\n' "$sql" | mysql_pipe
}

echo "==> seeding inventory tables in $NS/$POD ($DB)"

# image_url host rewrite: docker/product.json hardcodes http://localhost:9000/
# (the docker-compose MinIO host port). In kind the browser reaches MinIO via the
# media.microecom.local ingress, and order-service snapshots this image_url into
# order_item at order-create — so a localhost:9000 value here ends up in saved
# orders and 404s in the browser. Mirror the same rewrite 02-mongo-seed applies
# to the product catalog.
seed_table inventory_product "$PRODUCTS_JSON" '
  .[] |
  "INSERT INTO inventory_product (id, name, price, image_url) VALUES ("
  + "\"" + ._id."$oid" + "\", "
  + "\"" + (.name | gsub("\""; "\\\"")) + "\", "
  + (.price | tostring) + ", "
  + (if .imageUrl then "\"" + (.imageUrl | gsub("\""; "\\\"") | gsub("http://localhost:9000/"; "http://media.microecom.local/")) + "\"" else "NULL" end)
  + ");"
'

seed_table product_quantity_history "$QTY_JSON" '
  .[] |
  "INSERT INTO product_quantity_history (id, product_id, quantity, created_at) VALUES ("
  + "\"" + ._id + "\", "
  + "\"" + .productId + "\", "
  + (.quantity | tostring) + ", "
  + "\"" + (.createdAt."$date" | sub("Z$"; "") | sub("T"; " ")) + "\""
  + ");"
'

echo "inventory seed complete"

# AvailableStockSeeder runs at inventory-service startup (during k8s-apps, BEFORE
# this script) and seeds the Redis `available:{productId}` reservation counters
# from SUM(product_quantity_history). At that point the ledger was EMPTY, so it
# backfilled 0 rows and created NO counters — every order then fails
# "Insufficient available stock" (the Lua reservation reads a missing key as 0).
# The ledger rows were just inserted above, so restart inventory-service: the
# seeder re-runs, backfills inventory_product.stock from the ledger SUM, and
# re-incrs every `available:*` counter. It deletes-then-incrs each key, so this
# is safe and idempotent (a no-op seed just costs one extra rollout). Without
# this restart, order placement stays broken until the next inventory-service
# pod restart. Mirrors the same fix in scripts/aws/up-all.sh step 8.
#
# Skipped when the inventory-service Deployment isn't present (e.g. running the
# seed standalone before k8s-apps) — the empty-table WARN above already covers
# that case, and restarting a nonexistent Deployment would just add noise.
if kubectl -n apps get deploy inventory-service >/dev/null 2>&1; then
  echo "==> restarting inventory-service so AvailableStockSeeder re-seeds Redis from the populated ledger"
  kubectl -n apps rollout restart deploy/inventory-service
  kubectl -n apps rollout status deploy/inventory-service --timeout=300s
fi
