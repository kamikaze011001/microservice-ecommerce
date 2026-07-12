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

# A started Mongo container is not an accepting Mongo. Without this poll the
# countDocuments below comes back empty, ${count:-0} evaluates to 0, mongoimport
# fails against a not-yet-listening server, and `set -e` kills `make up`.
# 15 x 2s = 30s, matching scripts/kafka/ensure-connector.sh.
for i in $(seq 1 15); do
    if docker exec "$CONTAINER" mongosh --quiet \
        --authenticationDatabase admin -u "$USER" -p "$PASS" \
        --eval 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 15 ]; then
        log_err "MongoDB ($CONTAINER) not accepting connections after 30s"
        exit 1
    fi
    sleep 2
done

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
