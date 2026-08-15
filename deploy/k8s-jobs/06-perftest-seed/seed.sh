#!/usr/bin/env sh
# Seed perftest users (admin + 100 users + roles) into authorization-server
# MySQL. Idempotent: skip if perftest_admin already present; the SQL itself is
# also INSERT IGNORE / ON DUPLICATE KEY. Must run AFTER k8s-apps so the JPA
# tables (account/user/role/account_role) exist (Hibernate ddl-auto creates
# them at authorization-server startup).
set -eu

EXISTS=$(mysql -h mysql.infra.svc.cluster.local -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -N -e "SELECT COUNT(*) FROM ecommerce_dev.account WHERE username='perftest_admin';")

if [ "${EXISTS}" -gt 0 ]; then
  echo "perftest users already seeded (perftest_admin present); skipping"
  exit 0
fi

echo "seeding perftest users..."
mysql -h mysql.infra.svc.cluster.local -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  ecommerce_dev < /seed/perftest-users.sql
echo "perftest user seed complete"
