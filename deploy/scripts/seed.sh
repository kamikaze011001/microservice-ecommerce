#!/usr/bin/env bash
# Resolve deploy/seed/ (+ an env context) and push the PRE-APPS artifacts —
# Mongo documents and product image objects — to this env's backend.
#
#   deploy/scripts/seed.sh --env compose|k8s|aws --stage pre-apps
#                          [--dry-run] [--replace] [--context NAME]
#                          [--tf-outputs FILE]
#
# PRE-APPS (this file, Phase 5 Task 5): mongo (api_role/product/
# productQuantityHistory) + objects (product images). POST-APPS (ecommerce.sql,
# the derived inventory_product/product_quantity_history rows, the schema
# precondition, and the inventory-service reconcile) is Task 6 — NOT
# implemented here. `render_all()`'s "reconcile" key is printed for visibility
# but this stage does not act on it; `--stage post-apps` refuses below.
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
# mongo-products.sh is excluded from `make up`.
#
# --context NAME (or KUBE_CONTEXT=NAME) is REQUIRED for a real (non
# --dry-run) run against --env k8s — copied in spirit from secrets-seed.sh.
# It is ALSO required for --env aws's MONGO leg only: per the design doc's
# transport matrix ("Mongo | mongoimport via docker | in-cluster Job |
# *reuses the k8s Job verbatim*") and deploy/secrets/contexts/aws.yaml's own
# note ("MongoDB stays self-hosted in-cluster... keeps cluster DNS"), aws's
# mongo leg runs over `kubectl exec` against the EKS cluster too — the exact
# same "ambient context might be a different live cluster" hazard the k8s
# guard exists for. aws's IMAGE leg (`aws s3 cp`) never touches kubectl and
# is exempt. NOTE: this extends the letter of this script's original
# requirement (stated only for --env k8s) to --env aws for this one reason;
# see task-5-report.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/deploy/scripts/lib/colors.sh"

ENV_NAME=""; STAGE=""; DRY_RUN=0; REPLACE=0; TF_OUTPUTS_OVERRIDE=""
KUBE_CONTEXT="${KUBE_CONTEXT:-}"; CONTEXT_FLAG_GIVEN=0

usage() {
  echo "usage: seed.sh --env compose|k8s|aws --stage pre-apps [--dry-run] [--replace] [--context NAME] [--tf-outputs FILE]" >&2
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
  pre-apps) ;;
  post-apps)
    log_err "--stage post-apps is not implemented by this build (Task 6: mysql," \
            "derived inventory_product/product_quantity_history rows, the schema" \
            "precondition, and the inventory-service reconcile). This build only" \
            "ships --stage pre-apps (mongo + objects)."
    exit 2
    ;;
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
      terraform -chdir="$ROOT/aws/main" output -json > "$TF_CACHE" \
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
DROP_LIST="$(jq -c '.drop' "$RENDERED")"
RECONCILE_LIST="$(jq -c '.reconcile' "$RENDERED")"

log_info "resolved pre-apps artifacts for $ENV_NAME: mongo.api_role=$API_ROLE_COUNT mongo.product=$PRODUCT_COUNT mongo.productQuantityHistory=$QTY_COUNT objects=$OBJECTS_COUNT drop=$DROP_LIST"
log_info "reconcile=$RECONCILE_LIST — not acted on by this stage (Task 6/post-apps)"

if [ "$DRY_RUN" -eq 1 ]; then
  log_ok "dry-run — nothing written"
  exit 0
fi

# --- Step 2: transport (mongo, then objects) --------------------------------

FAIL=0

# Per-env connection settings. compose reads docker/.env (local-dev secrets);
# k8s/aws use the cluster's own known-fixed dev credentials (job.yaml /
# infra/manifests) unless overridden by the same env vars compose uses.
NS=infra
if [ "$ENV_NAME" = "compose" ]; then
  . "$ROOT/scripts/lib/env.sh"
  load_dotenv || exit 1
fi
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

seed_mongo_collection() {
  local coll="$1" drop="$2" docs_file n mode_args=()
  docs_file="$(mktemp)"
  jq -c --arg c "$coll" '.mongo[$c]' "$RENDERED" > "$docs_file"
  n="$(jq 'length' "$docs_file")"
  if [ "$drop" = "1" ]; then mode_args=(--drop); else mode_args=(--mode upsert); fi

  case "$ENV_NAME" in
    compose)
      docker exec -i "$MONGO_CONTAINER" mongoimport \
        --authenticationDatabase admin -u "$MONGO_USER" -p "$MONGO_PASS" \
        --db "$MONGO_DB" --collection "$coll" --jsonArray "${mode_args[@]}" \
        < "$docs_file" >/dev/null
      ;;
    k8s|aws)
      kubectl --context "$KUBE_CONTEXT" -n "$NS" exec -i mongodb-0 -- mongoimport \
        --uri "mongodb://127.0.0.1:27017/$MONGO_DB?authSource=admin" \
        -u "$MONGO_USER" -p "$MONGO_PASS" \
        --collection "$coll" --jsonArray "${mode_args[@]}" \
        < "$docs_file" >/dev/null
      ;;
  esac
  local rc=$?
  rm -f "$docs_file"
  if [ "$rc" -ne 0 ]; then
    log_err "mongoimport failed for $coll"
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
    MC_CONFIG_DIR="$(mktemp -d)"
    mc_run() {
      docker run --rm --network "$NETWORK" \
        -v "$SEED_IMAGES_DIR:/seed-images:ro" \
        -v "$MC_CONFIG_DIR:/mc-config" \
        --entrypoint mc "$MC_IMAGE" -C /mc-config "$@"
    }
    mc_run alias set local "http://${MINIO_HOST}:9000" "$MINIO_USER" "$MINIO_PASS" >/dev/null \
      || { log_err "mc alias set failed"; FAIL=1; }
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

if [ "$FAIL" -ne 0 ]; then
  log_err "seed pre-apps for $ENV_NAME finished WITH ERRORS — see above"
  exit 1
fi

log_ok "seed pre-apps complete for $ENV_NAME"
