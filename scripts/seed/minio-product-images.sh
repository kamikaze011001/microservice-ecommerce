#!/bin/bash
# Upload docker/seed-images/<cat>/<slug>.jpg to MinIO at
# products/<productId>/<slug>.jpg. Idempotent: skip if object size matches.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/seed/products-manifest.json"
SEED_DIR="$REPO_ROOT/docker/seed-images"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

load_dotenv

USER="${MINIO_ROOT_USER:-minioadmin}"
PASS="${MINIO_ROOT_PASSWORD:-minioadmin}"
BUCKET="${MINIO_BUCKET:-ecommerce-media}"
NETWORK="${MINIO_DOCKER_NETWORK:-docker_default}"
MINIO_HOST="${MINIO_HOST:-minio}"

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    log_warn "Docker network '$NETWORK' not found. Trying 'docker_default'…"
    NETWORK="docker_default"
fi

MC_CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

mc() {
    docker run --rm --network "$NETWORK" \
        -v "$SEED_DIR:/seed-images:ro" \
        -v "$MC_CONFIG_DIR:/mc-config" \
        --entrypoint mc \
        minio/mc:RELEASE.2024-09-16T17-43-14Z -C /mc-config "$@"
}

log_info "Configuring mc alias for $MINIO_HOST:9000…"
mc alias set local "http://${MINIO_HOST}:9000" "$USER" "$PASS" >/dev/null

log_info "Ensuring bucket '$BUCKET' exists and products/* is anonymous-read…"
mc mb --ignore-existing "local/$BUCKET" >/dev/null
mc anonymous set download "local/$BUCKET/products" >/dev/null

uploaded=0
skipped=0
failed=0

while IFS=$'\t' read -r slug category productId; do
    src_rel="$category/$slug.jpg"
    src_local="$SEED_DIR/$src_rel"
    if [ ! -f "$src_local" ]; then
        log_warn "Missing local image: $src_local — skipping"
        failed=$((failed + 1))
        continue
    fi
    object_key="products/$productId/$slug.jpg"
    local_size=$(wc -c < "$src_local" | tr -d ' ')
    remote_size=$(mc stat --json "local/$BUCKET/$object_key" 2>/dev/null \
        | jq -r '.size // empty' || true)
    if [ -n "$remote_size" ] && [ "$remote_size" = "$local_size" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    mc cp --attr "Content-Type=image/jpeg" \
        "/seed-images/$src_rel" "local/$BUCKET/$object_key" >/dev/null
    uploaded=$((uploaded + 1))
done < <(jq -r '.products[] | "\(.slug)\t\(.category)\t\(.productId)"' "$MANIFEST")

log_ok "MinIO product images: uploaded=$uploaded skipped=$skipped failed=$failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
