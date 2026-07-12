#!/bin/bash
# Import docker/api_role.json into MongoDB ecommerce_inventory.api_role.
# Idempotent: skip only when the live count matches the seed file's document
# count. A killed mongoimport can leave a partial collection (e.g. 5 of 40
# docs); a bare ">0" guard would treat that as "seeded" forever and silently
# reproduce the gateway 403 bug for whichever routes' rows never landed.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

load_dotenv

command -v jq >/dev/null 2>&1 || { log_err "jq is required (brew install jq)"; exit 1; }

DB="${MONGO_DB_NAME:-ecommerce_inventory}"
USER="${MONGO_USERNAME:-ecommerce}"
PASS="${MONGO_PASSWORD:-ecommerce123}"
CONTAINER="${MONGO_CONTAINER:-ecommerce-mongodb}"
SEED_FILE="$REPO_ROOT/docker/api_role.json"

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

expected=$(jq 'length' "$SEED_FILE")

count=$(docker exec "$CONTAINER" mongosh "$DB" \
    --quiet --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --eval "db.api_role.countDocuments()" 2>/dev/null | tail -1 | tr -d '[:space:]')

if [ "${count:-0}" -eq "$expected" ] 2>/dev/null; then
    log_warn "api_role already seeded ($count/$expected docs) — skipping"
    exit 0
fi

log_info "api_role has ${count:-0}/$expected docs — (re)importing /seed/api_role.json into $DB.api_role..."
# --mode upsert matches on _id (the seed file carries explicit _ids), so a
# partial prior import converges instead of erroring on duplicate keys.
docker exec "$CONTAINER" mongoimport \
    --authenticationDatabase admin -u "$USER" -p "$PASS" \
    --db "$DB" --collection api_role \
    --file /seed/api_role.json --jsonArray --mode upsert
log_ok "api_role seeded ($expected docs)"
