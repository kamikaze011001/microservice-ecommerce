#!/usr/bin/env bash
# Do the app's read-after-write flows survive replica lag? PASS/FAIL per env
# (ADR 0012's proof — expect FAIL on images that read Slave*Repo directly,
# PASS on images routed through ProxySQL).
#
#   CONTEXT=microecom scripts/db/db-lag-proof.sh [env]    (make db-lag-proof env=preview-x)
#
#   1. puts BOTH replicas 10 s behind (SOURCE_DELAY=10 + a 1/s heartbeat write
#      on the primary, so the lag never drains), and waits until they really
#      are > 5 s behind. The replicas are SHARED infra: every env's replica
#      reads see the lag for the ~30 s this runs; a trap always restores it.
#   2. runs scripts/db/db-lag-proof.js in the env's namespace: write, then read
#      straight back — cart, order detail, order history, cancel
#   3. if the env talks to ProxySQL (its schema shows up in the query digest):
#      both replicas were SHUNNED and history's @ReplicaRead was answered by the
#      primary's reader-hostgroup entry (the weight-1 fallback)
#   4. lifts the lag, restores the cart and cancels the orders (they stay
#      PROCESSING until the pending-order expiry, like the Bruno suite's)
#
# ProxySQL stats are per pod, so they are summed over every ProxySQL pod.
set -euo pipefail

: "${CONTEXT:?set CONTEXT (e.g. microecom)}"
case "$CONTEXT" in *eks*) echo "refusing an EKS context" >&2; exit 1 ;; esac
ENV_NAME=${1:-prod-like}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DELAY=10
K="kubectl --context $CONTEXT"

if [[ "$ENV_NAME" == prod-like ]]; then NS=apps DB=ecommerce_dev   # as devbox.sh cmd_api_test
else
  names="$(python3 "$ROOT/deploy/devbox/lib/env_gen.py" names --env "$ENV_NAME")"
  NS="$(jq -r .namespace <<<"$names")" DB="$(jq -r .mysqlDb <<<"$names")"
fi
$K get ns "$NS" >/dev/null || { echo "env $ENV_NAME has no namespace $NS" >&2; exit 1; }

REPLICAS=(mysql-replica-0 mysql-replica-1)
PROXIES=($($K -n infra get pods -l app.kubernetes.io/name=proxysql --field-selector=status.phase=Running -o jsonpath='{.items[*].status.podIP}'))

on()    { $K -n infra exec -i "$1" -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B 2>/dev/null' <<<"$2"; }
admin() { $K -n infra exec -i mysql-0 -c mysql -- mysql -N -B -h "$1" -P6032 -uradmin -pradmin 2>/dev/null <<<"$2"; }
admin_sum() {  # <sql returning one number per pod> → the sum over every ProxySQL pod
  local ip n total=0
  for ip in "${PROXIES[@]}"; do n="$(admin "$ip" "$1")"; total=$((total + ${n:-0})); done
  echo "$total"
}
lag_of() {  # no -N here: it would strip the field names from \G output
  $K -n infra exec -i "$1" -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" 2>/dev/null' <<<"SHOW REPLICA STATUS\G" \
    | awk '/Seconds_Behind_Source:/ {print $2}'
}
node_run() {  # <name> <args…> → run db-lag-proof.js in the env's namespace
  local name=$1; shift
  $K -n "$NS" run "db-lag-proof-$name-$(date +%H%M%S)" --rm -i --restart=Never --quiet \
    --image=node:20-alpine -- node -e "$(cat "$ROOT/scripts/db/db-lag-proof.js")" -- "$@" | tail -1
}

fail=0
check() { if eval "$2"; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; fi; }

HB_PID=""
restore() {
  [[ -n "$HB_PID" ]] && kill "$HB_PID" 2>/dev/null || true
  local r; for r in "${REPLICAS[@]}"; do
    on "$r" "STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_DELAY=0; START REPLICA;" >/dev/null || true
  done
}
trap restore EXIT

echo "env $ENV_NAME (namespace $NS, schema $DB) · ProxySQL pods: ${PROXIES[*]:-none}"

# --- 1. lag -------------------------------------------------------------------
echo "making both replicas lag ${DELAY} s…"
on mysql-0 "CREATE DATABASE IF NOT EXISTS db_lag_proof; CREATE TABLE IF NOT EXISTS db_lag_proof.hb (ts DATETIME(3));" >/dev/null
for r in "${REPLICAS[@]}"; do
  on "$r" "STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_DELAY=$DELAY; START REPLICA;" >/dev/null
done
# One exec, one loop inside the pod: a write a second keeps a fresh event
# waiting in the relay log, so the lag stays near DELAY instead of draining.
$K -n infra exec mysql-0 -c mysql -- sh -c \
  'while :; do mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "INSERT INTO db_lag_proof.hb VALUES (NOW(3))" 2>/dev/null; sleep 1; done' &
HB_PID=$!
lagged=0
for _ in $(seq 1 30); do
  l0="$(lag_of mysql-replica-0)" l1="$(lag_of mysql-replica-1)"
  if [[ "${l0:-0}" =~ ^[0-9]+$ && "${l1:-0}" =~ ^[0-9]+$ && "$l0" -gt 5 && "$l1" -gt 5 ]]; then lagged=1; break; fi
  sleep 1
done
check "both replicas > 5 s behind (${l0:-?} s, ${l1:-?} s)" "[[ $lagged == 1 ]]"
[[ $lagged == 1 ]] || exit 1
# Each ProxySQL pod's monitor shuns on its own clock: wait for all of them,
# or a read could still land on a lagging replica through a slower pod.
expected=$((2 * ${#PROXIES[@]})) shunned=0
for _ in $(seq 1 15); do
  shunned=$(admin_sum "SELECT COUNT(*) FROM stats_mysql_connection_pool WHERE hostgroup=20 AND srv_host LIKE 'mysql-replica-%' AND status LIKE 'SHUNNED%';")
  [[ "$shunned" -ge "$expected" ]] && break
  sleep 1
done
fallback_q0=$(admin_sum "SELECT COALESCE(SUM(Queries),0) FROM stats_mysql_connection_pool WHERE hostgroup=20 AND srv_host NOT LIKE 'mysql-replica-%';")
for ip in "${PROXIES[@]}"; do admin "$ip" "SELECT 1 FROM stats_mysql_query_digest_reset LIMIT 1;" >/dev/null; done

# --- 2. flows -----------------------------------------------------------------
echo "write → read-back flows in $NS (replicas still ${DELAY} s behind)…"
result="$(node_run flows flows)"
if ! jq -e .checks <<<"$result" >/dev/null 2>&1; then
  echo "  flows did not run: $result" >&2; exit 1
fi
while IFS=$'\t' read -r pass name got; do
  check "$name ($got)" "[[ $pass == true ]]"
done < <(jq -r '.checks[] | [.pass, .name, .got] | @tsv' <<<"$result")

# --- 3. routing (only for envs whose SQL goes through ProxySQL) ----------------
schema_q=$(admin_sum "SELECT COALESCE(SUM(count_star),0) FROM stats_mysql_query_digest WHERE schemaname='$DB';")
if [[ "$schema_q" -gt 0 ]]; then
  fallback_q1=$(admin_sum "SELECT COALESCE(SUM(Queries),0) FROM stats_mysql_connection_pool WHERE hostgroup=20 AND srv_host NOT LIKE 'mysql-replica-%';")
  replica_reads=$(admin_sum "SELECT COALESCE(SUM(count_star),0) FROM stats_mysql_query_digest WHERE schemaname='$DB' AND hostgroup=20;")
  check "every replica SHUNNED on every ProxySQL pod ($shunned of $expected)" "[[ $shunned -ge $expected ]]"
  check "@ReplicaRead reads still went to the reader hostgroup ($replica_reads)" "[[ $replica_reads -gt 0 ]]"
  check "…answered by the primary's fallback entry (+$((fallback_q1 - fallback_q0)) queries)" "[[ $fallback_q1 -gt $fallback_q0 ]]"
else
  echo "  (no $DB queries in ProxySQL's digest: $ENV_NAME connects to MySQL directly)"
fi

# --- 4. lift the lag, clean up -----------------------------------------------------
restore; trap - EXIT
for _ in $(seq 1 30); do
  [[ "$(lag_of mysql-replica-0)" == 0 && "$(lag_of mysql-replica-1)" == 0 ]] && break; sleep 1
done
on mysql-0 "DROP DATABASE IF EXISTS db_lag_proof;" >/dev/null
node_run cleanup cleanup "$(jq -c '{orderIds, cart}' <<<"$result")" >/dev/null || echo "  (cleanup failed — cancel the db-lag-proof orders by hand)" >&2
echo
exit "$fail"
