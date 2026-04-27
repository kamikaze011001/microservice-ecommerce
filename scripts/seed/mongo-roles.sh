#!/bin/bash
# Import docker/api_role.json into MongoDB ecommerce_inventory.api_role.
# Idempotent: skip if collection already non-empty.

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

count=$(docker exec "$CONTAINER" mongosh "$DB" \
    --quiet --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --eval "db.api_role.countDocuments()" 2>/dev/null | tail -1 | tr -d '[:space:]')

if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    log_warn "api_role already seeded ($count docs) — skipping"
    exit 0
fi

log_info "Importing /seed/api_role.json into $DB.api_role..."
docker exec "$CONTAINER" mongoimport \
    --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --db "$DB" --collection api_role \
    --file /seed/api_role.json --jsonArray
log_ok "api_role seeded"
