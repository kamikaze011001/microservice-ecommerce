#!/bin/bash
# Import docker/ecommerce.sql into MySQL master ecommerce_dev.
# Idempotent: skip if account table already populated.

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
SQL_FILE="$REPO_ROOT/docker/ecommerce.sql"

[ -f "$SQL_FILE" ] || { log_err "Missing $SQL_FILE"; exit 1; }

# Ensure DB exists
docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" \
    -e "CREATE DATABASE IF NOT EXISTS \`$DB\`;" 2>/dev/null

count=$(docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" -N -B "$DB" \
    -e "SELECT COUNT(*) FROM account;" 2>/dev/null || echo 0)

if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    log_warn "MySQL $DB already seeded (account=$count) — skipping"
    exit 0
fi

log_info "Importing ecommerce.sql into $DB..."
docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" "$DB" < "$SQL_FILE"
log_ok "MySQL $DB seeded"
