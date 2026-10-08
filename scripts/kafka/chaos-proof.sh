#!/usr/bin/env bash
# Kafka chaos proof: run the k6 payment saga load on a local k8s cluster with the
# consumers scaled out, kill and roll consumer pods in the middle of it, wait for
# Kafka to drain, then check that nothing was lost, applied twice, or left stuck.
#
#   CONTEXT=microecom scripts/kafka/chaos-proof.sh        (or: make kafka-chaos-proof)
#
# Why chaos and not just load: a clean run never exercises redelivery. Killing a pod
# mid-batch leaves offsets uncommitted (→ the next owner re-reads them) and every
# join/leave triggers a rebalance — exactly what PR2–PR4 had to make safe.
#
# Every invariant is scoped to rows written AFTER the run starts, using per-table
# high-water marks read before the run (so JVM vs DB clock/timezone never matters).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTX="${CONTEXT:?set CONTEXT=<kube-context> (e.g. microecom) — never the ambient one}"
JOB=k6-payment-stress
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300}"
# Consumers scaled out for the run (HPA minReplicas), restored on exit.
SCALE_OUT=("order-service:3" "inventory-service:2" "product-service:2")
# The products the k6 job orders — read from the job itself so the two can't drift.
IFS=',' read -r -a PRODUCTS <<<"$(sed -n 's/.*name: PRODUCT_IDS, value: "\([^"]*\)".*/\1/p' "$ROOT/deploy/k6-stress/payment-job.yaml")"
[[ ${#PRODUCTS[@]} -gt 0 ]] || { echo "chaos-proof: no PRODUCT_IDS in payment-job.yaml" >&2; exit 1; }

if [[ "$CTX" == *eks* && "${ALLOW_REMOTE:-0}" != 1 ]]; then
  echo "chaos-proof: refusing to kill pods on '$CTX' (looks like a real cluster). ALLOW_REMOTE=1 to override." >&2
  exit 1
fi

kc()    { kubectl --context "$CTX" "$@"; }
sql()   { kc -n infra exec mysql-0 -- mysql -uroot -proot -N -B ecommerce_dev -e "$1" 2>/dev/null; }
mongo() { kc -n infra exec mongodb-0 -c mongodb -- mongosh --host 127.0.0.1 -u root -p root \
            --authenticationDatabase admin --quiet ecommerce_inventory --eval "$1"; }
redis() { kc -n infra exec deploy/redis -- redis-cli "$@"; }
kbin()  { kc -n infra exec kafka-0 -- "/opt/kafka/bin/$1" --bootstrap-server localhost:9092 "${@:2}"; }
log()   { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# ── restore HPAs no matter how we exit ──────────────────────────────────────────
declare -A ORIGINAL_MIN=()
restore() {
  for svc in "${!ORIGINAL_MIN[@]}"; do
    kc -n apps patch hpa "$svc" --type merge -p "{\"spec\":{\"minReplicas\":${ORIGINAL_MIN[$svc]}}}" >/dev/null 2>&1 || true
  done
  [[ -n "${CHAOS_PID:-}" ]] && kill "$CHAOS_PID" 2>/dev/null || true
}
trap restore EXIT

# ── consumer lag and DLT totals ─────────────────────────────────────────────────
total_lag() {
  # Sum of the LAG column for every group except the replay tool's own.
  kbin kafka-consumer-groups.sh --all-groups --describe 2>/dev/null |
    awk '$1 != "GROUP" && $1 != "dlt-replay" && $6 ~ /^[0-9]+$/ {s += $6} END {print s + 0}'
}
dlt_records() {
  kbin kafka-get-offsets.sh --topic-pattern '.*\.DLT' 2>/dev/null | awk -F: '{s += $3} END {print s + 0}'
}
mid_flight_sagas() {
  sql "SELECT COUNT(*) FROM saga_instance WHERE created_at > '$M_SAGA' AND state IN ('STARTED','CONFIRMING','COMPENSATING')"
}

# ── 0. preflight ────────────────────────────────────────────────────────────────
log "context=$CTX — checking the stack is up"
for d in order-service inventory-service product-service orchestrator-service payment-service; do
  kc -n apps rollout status "deploy/$d" --timeout=60s >/dev/null
done

# ── 1. high-water marks (per table, in that table's own clock) ──────────────────
mark() { sql "SELECT COALESCE(MAX($2), '1970-01-01') FROM $1"; }
M_ORDER="$(mark '`order`' created_at)"
M_SAGA="$(mark saga_instance created_at)"
M_PQH="$(mark product_quantity_history created_at)"
M_PPE="$(mark processed_payment_event processed_at)"
M_MONGO="$(mongo 'const d = db.productQuantityHistory.find({createdAt: {$exists: true}}).sort({createdAt: -1}).limit(1).toArray();
                  print(d.length ? d[0].createdAt.toISOString() : "1970-01-01T00:00:00Z")')"
DLT_BEFORE="$(dlt_records)"
log "marks: order>$M_ORDER saga>$M_SAGA ledger>$M_PQH inbox>$M_PPE mongo>$M_MONGO dlt=$DLT_BEFORE"

# ── 2. scale the consumers out ──────────────────────────────────────────────────
for spec in "${SCALE_OUT[@]}"; do
  svc="${spec%%:*}"; want="${spec##*:}"
  ORIGINAL_MIN[$svc]="$(kc -n apps get hpa "$svc" -o jsonpath='{.spec.minReplicas}')"
  kc -n apps patch hpa "$svc" --type merge -p "{\"spec\":{\"minReplicas\":$want}}" >/dev/null
done
for spec in "${SCALE_OUT[@]}"; do
  svc="${spec%%:*}"; want="${spec##*:}"
  for _ in $(seq 1 60); do
    ready="$(kc -n apps get deploy "$svc" -o jsonpath='{.status.readyReplicas}')"
    [[ "${ready:-0}" -ge "$want" ]] && break
    sleep 5
  done
  log "$svc ready replicas: ${ready:-0}/$want"
done

# ── 3. load + chaos ─────────────────────────────────────────────────────────────
kc -n apps delete job "$JOB" --ignore-not-found >/dev/null
kc -n apps create configmap k6-payment-script --from-file="$ROOT/deploy/k6-stress/payment-flow.js" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "$ROOT/deploy/k6-stress/payment-job.yaml" >/dev/null
log "k6 load started (ramp 1m → 50 VUs, hold 3m)"

kill_one() {   # delete one pod of a deployment without waiting — a crash, not a drain
  local pod
  pod="$(kc -n apps get pod -l "app.kubernetes.io/name=$1" -o jsonpath='{.items[0].metadata.name}')"
  kc -n apps delete pod "$pod" --wait=false --grace-period=0 --force >/dev/null 2>&1
  log "CHAOS killed $1 pod $pod"
}
(
  sleep 90;  kill_one order-service
  sleep 45;  kc -n apps rollout restart deploy/inventory-service >/dev/null; log "CHAOS rolling restart inventory-service"
  sleep 45;  kill_one orchestrator-service
  sleep 30;  kill_one product-service
) &
CHAOS_PID=$!

for _ in $(seq 1 120); do
  succeeded="$(kc -n apps get job "$JOB" -o jsonpath='{.status.succeeded}')"
  failed="$(kc -n apps get job "$JOB" -o jsonpath='{.status.failed}')"
  [[ -n "$succeeded" || -n "$failed" ]] && break
  sleep 5
done
wait "$CHAOS_PID" 2>/dev/null || true; CHAOS_PID=
K6_RESULT=$([[ -n "${succeeded:-}" ]] && echo "thresholds met" || echo "thresholds missed (expected under chaos)")
log "k6 finished: $K6_RESULT"

# ── 4. drain ────────────────────────────────────────────────────────────────────
log "draining (≤ ${DRAIN_TIMEOUT}s): consumer lag → 0 and no saga mid-transition"
deadline=$(( $(date +%s) + DRAIN_TIMEOUT ))
while :; do
  lag="$(total_lag)"; mid="$(mid_flight_sagas)"
  [[ "$lag" -eq 0 && "$mid" -eq 0 ]] && break
  if [[ $(date +%s) -ge $deadline ]]; then log "drain timed out: lag=$lag mid-flight sagas=$mid"; break; fi
  sleep 5
done

# ── 5. invariants ───────────────────────────────────────────────────────────────
rows=(); fails=0
check() {   # name expected actual why
  if [[ "$2" == "$3" ]]; then rows+=("PASS|$1|$3|$4"); else rows+=("FAIL|$1|expected $2, got $3|$4"); fails=$((fails + 1)); fi
}

ORDERS="$(sql "SELECT COUNT(*) FROM \`order\` WHERE created_at > '$M_ORDER'")"
COMPLETED="$(sql "SELECT COUNT(*) FROM \`order\` WHERE created_at > '$M_ORDER' AND status = 'COMPLETED'")"

check "orders created" "yes" "$([[ "$ORDERS" -gt 0 ]] && echo yes || echo "no ($ORDERS)")" \
      "the load must have produced orders, or every check below is vacuous"
check "every order got a saga" 0 \
      "$(sql "SELECT COUNT(*) FROM \`order\` o LEFT JOIN saga_instance s ON s.order_id = o.id WHERE o.created_at > '$M_ORDER' AND s.id IS NULL")" \
      "Order.Created lost between Mongo CDC and the orchestrator"
check "no saga stuck mid-transition" 0 "$(mid_flight_sagas)" \
      "a step's reply never arrived (lost message or unhandled redelivery)"
check "no saga FAILED" 0 \
      "$(sql "SELECT COUNT(*) FROM saga_instance WHERE created_at > '$M_SAGA' AND state = 'FAILED'")" \
      "the orchestrator could not get a compensation acknowledged"
check "saga outcome = order status" 0 \
      "$(sql "SELECT COUNT(*) FROM saga_instance s JOIN \`order\` o ON o.id = s.order_id WHERE s.created_at > '$M_SAGA' AND (
               (s.state = 'COMPLETED'   AND o.status <> 'COMPLETED')
            OR (s.state = 'COMPENSATED' AND o.status NOT IN ('FAILED','CANCELED'))
            OR (o.status = 'COMPLETED'  AND s.state <> 'COMPLETED'))")" \
      "a status reply was lost, applied twice, or applied out of order"
check "paid ⇒ order COMPLETED" 0 \
      "$(sql "SELECT COUNT(*) FROM payment p JOIN \`order\` o ON o.id = p.order_id WHERE o.created_at > '$M_ORDER' AND p.status = 'SUCCESS' AND o.status <> 'COMPLETED'")" \
      "money taken, order not completed"
check "stock applied once per paid order" "$COMPLETED" \
      "$(sql "SELECT COUNT(*) FROM processed_payment_event WHERE processed_at > '$M_PPE'")" \
      "inventory inbox rows vs COMPLETED orders: more = double decrement, fewer = missed"
check "ledger = units sold" \
      "$(sql "SELECT COALESCE(SUM(i.quantity), 0) FROM order_item i JOIN \`order\` o ON o.id = i.order_id WHERE o.created_at > '$M_ORDER' AND o.status = 'COMPLETED'")" \
      "$(sql "SELECT COALESCE(-SUM(quantity), 0) FROM product_quantity_history WHERE created_at > '$M_PQH' AND quantity < 0")" \
      "inventory ledger decrements vs order_item quantities of paid orders"
check "no negative stock" 0 "$(sql "SELECT COUNT(*) FROM inventory_product WHERE stock < 0")" \
      "oversell got past both the Redis gate and the DB floor"

INV_LEDGER="$(sql "SELECT CONCAT(COUNT(*), '/', COALESCE(SUM(quantity), 0)) FROM product_quantity_history WHERE created_at > '$M_PQH'")"
PROD_LEDGER="$(mongo "const r = db.productQuantityHistory.aggregate([{\$match: {createdAt: {\$gt: ISODate('$M_MONGO')}}},
                       {\$group: {_id: null, n: {\$sum: 1}, s: {\$sum: '\$quantity'}}}]).toArray();
                       print(r.length ? r[0].n + '/' + r[0].s : '0/0')")"
check "product ledger = inventory ledger (rows/sum)" "$INV_LEDGER" "$PROD_LEDGER" \
      "product-service history must mirror inventory's exactly once (source-event-id dedupe)"

for pid in "${PRODUCTS[@]}"; do
  stock="$(sql "SELECT COALESCE(stock, 0) FROM inventory_product WHERE id = '$pid'")"
  available="$(redis GET "productAvailable:$pid" | tr -d '"')"
  reserved="$(redis --raw ZRANGE pendingOrders 0 -1 | python3 -c '
import json, sys
pid, total = sys.argv[1], 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    member = json.loads(line)                       # template stores the member as a JSON string
    total += json.loads(member.split(":", 1)[1]).get("products", {}).get(pid, 0)
print(total)' "$pid")"
  check "redis available + reserved = stock (${pid: -4})" "${stock:-0}" "$(( ${available:-0} + reserved ))" \
        "the Redis gate must agree with the DB; a drift lets orders through that the DB will refuse"
done

check "nothing dead-lettered during the run" "$DLT_BEFORE" "$(dlt_records)" \
      "a record failed every retry — inspect the DLT, fix, then make dlt-replay"
check "consumer lag drained" 0 "$(total_lag)" "every consumer caught up after the chaos"

# ── 6. report ───────────────────────────────────────────────────────────────────
echo
echo "Kafka chaos proof — $ORDERS orders ($COMPLETED completed), k6 $K6_RESULT"
printf '%-5s %-46s %-28s %s\n' "" "invariant" "result" "what a failure means"
for r in "${rows[@]}"; do
  IFS='|' read -r status name result why <<<"$r"
  printf '%-5s %-46s %-28s %s\n' "$status" "$name" "$result" "$why"
done
echo
if [[ $fails -eq 0 ]]; then echo "${#rows[@]} passed, 0 failed -> PASS"; else echo "$(( ${#rows[@]} - fails )) passed, $fails failed -> FAIL"; fi
exit $(( fails > 0 ))
