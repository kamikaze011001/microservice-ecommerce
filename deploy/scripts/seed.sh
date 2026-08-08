#!/usr/bin/env bash
# Resolve deploy/seed/ (+ an env context) and push the seed artifacts to this
# env's backend, in one of two stages.
#
#   deploy/scripts/seed.sh --env compose|k8s|aws --stage pre-apps|post-apps
#                          [--dry-run] [--replace] [--context NAME]
#                          [--tf-outputs FILE]
#
# PRE-APPS (Phase 5 Task 5): mongo (api_role/product/productQuantityHistory)
# + objects (product images). Must run before the apps so product-service /
# inventory-service have data to react to.
#
# POST-APPS (Phase 5 Task 6, this addition): the schema precondition, then
# ecommerce.sql (account/account_role/role/user), then the derived
# inventory_product/product_quantity_history rows, then the reconcile —
# `kubectl rollout restart deploy/inventory-service` on k8s/aws, `stop.sh` +
# `start.sh inventory-service` on compose (compose has no container to
# restart; the services are JVM processes — see design doc §D3). Must run
# AFTER the apps: ecommerce.sql is data-only (0 CREATE TABLE — its only
# "localhost" is an inert mysqldump header comment, do not "fix" it), so the
# schema must already exist via Hibernate ddl-auto or the import dies
# mid-way with ERROR 1146 (the failure mode k8s/CLAUDE.md documents). The
# precondition below checks every table an INSERT targets and refuses before
# writing a single row if any is missing.
#
# Same resolve-then-transport ordering as secrets-seed.sh: render the FULL
# artifact set first (deploy/scripts/lib/seed_render.py::render_all — pure,
# no network), and only start writing once every artifact resolved. A render
# failure prints nothing on the renderer's stdout and this script exits before
# touching any backend — see seed_render.py's own docstring for why.
#
# --replace opts into mongo-products.sh's / mongo-product-quantity.sh's OLD
# compose behaviour of DROPPING the product / productQuantityHistory
# collections before import (render_all's "drop" key; empty by default for
# every env). Default behaviour is `mongoimport --mode upsert` (matches on
# _id, never drops the collection), so a plain re-run never silently wipes a
# locally-added product — see design doc §7 and the Makefile's
# mongo-seed-ensure comment, which documents the old drop as the reason
# mongo-products.sh is excluded from `make up`. --replace is a pre-apps-only
# concept (mysql's idempotency below is a plain row-count skip, matching the
# OLD mysql*.sh scripts it replaces).
#
# --context NAME (or KUBE_CONTEXT=NAME) is REQUIRED for a real (non
# --dry-run) run against --env k8s — copied in spirit from secrets-seed.sh.
# It is ALSO required for --env aws's MONGO leg (pre-apps) and MYSQL leg
# (post-apps): per the design doc's transport matrix ("Mongo | mongoimport
# via docker | in-cluster Job | *reuses the k8s Job verbatim*"; "MySQL |
# docker exec -> mysql-master | in-cluster Job | ephemeral kubectl run pod ->
# mysql -h $RDS_HOST") and deploy/secrets/contexts/aws.yaml's own note
# ("MongoDB stays self-hosted in-cluster... keeps cluster DNS"), aws's mongo
# leg runs over `kubectl exec` against the EKS cluster, and aws's mysql leg
# launches an ephemeral pod INTO that same cluster with `kubectl run` — both
# the exact same "ambient context might be a different live cluster" hazard
# the k8s guard exists for. aws's IMAGE leg (`aws s3 cp`) never touches
# kubectl and is exempt. NOTE: this extends the letter of this script's
# original requirement (stated only for --env k8s) to --env aws for this
# reason; see task-5-report.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/deploy/scripts/lib/colors.sh"

ENV_NAME=""; STAGE=""; DRY_RUN=0; REPLACE=0; TF_OUTPUTS_OVERRIDE=""
KUBE_CONTEXT="${KUBE_CONTEXT:-}"; CONTEXT_FLAG_GIVEN=0

usage() {
  echo "usage: seed.sh --env compose|k8s|aws --stage pre-apps|post-apps [--dry-run] [--replace] [--context NAME] [--tf-outputs FILE]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env)        ENV_NAME="$2"; shift 2 ;;
    --stage)      STAGE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --replace)    REPLACE=1; shift ;;
    --context)    KUBE_CONTEXT="$2"; CONTEXT_FLAG_GIVEN=1; shift 2 ;;
    --tf-outputs) TF_OUTPUTS_OVERRIDE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$ENV_NAME" in
  compose|k8s|aws) ;;
  *) usage; exit 2 ;;
esac

case "$STAGE" in
  pre-apps|post-apps) ;;
  *) usage; exit 2 ;;
esac

# A kubectl context means nothing to compose, and nothing to aws's IMAGE leg —
# but aws's MONGO leg does use kubectl (see header comment), so --context is
# legal for aws too. Only compose rejects it outright.
if [ "$CONTEXT_FLAG_GIVEN" -eq 1 ] && [ "$ENV_NAME" = "compose" ]; then
  echo "--context applies only to --env k8s or --env aws (got --env compose)" >&2
  exit 2
fi

# ENV=k8s (and aws's mongo leg) write to whichever cluster kubectl happens to
# point at, and there is nothing in an ambient current-context that says which
# one that is — during an earlier phase's verification it turned out to be an
# unrelated, production-adjacent cluster. The target is never inferred: name
# it with --context/KUBE_CONTEXT and it is checked against current-context
# before a single byte moves. --dry-run touches no cluster, so it is exempt.
if { [ "$ENV_NAME" = "k8s" ] || [ "$ENV_NAME" = "aws" ]; } && [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "$KUBE_CONTEXT" ]; then
    log_err "ENV=$ENV_NAME needs an explicit kubectl context: pass --context NAME or set KUBE_CONTEXT"
    log_err "current context is '$(kubectl config current-context 2>/dev/null || echo '<none>')' — seeding refuses to guess"
    exit 1
  fi
  CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  if [ "$CURRENT_CONTEXT" != "$KUBE_CONTEXT" ]; then
    log_err "refusing to seed: requested context '$KUBE_CONTEXT' but kubectl's current context is '${CURRENT_CONTEXT:-<none>}'"
    log_err "run 'kubectl config use-context $KUBE_CONTEXT' first, or correct --context/KUBE_CONTEXT"
    exit 1
  fi
fi

# --- Step 1: resolve the FULL artifact set before writing anything ---------

RESOLVE_ARGS=(--env "$ENV_NAME" --seed-dir "$ROOT/deploy/seed")
if [ "$ENV_NAME" = "aws" ]; then
  if [ -n "$TF_OUTPUTS_OVERRIDE" ]; then
    TF_CACHE="$TF_OUTPUTS_OVERRIDE"
  else
    TF_CACHE="$ROOT/deploy/.run/terraform-outputs.json"
    mkdir -p "$ROOT/deploy/.run"
    if [ ! -f "$TF_CACHE" ]; then
      log_info "generating $TF_CACHE from terraform"
      # $TF_CACHE holds db_master_password (see the post-apps RDS_PASS read
      # below) — write it under a restrictive umask, same discipline as
      # secrets-seed.sh's secrets-<env>.json cache.
      (umask 077; terraform -chdir="$ROOT/aws/main" output -json > "$TF_CACHE") \
        || { log_err "terraform output failed — run 'terraform apply' first, or pass --tf-outputs"; exit 1; }
    fi
  fi
  RESOLVE_ARGS+=(--tf-outputs "$TF_CACHE")
fi
[ "$REPLACE" -eq 1 ] && RESOLVE_ARGS+=(--replace)

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
python3 "$ROOT/deploy/scripts/lib/seed_render.py" "${RESOLVE_ARGS[@]}" > "$RENDERED"
render_rc=$?
if [ "$render_rc" -ne 0 ] || [ ! -s "$RENDERED" ]; then
  log_err "render failed — nothing written to any backend"
  exit 1
fi

PRODUCT_COUNT="$(jq '.mongo.product | length' "$RENDERED")"
API_ROLE_COUNT="$(jq '.mongo.api_role | length' "$RENDERED")"
QTY_COUNT="$(jq '.mongo.productQuantityHistory | length' "$RENDERED")"
OBJECTS_COUNT="$(jq '.objects | length' "$RENDERED")"
MYSQL_COUNT="$(jq '.mysql | length' "$RENDERED")"
DROP_LIST="$(jq -c '.drop' "$RENDERED")"
RECONCILE_LIST="$(jq -c '.reconcile' "$RENDERED")"

case "$STAGE" in
  pre-apps)
    log_info "resolved pre-apps artifacts for $ENV_NAME: mongo.api_role=$API_ROLE_COUNT mongo.product=$PRODUCT_COUNT mongo.productQuantityHistory=$QTY_COUNT objects=$OBJECTS_COUNT drop=$DROP_LIST"
    log_info "reconcile=$RECONCILE_LIST — not acted on by this stage (pre-apps)"
    ;;
  post-apps)
    log_info "resolved post-apps artifacts for $ENV_NAME: mysql statements=$MYSQL_COUNT reconcile=$RECONCILE_LIST"
    ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  log_ok "dry-run — nothing written"
  exit 0
fi

# --- Step 2: transport (pre-apps: mongo, then objects. post-apps: mysql,
#             then the inventory-service reconcile) -------------------------

FAIL=0

# Per-env connection settings. compose reads docker/.env (local-dev secrets);
# k8s/aws use the cluster's own known-fixed dev credentials (job.yaml /
# infra/manifests) unless overridden by the same env vars compose uses.
NS=infra
if [ "$ENV_NAME" = "compose" ]; then
  . "$ROOT/scripts/lib/env.sh"
  load_dotenv || exit 1
fi

case "$STAGE" in
pre-apps)
MONGO_DB="${MONGO_DB_NAME:-ecommerce_inventory}"
MONGO_USER="${MONGO_USERNAME:-ecommerce}"
MONGO_PASS="${MONGO_PASSWORD:-ecommerce123}"
MONGO_CONTAINER="${MONGO_CONTAINER:-ecommerce-mongodb}"
MINIO_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-minioadmin}"
MINIO_BUCKET="${MINIO_BUCKET:-ecommerce-media}"
MINIO_HOST="${MINIO_HOST:-minio}"
SEED_IMAGES_DIR="$ROOT/docker/seed-images"

is_drop_flag() {
  jq -e --arg c "$1" '.drop | index($c) != null' "$RENDERED" >/dev/null 2>&1 && echo 1 || echo 0
}

# Credential hygiene (both branches below): the secret NEVER appears as a
# token in any process's argv — not this script's, not docker/kubectl's own
# client process, not the exec'd process inside the container/pod — because
# argv is readable host-side via `ps aux` and container-side via
# /proc/<pid>/cmdline. mongoimport only takes -u/-p as CLI flags (verified:
# `mongoimport --help` inside mongo:8.0.1 lists no env-var form), so instead
# every leg builds a `mongodb://user:pass@127.0.0.1/...` line and hands it to
# mongoimport via `--config=<file>` (also verified real: `--config=` accepts
# a YAML `uri:` key and mongoimport itself redacts it in its own log —
# "connected to: mongodb://[**REDACTED**]@..." — see task-5-report.md).
#   compose: the value is read SERVER-SIDE from the container's OWN
#     MONGO_INITDB_ROOT_USERNAME/PASSWORD (docker/mongodb.yml sets these from
#     docker/.env — confirmed set: `docker exec ecommerce-mongodb sh -c
#     'echo ${MONGO_INITDB_ROOT_USERNAME:+set}'`). This script's own MONGO_*
#     vars are not even used here — the secret never leaves the container.
#   k8s/aws: no such env var exists in the mongodb pod at all (verified —
#     k8s/infra/manifests/mongodb.yaml's `mongodb` container has no `env:`
#     block; the bootstrap sidecar's creds are literals inside its own inline
#     script, never exported) and `kubectl exec` has no docker-exec-style
#     `-e NAME` passthrough, so any value passed as an exec ARGUMENT would
#     land in that process's argv regardless of using "$1"/positional params.
#     Instead the URI travels as the FIRST LINE of the exec's stdin stream
#     (data, not argv) followed immediately by the JSON payload on the same
#     stream; the remote script's `read -r` consumes exactly that one line
#     (POSIX `read` is specified to read a line at a time with no read-ahead,
#     so the JSON bytes right behind it are untouched — verified against the
#     real compose container with a synthetic marker line + payload).
# Either way the on-disk config file is created via mktemp (mode 0600,
# owner-only) inside the container and removed by a `trap ... EXIT` in the
# remote script — NOT `exec mongoimport` as the last step, since `exec`
# replaces the shell process and would skip its own EXIT trap.
seed_mongo_collection() {
  local coll="$1" drop="$2" docs_file n mode_args=()
  docs_file="$(mktemp)"
  jq -c --arg c "$coll" '.mongo[$c]' "$RENDERED" > "$docs_file"
  n="$(jq 'length' "$docs_file")"
  if [ "$drop" = "1" ]; then mode_args=(--drop); else mode_args=(--mode upsert); fi

  case "$ENV_NAME" in
    compose)
      docker exec -i "$MONGO_CONTAINER" sh -c '
        set -e
        coll="$1"; shift
        : "${MONGO_INITDB_ROOT_USERNAME:?missing in container env}"
        : "${MONGO_INITDB_ROOT_PASSWORD:?missing in container env}"
        cfg="$(mktemp)"
        trap "rm -f \"$cfg\"" EXIT
        cat > "$cfg" <<CFGEOF
uri: "mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@127.0.0.1:27017/${MONGO_INITDB_DATABASE:-ecommerce_inventory}?authSource=admin"
CFGEOF
        mongoimport --config="$cfg" --collection "$coll" --jsonArray "$@"
      ' sh "$coll" "${mode_args[@]}" < "$docs_file" >/dev/null
      ;;
    k8s|aws)
      { printf '%s\n' "mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:27017/${MONGO_DB}?authSource=admin"; cat "$docs_file"; } \
        | kubectl --context "$KUBE_CONTEXT" -n "$NS" exec -i mongodb-0 -- sh -c '
            set -e
            coll="$1"; shift
            IFS= read -r uri
            cfg="$(mktemp)"
            trap "rm -f \"$cfg\"" EXIT
            printf "uri: \"%s\"\n" "$uri" > "$cfg"
            mongoimport --config="$cfg" --collection "$coll" --jsonArray "$@"
          ' sh "$coll" "${mode_args[@]}" >/dev/null
      ;;
  esac
  local rc=$?
  rm -f "$docs_file"
  if [ "$rc" -ne 0 ]; then
    if [ "$drop" = "1" ]; then
      log_err "mongoimport failed for $coll — the collection WAS DROPPED (mongoimport --drop runs the drop before importing) and the import did not complete: data is GONE, not merely unchanged — re-run to restore"
    else
      log_err "mongoimport failed for $coll (upsert mode — any previously-seeded data is unchanged)"
    fi
    return 1
  fi
  log_ok "mongo $coll seeded ($n docs$( [ "$drop" = "1" ] && echo ", dropped first" ))"
}

for coll in api_role product productQuantityHistory; do
  seed_mongo_collection "$coll" "$(is_drop_flag "$coll")" || FAIL=1
done

# --- objects (product images) ----------------------------------------------
# Source of truth for WHICH bytes to upload is the rendered mongo.product
# docs themselves (category + imageUrl), not the flat `objects` list —
# `objects` is a deduped/sorted key set (design doc's canon()) and has
# already lost the per-product category needed to find the local .jpg.
# Object key is recovered from imageUrl by taking everything from the first
# "/products/" onward — every canonical imageUrl embeds that segment (see
# seed_render.py's _objects(): mediaBaseUrl always ends right before it).

case "$ENV_NAME" in
  compose)
    MC_IMAGE="minio/mc:RELEASE.2024-09-16T17-43-14Z"
    NETWORK="${MINIO_DOCKER_NETWORK:-docker_default}"
    if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
      log_warn "Docker network '$NETWORK' not found. Trying 'docker_default'…"
      NETWORK="docker_default"
    fi
    # No `mc alias set` and no -C/config-dir mount at all: `mc` supports an
    # alias defined purely via an MC_HOST_<alias> env var (verified live
    # against the running compose MinIO — `mc ls` worked with zero prior
    # `alias set` call). That removes BOTH argv exposure (`alias set ... USER
    # PASS` used to put the password on the `docker run` argv) AND the
    # persisted-plaintext-config bug (`mc alias set` writes the credential
    # into config.json under whatever -C dir is given; the old code's
    # `MC_CONFIG_DIR="$(mktemp -d)"` was never in the cleanup trap, so every
    # real run left a permanent host directory holding the MinIO password —
    # two such directories from this task's own earlier verification runs
    # were found and removed, see task-5-report.md). `-e MC_HOST_local` (bare
    # name, no `=value`) passes the value through from THIS script's own
    # environment without ever placing it in the `docker run` argv either.
    export MC_HOST_local="http://${MINIO_USER}:${MINIO_PASS}@${MINIO_HOST}:9000"
    mc_run() {
      docker run --rm --network "$NETWORK" \
        -v "$SEED_IMAGES_DIR:/seed-images:ro" \
        -e MC_HOST_local \
        --entrypoint mc "$MC_IMAGE" "$@"
    }
    mc_run mb --ignore-existing "local/$MINIO_BUCKET" >/dev/null
    mc_run anonymous set download "local/$MINIO_BUCKET/products" >/dev/null
    ;;
  aws)
    S3_BUCKET="$(jq -r 'if (.s3_bucket_name.value) then .s3_bucket_name.value else .s3_bucket_name end' "$TF_CACHE" 2>/dev/null)"
    if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" = "null" ]; then
      log_err "s3_bucket_name missing from tf-outputs ($TF_CACHE)"
      FAIL=1
    fi
    ;;
esac

uploaded=0; skipped_missing=0
while IFS=$'\t' read -r pid category image_url; do
  [ -z "$image_url" ] && continue
  filename="${image_url##*/}"
  key="products/${image_url#*/products/}"
  src="$SEED_IMAGES_DIR/$category/$filename"
  if [ ! -f "$src" ]; then
    log_err "missing local seed image: $src (product $pid)"
    skipped_missing=$((skipped_missing + 1))
    FAIL=1
    continue
  fi
  case "$ENV_NAME" in
    compose)
      mc_run cp --attr "Content-Type=image/jpeg" "/seed-images/$category/$filename" "local/$MINIO_BUCKET/$key" >/dev/null \
        || { log_err "mc cp failed for $key"; FAIL=1; continue; }
      ;;
    k8s)
      kubectl --context "$KUBE_CONTEXT" -n "$NS" exec -i minio-0 -c setup -- sh -c "cat > /tmp/img.jpg" < "$src" \
        && kubectl --context "$KUBE_CONTEXT" -n "$NS" exec minio-0 -c setup -- \
             mc cp --attr "Content-Type=image/jpeg" /tmp/img.jpg "local/$MINIO_BUCKET/$key" >/dev/null \
        || { log_err "minio-0 upload failed for $key"; FAIL=1; continue; }
      ;;
    aws)
      aws s3 cp "$src" "s3://${S3_BUCKET}/${key}" --content-type image/jpeg >/dev/null \
        || { log_err "aws s3 cp failed for $key"; FAIL=1; continue; }
      ;;
  esac
  uploaded=$((uploaded + 1))
done < <(jq -r '.mongo.product[] | select(.imageUrl != null) | [._id["$oid"], .category, .imageUrl] | @tsv' "$RENDERED")

log_ok "objects seeded: uploaded=$uploaded missing=$skipped_missing (expected $OBJECTS_COUNT)"
;; # pre-apps

post-apps)
# --- mysql: schema precondition -> ecommerce.sql -> derived inventory rows
#            -> reconcile (design doc §D3) ----------------------------------
#
# Credential hygiene mirrors the mongo leg above exactly (same rule, same
# reason: argv is readable host-side via `ps aux` and container-side via
# /proc/<pid>/cmdline). `mysql -uroot -p"$PASS"` is precisely the class of
# bug this repo has already fixed twice (7f45f28, Task 5's c1a2153) — a
# password NEVER reaches any argv here either.
# `--defaults-extra-file=<file>` (must be the FIRST argument to mysql, or it
# is silently ignored) is MySQL's client-side analogue of mongoimport's
# `--config=`.
#   compose: docker/mysql.yml's `master` container carries its own
#     MYSQL_ROOT_PASSWORD (confirmed: `docker exec mysql-master sh -c
#     'echo ${MYSQL_ROOT_PASSWORD:+set}'` -> "set") — read SERVER-SIDE inside
#     the container; this script's own environment is never consulted.
#   k8s: k8s/infra/manifests/mysql.yaml's `mysql` StatefulSet pod (mysql-0,
#     ns infra, one replica) gets MYSQL_ROOT_PASSWORD via `envFrom:
#     secretRef: mysql-credentials` — same server-side read as compose.
#   aws: unlike mongo (which stays self-hosted in-cluster for aws too — see
#     this file's header), RDS has no pod to exec into. mysql runs from a
#     throwaway `kubectl run` pod that reaches RDS over the network
#     (mirrors scripts/aws/seed-inventory.sh). That pod has no ambient
#     credential env var, so the password travels as the FIRST LINE of the
#     exec's stdin stream — exactly the mongo aws leg's technique above
#     (`IFS= read -r pass` consumes exactly that line; POSIX `read` has no
#     read-ahead, so the SQL stream behind it is untouched — already
#     verified for mongo). It is never handed to `kubectl run` via --env:
#     that WOULD land it on THIS HOST's kubectl argv — the actual mistake in
#     scripts/aws/seed-inventory.sh's own `--env=MYSQL_PWD="$DB_PASS"` (not
#     our path, named here because it is the nearest precedent's real bug).
# Every on-disk defaults file is 0600 (mktemp's default mode), lives inside
# the container/pod only, and is removed by a `trap ... EXIT` — never `exec
# mysql` as the last step, since that replaces the shell and would skip its
# own trap.

MYSQL_DB="${MYSQL_DB_NAME:-ecommerce_dev}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql-master}"

if [ "$ENV_NAME" = "aws" ]; then
  RDS_HOST="$(jq -r 'if (.rds_primary_endpoint.value) then .rds_primary_endpoint.value else .rds_primary_endpoint end' "$TF_CACHE" 2>/dev/null)"
  RDS_PASS="$(jq -r 'if (.db_master_password.value) then .db_master_password.value else .db_master_password end' "$TF_CACHE" 2>/dev/null)"
  if [ -z "$RDS_HOST" ] || [ "$RDS_HOST" = "null" ]; then
    log_err "rds_primary_endpoint missing from tf-outputs ($TF_CACHE)"
    FAIL=1
  fi
  if [ -z "$RDS_PASS" ] || [ "$RDS_PASS" = "null" ]; then
    log_err "db_master_password missing from tf-outputs ($TF_CACHE)"
    FAIL=1
  fi
  [ "$FAIL" -eq 0 ] || exit 1
fi

# mysql_run: pipes SQL (or a query) on ITS OWN stdin to mysql against this
# env's target db, prints mysql's stdout. -N -B = no headers/table borders,
# so a SELECT's rows come back one bare value per line.
mysql_run() {
  case "$ENV_NAME" in
    compose)
      docker exec -i "$MYSQL_CONTAINER" sh -c '
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
      kubectl --context "$KUBE_CONTEXT" -n "$NS" exec -i mysql-0 -- sh -c '
        set -e
        db="$1"
        : "${MYSQL_ROOT_PASSWORD:?missing in container env}"
        cfg="$(mktemp)"
        trap "rm -f \"$cfg\"" EXIT
        printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASSWORD" > "$cfg"
        mysql --defaults-extra-file="$cfg" -N -B "$db"
      ' sh "$MYSQL_DB"
      ;;
    aws)
      { printf '%s\n' "$RDS_PASS"; cat; } | kubectl --context "$KUBE_CONTEXT" -n apps run "mysql-seed-${RANDOM}" \
        --rm -i --restart=Never --image=mysql:8.0.40 --command -- sh -c '
          set -e
          host="$1"; db="$2"
          IFS= read -r pass
          cfg="$(mktemp)"
          trap "rm -f \"$cfg\"" EXIT
          printf "[client]\nhost=%s\nuser=admin\npassword=%s\n" "$host" "$pass" > "$cfg"
          mysql --defaults-extra-file="$cfg" -N -B "$db"
        ' sh "$RDS_HOST" "$MYSQL_DB"
      ;;
  esac
}

# --- precondition: every table an INSERT targets must already exist -------
# ecommerce.sql is data-only (0 CREATE TABLE — see this file's header); the
# schema comes from Hibernate ddl-auto at service boot. Importing against a
# missing table fails partway through with ERROR 1146 (k8s/CLAUDE.md's
# documented failure mode). Check EVERY target table (from BOTH the
# ecommerce.sql dump and the generated inventory rows) before a single
# INSERT runs, and name the first missing one.
REQUIRED_TABLES="$(jq -r '.mysql[]' "$RENDERED" \
  | grep -oiE 'INSERT( IGNORE)? INTO `?[A-Za-z_]+`?' \
  | grep -oE '[A-Za-z_]+`?$' | tr -d '`' | sort -u)"
# Vacuous-pass guard: if the regex above matches nothing, REQUIRED_TABLES is
# empty, IN_LIST becomes '', the information_schema query returns nothing,
# `comm` compares empty-against-empty, MISSING stays empty, and the
# precondition below would print "all 0 target tables exist" and proceed —
# exactly the ERROR-1146 half-import this precondition exists to prevent,
# just with the guard itself silently disabled instead of removed. Six is the
# real count today (account, account_role, role, user, inventory_product,
# product_quantity_history) — refuse below that rather than assume the
# parser is still matching correctly.
REQUIRED_COUNT="$(printf '%s\n' "$REQUIRED_TABLES" | grep -c .)"
[ "$REQUIRED_COUNT" -ge 6 ] || { log_err "precondition: derived $REQUIRED_COUNT target tables from the SQL — the table-name parser is broken, refusing to proceed"; exit 1; }
IN_LIST="$(printf '%s\n' "$REQUIRED_TABLES" | awk '{printf "%s%s", (NR>1?",":""), "\x27" $0 "\x27"}')"
EXISTING_TABLES="$(printf "SELECT table_name FROM information_schema.tables WHERE table_schema='%s' AND table_name IN (%s);\n" "$MYSQL_DB" "$IN_LIST" | mysql_run)"
precheck_rc=$?
if [ "$precheck_rc" -ne 0 ]; then
  log_err "post-apps: could not query information_schema — is $ENV_NAME's MySQL reachable?"
  exit 1
fi
MISSING="$(comm -23 <(printf '%s\n' "$REQUIRED_TABLES") <(printf '%s\n' "$EXISTING_TABLES" | sort -u) | head -1)"
if [ -n "$MISSING" ]; then
  log_err "post-apps: table '$MISSING' does not exist — run the apps first so Hibernate ddl-auto creates the schema"
  exit 1
fi
log_ok "post-apps precondition: all $(printf '%s\n' "$REQUIRED_TABLES" | grep -c .) target tables exist ($ENV_NAME:$MYSQL_DB)"

# --- ecommerce.sql (account/account_role/role/user) ------------------------
# Rendered fresh via --only (same substitution path as the merged .mysql[]
# array); ecommerce.sql carries no {{ctx.…}} refs today so this is close to
# a no-op, but going through the renderer keeps one source of truth instead
# of reading deploy/seed/ecommerce.sql directly.
ECOMMERCE_SQL="$(python3 "$ROOT/deploy/scripts/lib/seed_render.py" "${RESOLVE_ARGS[@]}" --only ecommerce.sql)"
ec_render_rc=$?
if [ "$ec_render_rc" -ne 0 ] || [ -z "$ECOMMERCE_SQL" ]; then
  log_err "post-apps: could not render ecommerce.sql — see renderer stderr above"
  exit 1
fi

ACCOUNT_COUNT="$(printf 'SELECT COUNT(*) FROM account;\n' | mysql_run)"
if [ "${ACCOUNT_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  log_warn "ecommerce.sql already seeded (account=$ACCOUNT_COUNT rows) — skipping"
else
  log_info "importing ecommerce.sql (account/account_role/role/user) into $ENV_NAME:$MYSQL_DB"
  if ! printf '%s\n' "$ECOMMERCE_SQL" | mysql_run >/dev/null; then
    log_err "ecommerce.sql import failed"
    FAIL=1
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  log_err "seed post-apps for $ENV_NAME finished WITH ERRORS — see above (reconcile NOT attempted)"
  exit 1
fi

# --- derived inventory rows (inventory_product, then product_quantity_history) ----
# Pulled from the already-rendered/escaped merged .mysql[] array (not
# regenerated here) — table filter is safe because ecommerce.sql never
# targets these two tables. inventory_product goes first: no FK exists
# (ProductQuantityHistory.productId is a plain column, not a @ManyToOne —
# verified against the entity), but the row order still mirrors the old
# per-table scripts' intent (mysql-inventory-products.sh before
# mysql-product-quantity-history.sh).
#
# Gated INDEPENDENTLY per table — NOT one combined gate — matching the old
# mysql-inventory-products.sh / mysql-product-quantity-history.sh scripts
# this replaces. A single inventory_product-only gate covering both imports
# (an earlier version of this script did exactly that) has a silent-failure
# window: if the connection drops after inventory_product commits but
# before product_quantity_history does, a re-run sees inventory_product
# already populated, skips BOTH imports, and the ledger stays permanently
# half-empty — AvailableStockSeeder then rebuilds counters from an
# incomplete SUM(product_quantity_history), silently reintroducing "0
# available" for exactly the rows that never landed, while every command
# up to and including the reconcile reports success.
INV_PRODUCT_SQL="$(jq -r '.mysql[] | select(contains("INTO inventory_product "))' "$RENDERED")"
QTY_SQL="$(jq -r '.mysql[] | select(contains("INTO product_quantity_history "))' "$RENDERED")"

# Vacuous-pass guard, same class as ECOMMERCE_SQL's check above (which IS
# already asserted non-empty) — these two are jq substring filters, not
# counted anywhere else. If either ever matched nothing, an empty stream
# piped to `mysql` still exits 0 just like a real import, "importing … (0
# rows)" would print as if that were expected, the reconcile below would
# still run, and AvailableStockSeeder would rebuild the Redis counters /
# inventory_product.stock from an empty ledger — "0 available" returning
# silently with everything reporting green.
INV_ROWS="$(printf '%s\n' "$INV_PRODUCT_SQL" | grep -c INSERT || true)"
QTY_ROWS="$(printf '%s\n' "$QTY_SQL" | grep -c INSERT || true)"
[ "$INV_ROWS" -gt 0 ] || { log_err "post-apps: derived 0 inventory_product INSERT statements from the rendered SQL — refusing to import an empty ledger (the jq filter above may be broken)"; FAIL=1; }
[ "$QTY_ROWS" -gt 0 ] || { log_err "post-apps: derived 0 product_quantity_history INSERT statements from the rendered SQL — refusing to import an empty ledger (the jq filter above may be broken)"; FAIL=1; }
if [ "$FAIL" -ne 0 ]; then
  log_err "seed post-apps for $ENV_NAME finished WITH ERRORS — see above (reconcile NOT attempted)"
  exit 1
fi

INV_COUNT="$(printf 'SELECT COUNT(*) FROM inventory_product;\n' | mysql_run)"
if [ "${INV_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  log_warn "inventory_product already seeded ($INV_COUNT rows) — skipping"
else
  log_info "importing inventory_product ($INV_ROWS rows)"
  if ! printf '%s\n' "$INV_PRODUCT_SQL" | mysql_run >/dev/null; then
    log_err "inventory_product import failed"
    FAIL=1
  fi
fi

QTY_DB_COUNT="$(printf 'SELECT COUNT(*) FROM product_quantity_history;\n' | mysql_run)"
if [ "${QTY_DB_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  log_warn "product_quantity_history already seeded ($QTY_DB_COUNT rows) — skipping"
else
  log_info "importing product_quantity_history ($QTY_ROWS rows)"
  if ! printf '%s\n' "$QTY_SQL" | mysql_run >/dev/null; then
    log_err "product_quantity_history import failed"
    FAIL=1
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  log_err "seed post-apps for $ENV_NAME finished WITH ERRORS — see above (reconcile NOT attempted)"
  exit 1
fi
log_ok "mysql seeded for $ENV_NAME: ecommerce.sql + derived inventory rows"

# --- reconcile: restart inventory-service ----------------------------------
# render_all()'s reconcile token is the env-invariant "restart:inventory-
# service"; this is where it maps to a per-env action. AvailableStockSeeder
# (inventory-service, ApplicationRunner) runs at STARTUP and backfills the
# Redis `productAvailable:{productId}` counters from SUM(product_quantity_
# history) — see core-redis's RedisConstant.AVAILABLE_PRODUCT_KEY, whose
# actual value is "productAvailable:", not "available:" as an earlier draft
# of this task's brief said (see task-6-report.md). Apps start BEFORE this
# seed stage runs, so at boot the ledger was empty and it backfilled 0 rows,
# creating no counters; the Lua reservation then reads a missing key as 0
# and every order fails "Insufficient available stock". Idempotent (the
# seeder deletes-then-incrs each key), so a no-op reconcile just costs one
# restart. Skipped when the inventory-service workload is absent, so running
# this stage standalone (before the apps exist) stays valid — matches
# scripts/seed/k8s-inventory.sh's and scripts/aws/up-all.sh step 8's
# existing guard for the k8s/aws case.
case "$ENV_NAME" in
  compose)
    # compose has no reconcile today (the documented "0 available" cart bug)
    # — inventory-service is a JVM process under scripts/services/*, not a
    # container, so there is no `docker restart` target and no
    # scripts/services/restart.sh. The fix is `make svc-restart
    # svc=inventory-service`'s own two steps.
    #
    # Three outcomes, and they must stay distinguishable in the output:
    #   1. confidently absent (no pidfile/dead PID AND lsof confirms no
    #      listener) -> skip, log_warn, NOT a failure (standalone seed
    #      before apps exist is a legitimate use).
    #   2. confidently running -> restart, and the restart's own exit code
    #      is checked (see below) — it must NOT be possible for a timed-out
    #      or failed restart to still print success.
    #   3. genuinely unknown (no pidfile AND lsof unavailable to fall back
    #      on) -> NOT the same as (1). Silently choosing "skip" here would
    #      let a real orphan on :6969 go unreconciled while reporting
    #      success — the exact invisible-failure shape this whole stage
    #      exists to close. Loudly refuse instead (FAIL=1).
    INV_PID_FILE="$ROOT/logs/pids/inventory-service.pid"
    inventory_running=0
    inventory_status_known=1
    if [ -f "$INV_PID_FILE" ] && kill -0 "$(cat "$INV_PID_FILE" 2>/dev/null)" 2>/dev/null; then
      inventory_running=1
    elif command -v lsof >/dev/null 2>&1; then
      lsof -tiTCP:6969 -sTCP:LISTEN >/dev/null 2>&1 && inventory_running=1
    else
      inventory_status_known=0
    fi

    if [ "$inventory_running" -eq 1 ]; then
      log_info "reconcile: restarting inventory-service (stop.sh + start.sh) so AvailableStockSeeder rebuilds Redis counters from the seeded ledger"
      # start.sh runs under `set -e` and its single-target path calls
      # wait_for_port with no `|| true` — a stuck/failed boot makes start.sh
      # itself exit nonzero, which this `&&` chain now actually checks
      # (previously ignored, the Critical finding: a timed-out rollout still
      # printed "restarted" and exited 0).
      if bash "$ROOT/scripts/services/stop.sh" inventory-service \
         && bash "$ROOT/scripts/services/start.sh" inventory-service; then
        log_ok "reconcile: inventory-service restarted"
      else
        log_err "reconcile: inventory-service restart failed — Redis productAvailable:* counters were NOT rebuilt; every order will fail \"Insufficient available stock\" until this is fixed and the seed is re-run"
        FAIL=1
      fi
    elif [ "$inventory_status_known" -eq 0 ]; then
      log_err "reconcile: could not determine whether inventory-service is running (no pidfile and lsof is unavailable) — refusing to silently skip the reconcile; install lsof, or ensure logs/pids/inventory-service.pid is current, then re-run"
      FAIL=1
    else
      log_warn "reconcile: inventory-service is not running — skipping (seed run standalone before apps)"
    fi
    ;;
  k8s|aws)
    if kubectl --context "$KUBE_CONTEXT" -n apps get deploy inventory-service >/dev/null 2>&1; then
      log_info "reconcile: kubectl rollout restart deploy/inventory-service (context=$KUBE_CONTEXT)"
      if kubectl --context "$KUBE_CONTEXT" -n apps rollout restart deploy/inventory-service \
         && kubectl --context "$KUBE_CONTEXT" -n apps rollout status deploy/inventory-service --timeout=300s; then
        log_ok "reconcile: inventory-service rollout restarted"
      else
        log_err "reconcile: inventory-service rollout restart/status failed — Redis productAvailable:* counters were NOT rebuilt; every order will fail \"Insufficient available stock\" until this is fixed and the seed is re-run"
        FAIL=1
      fi
    else
      log_warn "reconcile: inventory-service Deployment not found in apps ns — skipping (seed run standalone before apps)"
    fi
    ;;
esac
;; # post-apps
esac

if [ "$FAIL" -ne 0 ]; then
  log_err "seed $STAGE for $ENV_NAME finished WITH ERRORS — see above"
  exit 1
fi

log_ok "seed $STAGE complete for $ENV_NAME"
