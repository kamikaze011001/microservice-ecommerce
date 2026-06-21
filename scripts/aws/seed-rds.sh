#!/usr/bin/env bash
# Seed RDS with the DATA in docker/ecommerce.sql (accounts, roles, users).
#
# IMPORTANT ordering: ecommerce.sql is data-only (INSERTs, no CREATE TABLE). The
# tables are created by the apps' Hibernate ddl-auto on first connect, so run
# this AFTER the DB services (authorization-server in particular) reach Running.
#
# Runs the mysql client from a throwaway pod INSIDE the cluster, so it inherits
# the EKS node security group that the RDS SG admits on 3306 — RDS has no public
# endpoint, so seeding from your laptop wouldn't reach it. Idempotent: guards on
# the `account` row count and skips if already populated.
#
# Usage:  AWS_PROFILE=microecom scripts/aws/seed-rds.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT/aws/main"
SQL="$ROOT/docker/ecommerce.sql"

RDS_HOST="$(terraform -chdir="$TF" output -raw rds_primary_endpoint)"
DB_PASS="$(terraform -chdir="$TF" output -raw db_master_password)"

# Run `mysql <args>` in a one-shot pod in the apps namespace. SQL (when loading)
# is piped via stdin; MYSQL_PWD keeps the password off the process args/logs.
run_mysql() {  # run_mysql <mysql-args...>   (optional SQL on stdin)
  kubectl run "rds-seed-${RANDOM}" -n apps --rm -i --restart=Never \
    --image=mysql:8.0 --env=MYSQL_PWD="$DB_PASS" --command -- \
    mysql -h "$RDS_HOST" -uadmin "$@"
}

echo "▶ checking RDS seed state at ${RDS_HOST} ..."
GUARD="$(run_mysql ecommerce_dev -N -e 'SELECT COUNT(*) FROM account;' 2>&1 </dev/null || true)"
COUNT="$(printf '%s' "$GUARD" | tr -dc '0-9')"

if printf '%s' "$GUARD" | grep -qiE "doesn't exist|unknown database|can't connect|access denied"; then
  echo "✋ RDS schema not ready — guard query failed:" >&2
  printf '%s\n' "$GUARD" | grep -iE "error|doesn't|denied|connect" | tail -2 >&2
  echo "   Wait until authorization-server is Running (its ddl-auto creates the tables), then re-run." >&2
  exit 1
fi

if [ -n "$COUNT" ] && [ "$COUNT" -gt 0 ]; then
  echo "▶ RDS already seeded (account rows=${COUNT}); skipping"
  exit 0
fi

echo "▶ seeding RDS data from docker/ecommerce.sql ..."
run_mysql ecommerce_dev < "$SQL"
echo "✅ RDS data seed complete (account/role/user)."
echo "ℹ️  Buy-flow stock lives in separate seeds — run the RDS equivalents of"
echo "   scripts/seed/mysql-inventory-products.sh + mysql-product-quantity-history.sh"
echo "   if you need cart/checkout to show stock (not required to verify Phase 4a)."
