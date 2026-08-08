#!/usr/bin/env sh
# Idempotency: skip only if the seed DATA is already present. This must NOT check
# "do tables exist" — the JPA services create the schema via Hibernate ddl-auto,
# and this Job runs (by design) AFTER k8s-apps, so the tables ALWAYS exist by the
# time it runs. A table-count guard therefore tripped every time and the seed
# silently never ran (role/account_role left empty -> admin endpoints 403,
# perftest_admin unrolled). Guard on row data instead: `account` is empty right
# after apps boot on a fresh bootstrap, and non-empty on any re-run.
set -eu

SEEDED=$(mysql -h mysql.infra.svc.cluster.local -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  ecommerce_dev -N -e "SELECT COUNT(*) FROM account;" 2>/dev/null || echo 0)

if [ "${SEEDED}" -gt 0 ]; then
  echo "mysql already seeded (account has ${SEEDED} rows); skipping"
  exit 0
fi

echo "seeding mysql..."
mysql -h mysql.infra.svc.cluster.local -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  ecommerce_dev < ${SEED_ROOT:-/seed}/ecommerce.sql
echo "mysql seed complete"
