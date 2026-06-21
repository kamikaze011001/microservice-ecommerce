#!/usr/bin/env bash
# Seed inventory-service's RDS tables:
#   ecommerce_dev.inventory_product        (from docker/product.json)
#   ecommerce_dev.product_quantity_history (from docker/product-quantity-history.json)
#
# WHY: these tables are normally written reactively — inventory_product by the
# Kafka ProductUpdate listener (only fires when product-service SAVES a product),
# product_quantity_history by admin stock ops / PaymentSuccess. The catalog is
# seeded straight into MongoDB (seed-mongo.sh), bypassing the save path, so
# neither table is ever populated and every cart item renders "0 available".
# This is the AWS/RDS twin of scripts/seed/k8s-inventory.sh, mirroring the SAME
# source JSON so product ids line up with the Mongo catalog.
#
# ORDERING: inventory-service creates these tables via Hibernate ddl-auto at
# startup, so run this AFTER inventory-service reaches Running (up-all.sh's
# step-6 rollout gate enforces it). Standalone, we preflight that the tables
# exist and tell you to wait if not.
#
# Like seed-rds.sh, the mysql client runs from a throwaway pod INSIDE the cluster
# (RDS has no public endpoint) with MYSQL_PWD to keep the password off argv.
# INSERT IGNORE makes re-runs idempotent (id is the PK).
#
# Usage:  AWS_PROFILE=microecom scripts/aws/seed-inventory.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT/aws/main"
PRODUCTS_JSON="$ROOT/docker/product.json"
QTY_JSON="$ROOT/docker/product-quantity-history.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
[ -f "$PRODUCTS_JSON" ] || { echo "Missing $PRODUCTS_JSON" >&2; exit 1; }
[ -f "$QTY_JSON" ]      || { echo "Missing $QTY_JSON" >&2; exit 1; }

RDS_HOST="$(terraform -chdir="$TF" output -raw rds_primary_endpoint)"
DB_PASS="$(terraform -chdir="$TF" output -raw db_master_password)"

# Run `mysql <args>` in a one-shot pod; SQL (when loading) is piped via stdin.
run_mysql() {  # run_mysql <mysql-args...>   (optional SQL on stdin)
  kubectl run "inv-seed-${RANDOM}" -n apps --rm -i --restart=Never \
    --image=mysql:8.0 --env=MYSQL_PWD="$DB_PASS" --command -- \
    mysql -h "$RDS_HOST" -uadmin "$@"
}

# Preflight: the tables must exist (inventory-service ddl-auto creates them).
echo "▶ checking inventory tables exist at ${RDS_HOST} ..."
TABLES="$(run_mysql ecommerce_dev -N -e "
  SELECT COUNT(*) FROM information_schema.tables
  WHERE table_schema='ecommerce_dev'
    AND table_name IN ('inventory_product','product_quantity_history');" 2>&1 </dev/null || true)"
# Catch connection/auth/db errors BEFORE digit-stripping — an error string like
# "Can't connect to MySQL server on 'host:3306'" would otherwise yield a big
# number that sails past the `< 2` gate and we'd "seed" against nothing. Mirrors
# the guard in seed-rds.sh.
if printf '%s' "$TABLES" | grep -qiE "can't connect|unknown database|access denied|error 2003|error 1045"; then
  echo "✋ cannot reach RDS / query failed:" >&2
  printf '%s\n' "$TABLES" | grep -iE "error|can't|denied|connect" | tail -2 >&2
  echo "   Check RDS is up and the apps namespace can reach it on 3306, then re-run." >&2
  exit 1
fi
NTAB="$(printf '%s' "$TABLES" | tr -dc '0-9')"
if [ "${NTAB:-0}" -lt 2 ]; then
  echo "✋ inventory tables not ready (found ${NTAB:-0}/2)." >&2
  echo "   Start inventory-service once (ddl-auto creates them), then re-run." >&2
  exit 1
fi

# Build INSERT IGNORE statements. Same jq as scripts/seed/k8s-inventory.sh; the
# image_url host rewrite mirrors seed-mongo.sh's catalog rewrite so order_item
# snapshots match the catalog. (S3 isn't wired until Phase 4c, so the host is a
# placeholder either way — kept consistent with Mongo.)
SQL_PRODUCTS="$(jq -r '
  .[] |
  "INSERT IGNORE INTO inventory_product (id, name, price, image_url) VALUES ("
  + "\"" + ._id."$oid" + "\", "
  + "\"" + (.name | gsub("\""; "\\\"")) + "\", "
  + (.price | tostring) + ", "
  + (if (.imageUrl // "" | length) > 0 then "\"" + (.imageUrl | gsub("\""; "\\\"") | gsub("http://localhost:9000/"; "http://media.microecom.local/")) + "\"" else "NULL" end)
  + ");"' "$PRODUCTS_JSON")"

SQL_QTY="$(jq -r '
  .[] |
  "INSERT IGNORE INTO product_quantity_history (id, product_id, quantity, created_at) VALUES ("
  + "\"" + ._id + "\", "
  + "\"" + .productId + "\", "
  + (.quantity | tostring) + ", "
  + "\"" + (.createdAt."$date" | sub("Z$"; "") | sub("T"; " ")) + "\""
  + ");"' "$QTY_JSON")"

PROD_ROWS="$(printf '%s\n' "$SQL_PRODUCTS" | grep -c INSERT || true)"
QTY_ROWS="$(printf '%s\n' "$SQL_QTY" | grep -c INSERT || true)"
echo "▶ seeding inventory_product (${PROD_ROWS} rows) + product_quantity_history (${QTY_ROWS} rows) ..."
# Pipe the INSERTs + a labelled post-seed count in ONE mysql session (no extra
# pod): INSERT IGNORE swallows PK conflicts silently, so echo the resulting table
# counts as proof rather than trusting a bare exit 0.
printf '%s\n%s\nSELECT CONCAT("inventory_product=", COUNT(*)) FROM inventory_product;\nSELECT CONCAT("product_quantity_history=", COUNT(*)) FROM product_quantity_history;\n' \
  "$SQL_PRODUCTS" "$SQL_QTY" | run_mysql ecommerce_dev -N
echo "✅ inventory stock seed complete (see the row counts above)."
