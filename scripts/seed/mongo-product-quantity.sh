#!/bin/bash
# Import docker/product-quantity-history.json into MongoDB
# ecommerce_inventory.productQuantityHistory. Always drops first so the
# manifest is the source of truth.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

load_dotenv

DB="${MONGO_DB_NAME:-ecommerce_inventory}"
USER="${MONGO_USERNAME:-ecommerce}"
PASS="${MONGO_PASSWORD:-ecommerce123}"
CONTAINER="${MONGO_CONTAINER:-ecommerce-mongodb}"

log_info "Dropping $DB.productQuantityHistory before reseed…"
docker exec "$CONTAINER" mongosh "$DB" \
    --quiet --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --eval "db.productQuantityHistory.drop()" >/dev/null

log_info "Importing /seed/product-quantity-history.json into $DB.productQuantityHistory…"
docker exec "$CONTAINER" mongoimport \
    --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --db "$DB" --collection productQuantityHistory \
    --file /seed/product-quantity-history.json --jsonArray

count=$(docker exec "$CONTAINER" mongosh "$DB" \
    --quiet --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --eval "db.productQuantityHistory.countDocuments()" 2>/dev/null | tail -1 | tr -d '[:space:]')

log_ok "productQuantityHistory seeded ($count docs)"
