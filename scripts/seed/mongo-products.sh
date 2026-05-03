#!/bin/bash
# Import docker/product.json into MongoDB ecommerce_inventory.product.
# Always drops the collection first so the manifest is the source of truth.

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

log_info "Dropping $DB.product before reseed…"
docker exec "$CONTAINER" mongosh "$DB" \
    --quiet --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --eval "db.product.drop()" >/dev/null

log_info "Importing /seed/product.json into $DB.product…"
docker exec "$CONTAINER" mongoimport \
    --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --db "$DB" --collection product \
    --file /seed/product.json --jsonArray

count=$(docker exec "$CONTAINER" mongosh "$DB" \
    --quiet --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --eval "db.product.countDocuments()" 2>/dev/null | tail -1 | tr -d '[:space:]')

log_ok "product seeded ($count docs)"
