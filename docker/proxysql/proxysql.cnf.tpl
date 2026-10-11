# ProxySQL for docker-compose (ADR 0012). ${VARS} are filled in by the
# container's start command (docker/mysql.yml). The k8s twin is
# deploy/charts/microecom/charts/infra/templates/proxysql.yaml — keep the two
# routing sections identical.
#
#   hostgroup 10  writer   master
#   hostgroup 20  readers  slave1, slave2 (weight 1000, shunned past 5 s lag)
#                          + master at weight 1 (answer even if both slaves lag)
datadir="/var/lib/proxysql"

admin_variables=
{
  admin_credentials="admin:admin;radmin:radmin"
  mysql_ifaces="0.0.0.0:6032"
  restapi_enabled=true
  restapi_port=6070
}

mysql_variables=
{
  threads=4
  max_connections=2048
  interfaces="0.0.0.0:6033"
  default_schema="information_schema"
  server_version="8.0.40"
  connect_timeout_server=3000
  monitor_username="monitor"
  monitor_password="${PROXYSQL_MONITOR_PASSWORD}"
  monitor_ping_interval=2000
  monitor_read_only_interval=1500
  monitor_replication_lag_interval=1000
}

mysql_servers=
(
  { address="master", port=3306, hostgroup=10, max_connections=500 },
  { address="master", port=3306, hostgroup=20, weight=1, max_connections=500 },
  { address="slave1", port=3306, hostgroup=20, weight=1000, max_connections=500, max_replication_lag=5 },
  { address="slave2", port=3306, hostgroup=20, weight=1000, max_connections=500, max_replication_lag=5 }
)

mysql_users=
(
  { username="${MYSQL_APP_USER}", password="${MYSQL_APP_PASSWORD}", default_hostgroup=10, transaction_persistent=1 }
)

mysql_query_rules=
(
  { rule_id=1, active=1, match_pattern="^/\\* replica \\*/", destination_hostgroup=20, apply=1 }
)
