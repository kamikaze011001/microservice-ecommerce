#!/bin/bash
# Fetch deterministic placeholder JPEGs for every product in
# scripts/seed/products-manifest.json. Idempotent: skips files that exist.
# Re-run with FORCE=1 to overwrite.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/seed/products-manifest.json"
OUT_DIR="$REPO_ROOT/docker/seed-images"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

mkdir -p "$OUT_DIR/apparel" "$OUT_DIR/footwear" "$OUT_DIR/accessories"

count_total=0
count_fetched=0
count_skipped=0

while IFS=$'\t' read -r slug category; do
    count_total=$((count_total + 1))
    out="$OUT_DIR/$category/$slug.jpg"
    if [ -f "$out" ] && [ -z "$FORCE" ]; then
        count_skipped=$((count_skipped + 1))
        continue
    fi
    url="https://picsum.photos/seed/${slug}/800/800.jpg"
    log_info "Fetching $slug -> $out"
    curl -sSL --fail --output "$out" "$url" || {
        log_warn "Failed to fetch $url; leaving placeholder absent"
        continue
    }
    count_fetched=$((count_fetched + 1))
done < <(jq -r '.products[] | "\(.slug)\t\(.category)"' "$MANIFEST")

log_ok "seed-images: fetched=$count_fetched skipped=$count_skipped total=$count_total"
