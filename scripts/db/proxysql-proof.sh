#!/usr/bin/env bash
# Does ProxySQL route the way ADR 0012 says? PASS/FAIL against the live cluster.
#
#   CONTEXT=microecom scripts/db/proxysql-proof.sh      (make proxysql-proof)
#
#   1. every backend is ONLINE (hostgroup 10 = primary, 20 = replicas)
#   2. an untagged SELECT goes to the primary; a /* replica */ SELECT to replicas
#   3. a tagged SELECT inside a read-WRITE transaction stays on the primary
#      (transaction_persistent) — the check-then-write case
#   4. a replica lagging past max_replication_lag is SHUNNED and tagged reads
#      avoid it. Lag is made on purpose (SOURCE_DELAY on mysql-replica-0, which
#      is SHARED infra: every env's replica reads see it for ~30 s); a trap
#      always puts the delay back to 0.
#
# Queries are told apart by a column ALIAS: the digest normalizes literals to
# `?` (and drops comments), but keeps aliases. (The admin interface is SQLite:
# no backslash escapes in LIKE, so the filter is a plain '%proof%'.)
#
# Talks to ONE ProxySQL pod by IP (stats are per pod), with the mysql client in
# mysql-0. --comments: the mysql CLI strips SQL comments by default — it would
# eat the very hint we're testing.
set -euo pipefail

: "${CONTEXT:?set CONTEXT (e.g. microecom)}"
case "$CONTEXT" in *eks*) echo "refusing an EKS context" >&2; exit 1 ;; esac
K="kubectl --context $CONTEXT -n infra"
APP_USER=${APP_USER:-root} APP_PASS=${APP_PASS:-root}

PROXY_IP="$($K get pods -l app.kubernetes.io/name=proxysql -o jsonpath='{.items[0].status.podIP}')"
[[ -n "$PROXY_IP" ]] || { echo "no ProxySQL pod" >&2; exit 1; }

app()   { $K exec -i mysql-0 -c mysql -- mysql --comments -N -B -h "$PROXY_IP" -P6033 -u"$APP_USER" -p"$APP_PASS" 2>/dev/null <<<"$1"; }
admin() { $K exec -i mysql-0 -c mysql -- mysql -N -B -h "$PROXY_IP" -P6032 -uradmin -pradmin 2>/dev/null <<<"$1"; }
on()    { $K exec -i "$1" -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B 2>/dev/null' <<<"$2"; }

fail=0
check() { if eval "$2"; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; fi; }
restore_delay() { on mysql-replica-0 "STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_DELAY=0; START REPLICA;" >/dev/null || true; }
trap restore_delay EXIT

echo "ProxySQL pod $PROXY_IP"

# --- 1. backends ------------------------------------------------------------
pool="$(admin "SELECT hostgroup, srv_host, status FROM stats_mysql_connection_pool ORDER BY hostgroup, srv_host;")"
echo "$pool" | sed 's/^/    /'
check "primary ONLINE in hostgroup 10"  "grep -qE '^10\\s+mysql\\.infra.*ONLINE' <<<\"\$pool\""
check "both replicas ONLINE in hostgroup 20" "[[ \$(grep -cE '^20\\s+mysql-replica-.*ONLINE' <<<\"\$pool\") -eq 2 ]]"

# --- 2 & 3. routing -----------------------------------------------------------
admin "SELECT 1 FROM stats_mysql_query_digest_reset LIMIT 1;" >/dev/null
for _ in 1 2 3; do app "SELECT 1 AS proof_untagged;" >/dev/null; done
for _ in 1 2 3 4 5 6; do app "/* replica */ SELECT 1 AS proof_tagged;" >/dev/null; done
app "CREATE DATABASE IF NOT EXISTS proxysql_proof; CREATE TABLE IF NOT EXISTS proxysql_proof.t (id INT);
     START TRANSACTION; INSERT INTO proxysql_proof.t VALUES (1); /* replica */ SELECT 1 AS proof_in_write_tx; COMMIT;" >/dev/null
digest="$(admin "SELECT hostgroup, digest_text FROM stats_mysql_query_digest WHERE digest_text LIKE '%proof%';")"
echo "$digest" | sed 's/^/    /'
check "untagged SELECT → primary (10)"            "grep -qE '^10\\s.*proof_untagged' <<<\"\$digest\" && ! grep -qE '^20\\s.*proof_untagged' <<<\"\$digest\""
check "/* replica */ SELECT → replicas (20)"      "grep -qE '^20\\s.*proof_tagged' <<<\"\$digest\""
check "tagged SELECT inside a write tx → primary" "grep -qE '^10\\s.*proof_in_write_tx' <<<\"\$digest\" && ! grep -qE '^20\\s.*proof_in_write_tx' <<<\"\$digest\""

# --- 4. lag → shun -----------------------------------------------------------
echo "making mysql-replica-0 lag (SOURCE_DELAY=15, then a write on the primary)…"
on mysql-replica-0 "STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_DELAY=15; START REPLICA;" >/dev/null
app "INSERT INTO proxysql_proof.t VALUES (2);" >/dev/null
shunned=""
for _ in $(seq 1 25); do
  shunned="$(admin "SELECT status FROM stats_mysql_connection_pool WHERE hostgroup=20 AND srv_host LIKE 'mysql-replica-0%';")"
  [[ "$shunned" == SHUNNED* ]] && break
  sleep 1
done
check "a replica lagging > 5 s is SHUNNED (was: ${shunned:-?})" "[[ \"\$shunned\" == SHUNNED* ]]"
before="$(admin "SELECT Queries FROM stats_mysql_connection_pool WHERE hostgroup=20 AND srv_host LIKE 'mysql-replica-0%';")"
for _ in 1 2 3 4 5 6; do app "/* replica */ SELECT 1 AS proof_while_lagging;" >/dev/null; done
after="$(admin "SELECT Queries FROM stats_mysql_connection_pool WHERE hostgroup=20 AND srv_host LIKE 'mysql-replica-0%';")"
check "tagged reads avoid the shunned replica (${before:-?} → ${after:-?} queries)" "[[ \"\$before\" == \"\$after\" ]]"

restore_delay
trap - EXIT
app "DROP DATABASE IF EXISTS proxysql_proof;" >/dev/null
echo
exit "$fail"
