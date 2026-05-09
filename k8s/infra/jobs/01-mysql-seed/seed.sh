#!/usr/bin/env sh
# Idempotency reference example: count tables in target schema; skip if > 0.
# This pattern is the simplest viable predicate. The Mongo seed (Job 02) makes
# a different call — see Checkpoint 6 in the design spec.
set -eu

TABLE_COUNT=$(mysql -h mysql.infra.svc.cluster.local -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='ecommerce_dev';")

if [ "${TABLE_COUNT}" -gt 0 ]; then
  echo "mysql already seeded (${TABLE_COUNT} tables present); skipping"
  exit 0
fi

echo "seeding mysql..."
mysql -h mysql.infra.svc.cluster.local -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  ecommerce_dev < /seed/ecommerce.sql
echo "mysql seed complete"
