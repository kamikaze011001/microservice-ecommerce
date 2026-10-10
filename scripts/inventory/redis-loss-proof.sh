#!/usr/bin/env bash
# Does a Redis restart lose paid orders' stock decrements?
#
#   CONTEXT=microecom scripts/inventory/redis-loss-proof.sh preview-<name> [orders]
#   (make inventory-redis-loss-proof env=preview-<name>)
#
# Runs against a devbox PREVIEW env (make devbox-env-create): it has its own
# Redis, so wiping it can't touch prod-like. The window the Kafka chaos run hit
# by accident, reproduced on purpose:
#   1. create N orders AND their payments  — lines + price sit in Redis
#   2. FLUSHALL the env's Redis            — what a Redis restart does
#   3. approve every payment (mock PayPal) — inventory must still decrement
# (Flushing BEFORE the payment is created is a different, loud failure:
# payment-service reads the order total from the same index and answers 400.)
# Then PASS/FAIL on: all orders COMPLETED, ledger units == units sold, stock
# dropped by units sold, inbox rows == orders paid. Exit 1 on any FAIL.
set -euo pipefail

ENV_NAME=${1:?usage: redis-loss-proof.sh preview-<name> [orders]}
N=${2:-12}
: "${CONTEXT:?set CONTEXT (e.g. microecom)}"
case "$CONTEXT" in *eks*) echo "refusing an EKS context" >&2; exit 1 ;; esac
[[ "$ENV_NAME" == preview-* ]] || { echo "only preview envs (it wipes the env's Redis)" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K="kubectl --context $CONTEXT"
eval "$(python3 "$ROOT/deploy/devbox/lib/env_gen.py" names --env "$ENV_NAME" | jq -r \
  '"NS=\(.namespace) DB=\(.mysqlDb) API=http://\(.apiHost)"')"

sql() { $K -n infra exec -i mysql-0 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B 2>/dev/null' <<<"$1"; }
snapshot() {
  sql "SELECT
         (SELECT COALESCE(SUM(stock),0) FROM \`$DB\`.inventory_product),
         (SELECT COALESCE(SUM(-quantity),0) FROM \`$DB\`.product_quantity_history WHERE quantity < 0),
         (SELECT COUNT(*) FROM \`$DB\`.processed_payment_event)"
}

$K get ns "$NS" >/dev/null 2>&1 || { echo "no namespace $NS — make devbox-env-create name=${ENV_NAME#preview-}" >&2; exit 1; }
read -r STOCK0 LEDGER0 INBOX0 <<<"$(snapshot)"
echo "before: stock=$STOCK0 ledger_units=$LEDGER0 inbox_rows=$INBOX0"

# In-cluster client: same gateway the env's browser traffic uses.
client() {
  $K -n "$NS" run "redis-loss-$1-$(date +%s)" --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet \
    --env="B=http://gateway:6868" --env="API=$API" --env="N=$N" -- sh -s
}
LOGIN='T=$(curl -s -X POST -H "content-type: application/json" -d "{\"username\":\"perftest_user_100\",\"password\":\"Test@123456\"}" $B/authorization-server/v1/auth:login | sed -n "s/.*\"access_token\":\"\([^\"]*\)\".*/\1/p")
[ -n "$T" ] || { echo "LOGIN_FAILED"; exit 1; }'

echo "1/3 creating $N orders + their payments"
CREATED_OUT="$(client create <<EOF
$LOGIN
P1=67c000000000000000000001; P2=67c000000000000000000002; P3=67c000000000000000000003
i=0; while [ \$i -lt \$N ]; do
  case \$((i % 3)) in 0) P=\$P1;; 1) P=\$P2;; *) P=\$P3;; esac
  O=\$(curl -s -X POST -H "content-type: application/json" -H "Authorization: Bearer \$T" \
    -d "{\"address\":\"redis loss proof\",\"phone_number\":\"0912345678\",\"items\":[{\"product_id\":\"\$P\",\"quantity\":1}]}" \
    \$B/order-service/v1/orders | sed -n 's/.*"order_id":"\([^"]*\)".*/\1/p')
  i=\$((i+1))
  [ -n "\$O" ] || continue
  HREF=\$(curl -s -X POST -H "Authorization: Bearer \$T" "\$B/payment-service/v1/payments?orderId=\$O" \
    | tr '{' '\n' | grep -E '"rel":"(approve|payer-action)"' | sed -n 's/.*"href":"\([^"]*\)".*/\1/p' | head -1)
  [ -n "\$HREF" ] && echo "ORDER \$O \$HREF"
done
EOF
)"
ORDERS="$(grep -E '^ORDER ' <<<"$CREATED_OUT" | awk '{print $2}' || true)"
LINKS="$(grep -E '^ORDER ' <<<"$CREATED_OUT" | awk '{print $3}' || true)"
CREATED=$(wc -w <<<"$ORDERS" | tr -d ' ')
echo "    created $CREATED (each with a pending payment)"
[[ "$CREATED" -gt 0 ]] || { echo "no orders created:" >&2; head -5 <<<"$CREATED_OUT" >&2; exit 1; }

echo "2/3 wiping $ENV_NAME's Redis (FLUSHALL) — the pending-order index is gone"
$K -n "$NS" exec deploy/redis -- redis-cli FLUSHALL >/dev/null

echo "3/3 approving every payment through the mock PayPal"
# Follow the 302 chain, rewriting the env's ingress host to the gateway at each
# hop; stop at the SPA host (browser-only) — by then the callback has run.
PAID_OUT="$(client pay <<EOF
for HREF in $(echo $LINKS); do
  URL="\$(echo "\$HREF" | sed "s#^\$API#\$B#")"
  case "\$URL" in *\?*) URL="\$URL&decision=approve";; *) URL="\$URL?decision=approve";; esac
  hops=0
  while [ \$hops -lt 5 ]; do
    LOC=\$(curl -s -o /dev/null -w '%{redirect_url}' "\$URL")
    case "\$LOC" in "\$API"*) URL="\$(echo "\$LOC" | sed "s#^\$API#\$B#")"; hops=\$((hops+1));; *) break;; esac
  done
  echo "APPROVED hops=\$hops"
done
EOF
)"
echo "    approved $(grep -c '^APPROVED' <<<"$PAID_OUT" || true)"

IDS="$(sed "s/[^ ][^ ]*/'&'/g; s/ /,/g" <<<"$(echo $ORDERS)")"
echo "    waiting for the saga to settle"
for _ in $(seq 1 36); do
  left=$(sql "SELECT COUNT(*) FROM \`$DB\`.\`order\` WHERE id IN ($IDS) AND status = 'PROCESSING'")
  [[ "$left" == 0 ]] && break
  sleep 5
done

read -r STOCK1 LEDGER1 INBOX1 <<<"$(snapshot)"
DONE=$(sql "SELECT COUNT(*) FROM \`$DB\`.\`order\` WHERE id IN ($IDS) AND status = 'COMPLETED'")
UNITS=$(sql "SELECT COALESCE(SUM(oi.quantity),0) FROM \`$DB\`.order_item oi JOIN \`$DB\`.\`order\` o ON o.id = oi.order_id
             WHERE o.id IN ($IDS) AND o.status = 'COMPLETED'")
echo "after:  stock=$STOCK1 ledger_units=$LEDGER1 inbox_rows=$INBOX1   completed=$DONE/$CREATED units_sold=$UNITS"

# The wipe also took the available-stock counters; inventory-service rebuilds
# them on boot — without this the env refuses every new order (and a re-run).
$K -n "$NS" rollout restart deploy/inventory-service >/dev/null
$K -n "$NS" rollout status deploy/inventory-service --timeout=300s >/dev/null

fail=0
check() { if eval "$2"; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; fi; }
echo
check "every order completed ($DONE/$CREATED)"                           "(( DONE == CREATED ))"
check "ledger recorded every unit sold ($((LEDGER1 - LEDGER0)) of $UNITS)" "(( LEDGER1 - LEDGER0 == UNITS ))"
check "stock dropped by every unit sold ($((STOCK0 - STOCK1)) of $UNITS)"  "(( STOCK0 - STOCK1 == UNITS ))"
check "inbox rows == payments applied ($((INBOX1 - INBOX0)) of $DONE)"    "(( INBOX1 - INBOX0 == DONE ))"
echo
exit "$fail"
