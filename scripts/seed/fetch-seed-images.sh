#!/bin/bash
# Download each product's real image from its manifest `imageSource` and
# convert webp -> jpg into docker/seed-images/<category>/<slug>.jpg.
#
# The JPEGs are COMMITTED, so this is an authoring tool, not a build step —
# no contributor and no CI job needs to run it. Re-run only when the
# manifest changes. Idempotent: skips files that exist unless FORCE=1.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/seed/products-manifest.json"
OUT_DIR="$REPO_ROOT/docker/seed-images"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

# webp -> jpg. No single converter is present on every machine, so try the
# common ones in order and fail loudly rather than silently emitting a webp
# with a .jpg extension (MinIO would then serve the wrong Content-Type).
#
# Each branch must produce a JPEG in ONE step. `dwebp` is deliberately absent:
# it only decodes to png/pnm, so it would need a second converter anyway — and
# the only reason we'd reach it is that the converters it depends on are missing.
convert_webp() {
    local src="$1" dst="$2"
    if command -v magick >/dev/null 2>&1; then
        magick "$src" "$dst"
    elif command -v sips >/dev/null 2>&1; then
        sips -s format jpeg "$src" --out "$dst" >/dev/null
    elif python3 -c "import PIL" >/dev/null 2>&1; then
        python3 -c "from PIL import Image; Image.open('$src').convert('RGB').save('$dst', 'JPEG', quality=90)"
    else
        log_err "no webp->jpg converter found. Install one of: imagemagick (brew install imagemagick) or Pillow (pip install Pillow)."
        exit 1
    fi
}

mkdir -p "$OUT_DIR/apparel" "$OUT_DIR/footwear" "$OUT_DIR/accessories"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetched=0
skipped=0

while IFS=$'\t' read -r slug category src; do
    out="$OUT_DIR/$category/$slug.jpg"
    if [ -f "$out" ] && [ -z "$FORCE" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    log_info "Fetching $slug"
    # NOTE: several imageSource URLs contain & and ' — always keep "$src" quoted.
    curl -sSL --fail --max-time 30 --output "$tmp/$slug.webp" "$src"
    convert_webp "$tmp/$slug.webp" "$out"
    fetched=$((fetched + 1))
done < <(jq -r '.products[] | "\(.slug)\t\(.category)\t\(.imageSource)"' "$MANIFEST")

# Prune images whose slug is no longer in the manifest.
pruned=0
expected=$(jq -r '.products[] | "\(.category)/\(.slug).jpg"' "$MANIFEST" | sort)
while IFS= read -r existing; do
    rel="${existing#"$OUT_DIR/"}"
    if ! echo "$expected" | grep -Fqx "$rel"; then
        log_info "Pruning stale image $rel"
        rm -f "$existing"
        pruned=$((pruned + 1))
    fi
done < <(find "$OUT_DIR" -name '*.jpg')

log_ok "seed-images: fetched=$fetched skipped=$skipped pruned=$pruned"
