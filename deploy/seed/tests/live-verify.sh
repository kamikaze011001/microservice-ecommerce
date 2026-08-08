#!/usr/bin/env bash
# Layer B — live state diff (compose + k8s). Proves the transports actually
# LAND the data, not just that the rendered artifacts are right (that's
# Layer A / equivalence-test.sh, which is offline). See
# docs/superpowers/specs/2026-08-08-canonical-seed-design.md §5 "Layer B"
# and §7's reset-scope risk.
#
#   ./deploy/seed/tests/live-verify.sh --env compose
#   ./deploy/seed/tests/live-verify.sh --env k8s --context <name>
#
# Sequence (both envs): flush the Redis productAvailable:* counters (so the
# "old way has no reconcile" check is measured against a genuinely empty set,
# not stale leftovers from a previous run) -> prove the non-empty guard
# actually fires against that empty set -> reset Mongo/MySQL to a clean slate
# -> seed the OLD way -> snapshot -> reset again -> seed the NEW way ->
# snapshot -> diff.
#
# CONTENT, NOT COUNTS: every table/collection is compared by a canonical
# content hash (sorted rows/docs, sha256), never a row count alone. Equal
# counts with a wrong image_url host is exactly the defect this phase
# removes — see design doc §5.
#
# THE VACUOUS-CHECK TRAP: an unauthenticated `redis-cli --scan` returns EMPTY
# rather than erroring, indistinguishable from "no keys exist". Every Redis
# read here checks PING == PONG first and fails LOUDLY (nonzero exit, not a
# silent empty result) if auth didn't happen — see redis_dump() below — and
# the non-empty guard is demonstrated to actually fire, not just asserted to
# exist, before it's relied on for the real comparison.
#
# CREDENTIAL HYGIENE mirrors deploy/scripts/seed.sh exactly: every password is
# read SERVER-SIDE from the container's own env (MYSQL_ROOT_PASSWORD /
# MONGO_INITDB_ROOT_PASSWORD / REDIS_PASSWORD, all already present in the
# compose containers per docker/*.yml) and never appears in this script's own
# argv, nor in `docker exec`'s host-side argv. k8s's redis has no password at
# all (k8s/infra/manifests/redis.yaml — LOCAL-DEV ONLY, no auth); k8s's
# mysql/mongo creds are read server-side the same way, from the pod's own env.
#
# RESET SCOPE (deliberately broader than the two Mongo collections named in
# the original k8s-cluster task-8-brief.md): drops product, api_role AND
# productQuantityHistory, and truncates every table the seed writes
# (inventory_product, product_quantity_history) plus the four ecommerce.sql
# populates (account, account_role, role, user). Dropping
# productQuantityHistory too — not just product/api_role — closes the same
# stale-collection hazard design doc §7 names for `product`: the new render's
# default mongoimport mode is --mode upsert (never drops), so a document that
# is not part of a fresh reset could survive across passes and bias the diff.
# Never `make k8s-nuke`, never a whole-database DROP (also sandbox-blocked).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
. "$ROOT/deploy/scripts/lib/colors.sh"

ENV_NAME=""
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

usage() {
  echo "usage: live-verify.sh --env compose|k8s [--context NAME]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env)     ENV_NAME="$2"; shift 2 ;;
    --context) KUBE_CONTEXT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$ENV_NAME" in
  compose|k8s) ;;
  *) usage; exit 2 ;;
esac

# Same guard as deploy/scripts/seed.sh: never infer which cluster kubectl
# happens to point at. --env compose never touches kubectl at all.
if [ "$ENV_NAME" = "k8s" ]; then
  if [ -z "$KUBE_CONTEXT" ]; then
    log_err "--env k8s needs an explicit context: pass --context NAME or set KUBE_CONTEXT"
    exit 1
  fi
  CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  if [ "$CURRENT_CONTEXT" != "$KUBE_CONTEXT" ]; then
    log_err "refusing to run: requested context '$KUBE_CONTEXT' but kubectl's current context is '${CURRENT_CONTEXT:-<none>}'"
    exit 1
  fi
fi

MYSQL_TABLES="account account_role role user inventory_product product_quantity_history"
MONGO_COLLECTIONS="product api_role productQuantityHistory"

NS=infra
case "$ENV_NAME" in
  compose)
    . "$ROOT/scripts/lib/env.sh"
    load_dotenv || exit 1
    MYSQL_DB="${MYSQL_DB_NAME:-ecommerce_dev}"
    MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql-master}"
    MONGO_DB="${MONGO_DB_NAME:-ecommerce_inventory}"
    MONGO_CONTAINER="${MONGO_CONTAINER:-ecommerce-mongodb}"
    REDIS_CONTAINER="${REDIS_CONTAINER:-docker-redis-ecommerce-1}"
    ;;
  k8s)
    MYSQL_DB="ecommerce_dev"
    MONGO_DB="ecommerce_inventory"
    ;;
esac

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ── MySQL ────────────────────────────────────────────────────────────────
# mysql_query: pipes a SQL statement on ITS OWN stdin to mysql, prints
# mysql's stdout (-N -B: no headers/borders, NULL renders as the literal
# text "NULL" in batch mode — deterministic, no ambiguity with a real value).
mysql_query() {
  local sql="$1"
  case "$ENV_NAME" in
    compose)
      printf '%s\n' "$sql" | docker exec -i "$MYSQL_CONTAINER" sh -c '
        set -e
        db="$1"
        : "${MYSQL_ROOT_PASSWORD:?missing in container env}"
        cfg="$(mktemp)"
        trap "rm -f \"$cfg\"" EXIT
        printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASSWORD" > "$cfg"
        mysql --defaults-extra-file="$cfg" -N -B "$db"
      ' sh "$MYSQL_DB"
      ;;
    k8s)
      printf '%s\n' "$sql" | kubectl --context "$KUBE_CONTEXT" -n "$NS" exec -i mysql-0 -- sh -c '
        set -e
        db="$1"
        : "${MYSQL_ROOT_PASSWORD:?missing in container env}"
        cfg="$(mktemp)"
        trap "rm -f \"$cfg\"" EXIT
        printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASSWORD" > "$cfg"
        mysql --defaults-extra-file="$cfg" -N -B "$db"
      ' sh "$MYSQL_DB"
      ;;
  esac
}

# ── Mongo ────────────────────────────────────────────────────────────────
# mongo_docs: one Extended-JSON document per line, sorted by _id server-side
# (client-side sort on the dumped text below is the real ordering guarantee).
mongo_docs() {
  local coll="$1"
  case "$ENV_NAME" in
    compose)
      docker exec "$MONGO_CONTAINER" sh -c '
        set -e
        coll="$1"; db="$2"
        : "${MONGO_INITDB_ROOT_USERNAME:?missing in container env}"
        : "${MONGO_INITDB_ROOT_PASSWORD:?missing in container env}"
        mongosh --quiet --authenticationDatabase admin \
          -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" "$db" --eval "
            db.getCollection(\"$coll\").find().sort({_id:1}).forEach(function(d){print(EJSON.stringify(d));});
          "
      ' sh "$coll" "$MONGO_DB"
      ;;
    k8s)
      # UNLIKE compose's mongo container, NO credential env var exists in the
      # k8s mongodb pod at all (k8s/CLAUDE.md's Bitnami-migration SCAR: the
      # bootstrap sidecar's creds are literals inside its own inline script,
      # never exported) -- confirmed already by deploy/scripts/seed.sh's own
      # header comment for its k8s/aws mongo leg. Same known-fixed dev creds
      # seed.sh uses there (MONGO_USERNAME/MONGO_PASSWORD, matching compose's
      # own defaults), travelling as the FIRST LINE of the exec's stdin
      # stream (data, not argv) so it never appears in mongosh's own argv
      # (readable container-side via /proc/<pid>/cmdline) -- then handed to
      # mongosh via an exported env var (Mongo(process.env.MONGO_URI)),
      # never a CLI argument, identical rationale to seed.sh's --config=
      # technique for mongoimport (which has no equivalent flag for mongosh).
      local user="${MONGO_USERNAME:-ecommerce}" pass="${MONGO_PASSWORD:-ecommerce123}"
      printf '%s\n' "mongodb://${user}:${pass}@127.0.0.1:27017/admin?authSource=admin" \
        | kubectl --context "$KUBE_CONTEXT" -n "$NS" exec -i mongodb-0 -- sh -c '
            set -e
            coll="$1"; db="$2"
            IFS= read -r MONGO_URI
            export MONGO_URI
            mongosh --quiet --eval "
              var db = Mongo(process.env.MONGO_URI).getDB(\"$db\");
              db.getCollection(\"$coll\").find().sort({_id:1}).forEach(function(d){print(EJSON.stringify(d));});
            "
          ' sh "$coll" "$MONGO_DB"
      ;;
  esac
}

mongo_drop() {
  local coll="$1"
  case "$ENV_NAME" in
    compose)
      docker exec "$MONGO_CONTAINER" sh -c '
        set -e
        coll="$1"; db="$2"
        : "${MONGO_INITDB_ROOT_USERNAME:?missing in container env}"
        : "${MONGO_INITDB_ROOT_PASSWORD:?missing in container env}"
        mongosh --quiet --authenticationDatabase admin \
          -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" "$db" --eval "
            db.getCollection(\"$coll\").drop();
          " >/dev/null
      ' sh "$coll" "$MONGO_DB"
      ;;
    k8s)
      # Same stdin-URI / env-var technique as mongo_docs's k8s branch above.
      local user="${MONGO_USERNAME:-ecommerce}" pass="${MONGO_PASSWORD:-ecommerce123}"
      printf '%s\n' "mongodb://${user}:${pass}@127.0.0.1:27017/admin?authSource=admin" \
        | kubectl --context "$KUBE_CONTEXT" -n "$NS" exec -i mongodb-0 -- sh -c '
            set -e
            coll="$1"; db="$2"
            IFS= read -r MONGO_URI
            export MONGO_URI
            mongosh --quiet --eval "
              var db = Mongo(process.env.MONGO_URI).getDB(\"$db\");
              db.getCollection(\"$coll\").drop();
            " >/dev/null
          ' sh "$coll" "$MONGO_DB"
      ;;
  esac
}

# ── Redis ────────────────────────────────────────────────────────────────
# redis_dump: prints AUTH_OK on its own first line, then one "key<TAB>value"
# line per productAvailable:* key. Fails LOUDLY (nonzero rc, nothing useful
# on stdout) if PING doesn't come back PONG — the whole point being that a
# caller can never mistake "auth failed" for "zero keys exist".
redis_dump() {
  case "$ENV_NAME" in
    compose)
      docker exec "$REDIS_CONTAINER" sh -c '
        set -e
        : "${REDIS_PASSWORD:?missing in container env}"
        pong="$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null)"
        if [ "$pong" != "PONG" ]; then
          echo "redis auth/connect failed (PING != PONG)" >&2
          exit 3
        fi
        echo "AUTH_OK"
        redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan --pattern "productAvailable:*" | while read -r k; do
          [ -n "$k" ] || continue
          v="$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning GET "$k")"
          printf "%s\t%s\n" "$k" "$v"
        done
      '
      ;;
    k8s)
      # k8s/infra/manifests/redis.yaml: LOCAL-DEV ONLY, no password, plain
      # Deployment (not a StatefulSet) — pod name is not fixed, resolve by
      # label. PING still confirms reachability so a silent-empty scan can
      # never be mistaken for zero keys.
      local pod
      pod="$(kubectl --context "$KUBE_CONTEXT" -n "$NS" get pod -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
      if [ -z "$pod" ]; then
        echo "no redis pod found (label app.kubernetes.io/name=redis, ns $NS)" >&2
        return 3
      fi
      kubectl --context "$KUBE_CONTEXT" -n "$NS" exec "$pod" -- sh -c '
        set -e
        pong="$(redis-cli PING 2>/dev/null)"
        if [ "$pong" != "PONG" ]; then
          echo "redis connect failed (PING != PONG)" >&2
          exit 3
        fi
        echo "AUTH_OK"
        redis-cli --scan --pattern "productAvailable:*" | while read -r k; do
          [ -n "$k" ] || continue
          v="$(redis-cli GET "$k")"
          printf "%s\t%s\n" "$k" "$v"
        done
      '
      ;;
  esac
}

# read_redis_state <outfile>: writes "key<TAB>value" lines (no AUTH_OK
# marker) to $1. Returns nonzero WITHOUT writing anything usable if auth
# failed — callers must check the return code, never just "file is empty".
read_redis_state() {
  local outfile="$1" raw errfile
  raw="$(mktemp)"; errfile="$(mktemp)"
  if ! redis_dump >"$raw" 2>"$errfile"; then
    log_err "redis: $(cat "$errfile")"
    rm -f "$raw" "$errfile"
    return 2
  fi
  if [ "$(head -1 "$raw")" != "AUTH_OK" ]; then
    log_err "redis: response did not start with AUTH_OK — refusing to treat this as a verified empty result"
    rm -f "$raw" "$errfile"
    return 2
  fi
  tail -n +2 "$raw" > "$outfile"
  rm -f "$raw" "$errfile"
  return 0
}

# assert_nonempty_counters <keyvalue-file> <label>: THE guard. Refuses to
# trust a sum computed over zero counters — "all found counters sum
# correctly" is trivially true over an empty set. This function is what
# gets demonstrated firing, below, before it's relied on for real.
assert_nonempty_counters() {
  local file="$1" label="$2" n
  n=$(wc -l < "$file" | tr -d '[:space:]')
  if [ "${n:-0}" -eq 0 ]; then
    log_err "$label: 0 productAvailable:* keys found — refusing to sum an empty counter set (this is the guard the brief calls out; see live-verify.sh's assert_nonempty_counters)"
    return 1
  fi
  return 0
}

flush_redis_counters() {
  case "$ENV_NAME" in
    compose)
      docker exec "$REDIS_CONTAINER" sh -c '
        set -e
        : "${REDIS_PASSWORD:?missing in container env}"
        redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan --pattern "productAvailable:*" | while read -r k; do
          [ -n "$k" ] && redis-cli -a "$REDIS_PASSWORD" --no-auth-warning DEL "$k" >/dev/null
        done
      '
      ;;
    k8s)
      local pod
      pod="$(kubectl --context "$KUBE_CONTEXT" -n "$NS" get pod -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}')"
      kubectl --context "$KUBE_CONTEXT" -n "$NS" exec "$pod" -- sh -c '
        set -e
        redis-cli --scan --pattern "productAvailable:*" | while read -r k; do
          [ -n "$k" ] && redis-cli DEL "$k" >/dev/null
        done
      '
      ;;
  esac
}

# ── reset (scoped — see header) ─────────────────────────────────────────
reset_state() {
  log_info "reset: dropping mongo product/api_role/productQuantityHistory"
  for c in $MONGO_COLLECTIONS; do mongo_drop "$c"; done

  log_info "reset: truncating mysql account_role/account/role/user/inventory_product/product_quantity_history"
  mysql_query "
    SET FOREIGN_KEY_CHECKS=0;
    TRUNCATE TABLE account_role;
    TRUNCATE TABLE account;
    TRUNCATE TABLE role;
    TRUNCATE TABLE \`user\`;
    TRUNCATE TABLE inventory_product;
    TRUNCATE TABLE product_quantity_history;
    SET FOREIGN_KEY_CHECKS=1;
  " >/dev/null
}

# ── seeding ──────────────────────────────────────────────────────────────
run_old_way() {
  case "$ENV_NAME" in
    compose)
      # The real old invocation — scripts/seed/all.sh runs every per-domain
      # script in order (mysql.sh, mongo-roles.sh, minio-product-images.sh,
      # mongo-products.sh, mongo-product-quantity.sh,
      # mysql-inventory-products.sh, mysql-product-quantity-history.sh). No
      # reconcile step exists anywhere in scripts/seed/ — that absence is the
      # declared asymmetry this test measures, not a bug in this test.
      bash "$ROOT/scripts/seed/all.sh"
      ;;
    k8s)
      # NOT RUN by this task (scope decision: no live cluster). Written so
      # the k8s leg is complete and ready. Mirrors the OLD k8s bootstrap
      # order from the Makefile: k8s-seed (mongo, among other idempotent
      # jobs) + k8s-seed-images pre-apps; k8s-seed-mysql + k8s-seed-inventory
      # post-apps. Unlike compose, k8s's old path ALREADY restarts
      # inventory-service (scripts/seed/k8s-inventory.sh) — so k8s has no
      # declared reconcile asymmetry; both ways are expected to leave Redis
      # counters present. See design doc's DECLARED table (only
      # compose/drop and compose/reconcile are listed).
      make -C "$ROOT" k8s-seed
      make -C "$ROOT" k8s-seed-images
      make -C "$ROOT" k8s-seed-mysql
      make -C "$ROOT" k8s-seed-inventory
      ;;
  esac
}

run_new_way() {
  case "$ENV_NAME" in
    compose)
      bash "$ROOT/deploy/scripts/seed.sh" --env compose --stage pre-apps
      bash "$ROOT/deploy/scripts/seed.sh" --env compose --stage post-apps
      ;;
    k8s)
      # NOT RUN by this task — see run_old_way's k8s comment.
      bash "$ROOT/deploy/scripts/seed.sh" --env k8s --stage pre-apps --context "$KUBE_CONTEXT"
      bash "$ROOT/deploy/scripts/seed.sh" --env k8s --stage post-apps --context "$KUBE_CONTEXT"
      ;;
  esac
}

# ── snapshot + hash ──────────────────────────────────────────────────────
# capture_snapshot <label>: dumps every mysql table and mongo collection to
# $WORKDIR/<label>.mysql.<table> / $WORKDIR/<label>.mongo.<coll>, then hashes
# them into $WORKDIR/<label>.json via python (canonicalizes row/doc order so
# import-order never masquerades as a content diff — same reasoning as
# equivalence-test.sh's canon()).
#
# inventory_product is special-cased to the SEED columns only (id, name,
# price, image_url) — its `stock` column is NOT part of any INSERT the seed
# renders; it is backfilled separately by inventory-service's
# AvailableStockSeeder ApplicationRunner (a native UPDATE ... SET stock =
# GREATEST(0, COALESCE(SUM(product_quantity_history.quantity), 0))) at boot,
# the SAME reconcile that rebuilds the Redis productAvailable:* counters —
# discovered live during Task 8 verification (see task-8-report.md): a
# first `SELECT *` run over inventory_product produced a false-looking
# content mismatch that was actually this second, MySQL-side effect of the
# very reconcile step being tested, not a seed defect. It gets its own
# declared-asymmetry check (see step 8) exactly like the Redis counters do.
capture_snapshot() {
  local label="$1" t c
  for t in $MYSQL_TABLES; do
    if [ "$t" = "inventory_product" ]; then
      mysql_query "SELECT id, name, price, image_url FROM inventory_product;" > "$WORKDIR/$label.mysql.$t"
    else
      mysql_query "SELECT * FROM \`$t\`;" > "$WORKDIR/$label.mysql.$t"
    fi
  done
  mysql_query "SELECT id, stock FROM inventory_product;" > "$WORKDIR/$label.stock"
  for c in $MONGO_COLLECTIONS; do
    mongo_docs "$c" > "$WORKDIR/$label.mongo.$c"
  done

  python3 - "$WORKDIR" "$label" "$MYSQL_TABLES" "$MONGO_COLLECTIONS" <<'PY'
import hashlib, json, sys, pathlib

workdir, label, mysql_tables, mongo_colls = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4].split()
wd = pathlib.Path(workdir)
snap = {"mysql": {}, "mongo": {}}

for t in mysql_tables:
    lines = [l for l in (wd / f"{label}.mysql.{t}").read_text().splitlines() if l != ""]
    lines.sort()
    h = hashlib.sha256("\n".join(lines).encode()).hexdigest()
    snap["mysql"][t] = {"rows": len(lines), "hash": h}

for c in mongo_colls:
    raw = [l for l in (wd / f"{label}.mongo.{c}").read_text().splitlines() if l.strip() != ""]
    docs = []
    for l in raw:
        try:
            docs.append(json.loads(l))
        except json.JSONDecodeError as e:
            print(f"FAIL: {label}/{c} produced a non-JSON line: {l!r} ({e})", file=sys.stderr)
            sys.exit(1)
    canon = sorted(json.dumps(d, sort_keys=True) for d in docs)
    h = hashlib.sha256("\n".join(canon).encode()).hexdigest()
    snap["mongo"][c] = {"docs": len(docs), "hash": h}

(wd / f"{label}.json").write_text(json.dumps(snap))
PY
}

diff_snapshots() {
  local old_label="$1" new_label="$2"
  python3 - "$WORKDIR/$old_label.json" "$WORKDIR/$new_label.json" <<'PY'
import json, sys

old = json.loads(open(sys.argv[1]).read())
new = json.loads(open(sys.argv[2]).read())

fail = False
for domain in ("mysql", "mongo"):
    for key in sorted(set(old[domain]) | set(new[domain])):
        o, n = old[domain].get(key), new[domain].get(key)
        if o is None or n is None:
            print(f"FAIL {domain}/{key}: missing from one side (old={o}, new={n})")
            fail = True
            continue
        count_key = "rows" if domain == "mysql" else "docs"
        if o["hash"] == n["hash"] and o[count_key] == n[count_key]:
            print(f"ok   {domain}/{key}: {o[count_key]} {count_key}, hash matches ({o['hash'][:12]}...)")
        else:
            print(f"FAIL {domain}/{key}: old={o[count_key]} {count_key} hash={o['hash'][:12]}... "
                  f"new={n[count_key]} {count_key} hash={n['hash'][:12]}... — content differs")
            fail = True

sys.exit(1 if fail else 0)
PY
}

# ── main ─────────────────────────────────────────────────────────────────
echo
echo -e "\033[1mlive-verify — $ENV_NAME\033[0m"

if [ "$ENV_NAME" = "k8s" ]; then
  log_err "the k8s leg is written but this run target is compose-only in this environment (no live cluster) — refusing to proceed"
  log_err "if a cluster exists, re-run with --context <name>; the k8s functions above are otherwise untested"
  exit 1
fi

FAIL=0

log_info "step 1/8: flush Redis productAvailable:* (so the old-way check starts from a genuinely empty set)"
flush_redis_counters

log_info "step 2/8: demonstrate the non-empty guard actually fires against the now-empty set"
DEMO_FILE="$WORKDIR/redis.guard-demo"
if read_redis_state "$DEMO_FILE"; then
  if assert_nonempty_counters "$DEMO_FILE" "guard-demo"; then
    log_err "guard demo FAILED: expected assert_nonempty_counters to refuse an empty set, but it accepted it"
    exit 1
  else
    log_ok "guard demo PASSED: assert_nonempty_counters correctly refused 0 keys (error line above is the guard firing, not a real failure)"
  fi
else
  log_err "guard demo FAILED: could not even read Redis state (auth/connect problem) — see error above"
  exit 1
fi

log_info "step 3/8: reset (clean slate) + seed OLD way"
reset_state
run_old_way
capture_snapshot old
OLD_REDIS="$WORKDIR/redis.old"
read_redis_state "$OLD_REDIS" || { log_err "could not read redis state after old-way seed"; exit 1; }
OLD_REDIS_COUNT=$(wc -l < "$OLD_REDIS" | tr -d '[:space:]')
OLD_REDIS_SUM=$(awk -F'\t' '{s+=$2} END{print s+0}' "$OLD_REDIS")
log_info "old-way redis: $OLD_REDIS_COUNT productAvailable:* keys, sum=$OLD_REDIS_SUM"

log_info "step 4/8: reset (clean slate) + seed NEW way"
reset_state
run_new_way
capture_snapshot new
NEW_REDIS="$WORKDIR/redis.new"
read_redis_state "$NEW_REDIS" || { log_err "could not read redis state after new-way seed"; exit 1; }
NEW_REDIS_COUNT=$(wc -l < "$NEW_REDIS" | tr -d '[:space:]')
NEW_REDIS_SUM=$(awk -F'\t' '{s+=$2} END{print s+0}' "$NEW_REDIS")
log_info "new-way redis: $NEW_REDIS_COUNT productAvailable:* keys, sum=$NEW_REDIS_SUM"

log_info "step 5/8: diff MySQL/Mongo content hashes (old way vs new way)"
if ! diff_snapshots old new; then
  FAIL=1
fi

log_info "step 6/8: per-product Redis check against the freshly-seeded ledger (new way)"
# Brief's exact requirement: for every productId with a nonzero ledger,
# productAvailable:{productId} EXISTS and the total matches
# SUM(product_quantity_history.quantity). Checked per-key, not just in
# aggregate, so a compensating error (one key short, another key long)
# can't hide behind a matching total.
LEDGER="$WORKDIR/ledger.tsv"
mysql_query "SELECT product_id, SUM(quantity) FROM product_quantity_history GROUP BY product_id;" > "$LEDGER"
if assert_nonempty_counters "$NEW_REDIS" "new-way (post reconcile)"; then
  python3 - "$LEDGER" "$NEW_REDIS" <<'PY'
import sys

ledger = {}
with open(sys.argv[1]) as f:
    for line in f:
        pid, total = line.rstrip("\n").split("\t")
        total = int(total)
        if total != 0:
            ledger[pid] = total

redis = {}
with open(sys.argv[2]) as f:
    for line in f:
        k, v = line.rstrip("\n").split("\t")
        pid = k[len("productAvailable:"):]
        redis[pid] = int(v)

expected_ids = set(ledger)
actual_ids = set(redis)
problems = []
if expected_ids != actual_ids:
    missing = expected_ids - actual_ids
    extra = actual_ids - expected_ids
    if missing:
        problems.append(f"{len(missing)} product(s) with nonzero ledger have NO productAvailable key: {sorted(missing)[:5]}")
    if extra:
        problems.append(f"{len(extra)} productAvailable key(s) have no matching nonzero ledger row: {sorted(extra)[:5]}")
mismatched = [pid for pid in (expected_ids & actual_ids) if ledger[pid] != redis[pid]]
if mismatched:
    problems.append(f"{len(mismatched)} product(s) where redis value != ledger sum: {mismatched[:5]}")

ledger_sum = sum(ledger.values())
redis_sum = sum(redis.values())
if ledger_sum != redis_sum:
    problems.append(f"total mismatch: ledger sum={ledger_sum} redis sum={redis_sum}")

print(f"ledger: {len(ledger)} products with nonzero quantity, sum={ledger_sum}")
print(f"redis:  {len(redis)} productAvailable:* keys, sum={redis_sum}")
if problems:
    for p in problems:
        print(f"FAIL {p}")
    sys.exit(1)
print(f"ok   every nonzero-ledger product has a matching productAvailable key, all values equal, sums match ({ledger_sum})")
PY
  if [ $? -ne 0 ]; then FAIL=1; fi
else
  FAIL=1
fi

log_info "step 7/8: the declared asymmetry (design doc §D3) — compose's OLD path has no reconcile"
# Mirrors deploy/seed/tests/equivalence-test.sh's DECLARED-difference
# handling: assert the difference in the STATED DIRECTION, and FAIL if it
# ever disappears (either direction) rather than silently accepting
# whatever the two sides happen to produce.
if [ "$OLD_REDIS_COUNT" -eq 0 ] && [ "$NEW_REDIS_COUNT" -gt 0 ]; then
  echo "declared-different: compose/redis-reconcile   old=absent(0 keys) -> new=present($NEW_REDIS_COUNT keys, sum=$NEW_REDIS_SUM)"
elif [ "$OLD_REDIS_COUNT" -gt 0 ]; then
  log_err "regression: declared to differ (old: absent) but the OLD path now also produced $OLD_REDIS_COUNT counters — the compose 'no reconcile' asymmetry (design doc §D3) may have been fixed upstream without updating this declaration; verify scripts/seed/all.sh wasn't changed to restart inventory-service"
  FAIL=1
else
  log_err "declared entry doesn't match reality: old_count=$OLD_REDIS_COUNT new_count=$NEW_REDIS_COUNT (expected old=0, new>0)"
  FAIL=1
fi

log_info "step 8/8: second declared asymmetry — inventory_product.stock, backfilled by the SAME reconcile"
# Discovered live (not anticipated by the brief): AvailableStockSeeder's
# ApplicationRunner backfills MySQL inventory_product.stock via
# GREATEST(0, COALESCE(SUM(product_quantity_history.quantity), 0)) at
# inventory-service boot -- the exact same reconcile trigger that rebuilds
# the Redis counters (step 7), just writing to a second place. Old way never
# restarts inventory-service, so `stock` stays at its INSERT-time value:
# the column is nullable with no DEFAULT, and the seed INSERT never mentions
# it, so it lands NULL for every row. New way's restart backfills it to
# match the ledger. Same declared-difference contract as step 7: assert the
# direction, fail if it ever reverses.
python3 - "$WORKDIR/old.stock" "$WORKDIR/new.stock" "$LEDGER" <<'PY'
import sys

def read_stock(path):
    out = {}
    with open(path) as f:
        for line in f:
            pid, val = line.rstrip("\n").split("\t")
            out[pid] = val
    return out

def read_ledger(path):
    out = {}
    with open(path) as f:
        for line in f:
            pid, total = line.rstrip("\n").split("\t")
            out[pid] = int(total)
    return out

old_stock = read_stock(sys.argv[1])
new_stock = read_stock(sys.argv[2])
ledger = read_ledger(sys.argv[3])

problems = []

non_null_old = {pid: v for pid, v in old_stock.items() if v != "NULL"}
if non_null_old:
    problems.append(f"regression: declared to differ (old: stock IS NULL for every row) but {len(non_null_old)} row(s) are non-NULL after the OLD-way seed: {list(non_null_old.items())[:5]}")

expected_new = {pid: str(max(0, ledger.get(pid, 0))) for pid in old_stock}
mismatched_new = {pid: (new_stock.get(pid), expected_new[pid])
                   for pid in expected_new if new_stock.get(pid) != expected_new[pid]}
if mismatched_new:
    problems.append(f"new-way stock doesn't match GREATEST(0, ledger sum) for {len(mismatched_new)} product(s): {list(mismatched_new.items())[:5]}")

print(f"old: {len(old_stock)} rows, {len(non_null_old)} non-NULL (want 0)")
print(f"new: {len(new_stock)} rows, {len(mismatched_new)} mismatched vs GREATEST(0, ledger sum) (want 0)")
if problems:
    for p in problems:
        print(f"FAIL {p}")
    sys.exit(1)
print(f"declared-different: compose/inventory_product.stock   old=NULL (all {len(old_stock)} rows) -> new=matches GREATEST(0, ledger sum) (all {len(new_stock)} rows)")
PY
if [ $? -ne 0 ]; then FAIL=1; fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}PASS${NC} — mysql/mongo seed content identical old vs new; redis counters + inventory_product.stock both absent/NULL old, present+correct new (578 across 27 keys, as documented)"
else
  echo -e "${RED}FAIL${NC} — see above"
fi

exit "$FAIL"
