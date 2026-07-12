#!/bin/bash
# Gate for products-manifest.json.
#
# The k6 stress jobs (k8s/apps/base/k6-stress/*.yaml) hardcode product
# ObjectIds 67c0…0001-0004. Renumbering the catalog silently breaks them,
# and the failure surfaces far from the cause. So the IDs and their stock
# levels are FROZEN and checked here.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/seed/products-manifest.json"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

# id-suffix:quantity — frozen. Do not edit without re-checking the k6 jobs.
FROZEN="01:30 02:18 03:12 04:0 05:8 06:25 07:22 08:2 09:35 0a:40 \
0b:28 0c:14 0d:22 0e:10 0f:0 10:30 11:6 12:1 13:18 14:24 \
15:50 16:18 17:32 18:14 19:0 1a:40 1b:10 1c:45 1d:16 1e:8"

fail=0
err() { log_warn "$1"; fail=1; }

count=$(jq '.products | length' "$MANIFEST")
[ "$count" -eq 30 ] || err "expected 30 products, got $count"

for pair in $FROZEN; do
    suffix="${pair%%:*}"
    want_qty="${pair##*:}"
    id="67c0000000000000000000${suffix}"
    entry=$(jq -c --arg id "$id" '.products[] | select(.productId == $id)' "$MANIFEST")
    if [ -z "$entry" ]; then
        err "missing frozen productId $id"
        continue
    fi
    got_qty=$(echo "$entry" | jq -r '.quantity')
    [ "$got_qty" = "$want_qty" ] || err "$id quantity drifted: want $want_qty, got $got_qty"
done

# Every product must carry chatbot-grounding data and a real image source.
while IFS=$'\t' read -r id desc_len tag_count src; do
    [ "$desc_len" -ge 80 ] || err "$id description too short ($desc_len chars; need >= 80)"
    [ "$tag_count" -ge 3 ] || err "$id has $tag_count tags (need >= 3)"
    case "$src" in
        https://cdn.dummyjson.com/product-images/*) ;;
        *) err "$id imageSource is not a dummyjson product image: '$src'" ;;
    esac
done < <(jq -r '.products[] | "\(.productId)\t\(.description | length)\t\(.tags | length)\t\(.imageSource)"' "$MANIFEST")

# Trademarked brands must never re-enter the catalog.
if jq -r '.products[] | .name' "$MANIFEST" \
   | grep -inE 'nike|puma|off.?white|prada|calvin klein|rolex|marni|gigabyte|heshe'; then
    err "trademarked brand name found in catalog"
fi

# Slugs must be unique — they are the image filenames.
dupes=$(jq -r '.products[].slug' "$MANIFEST" | sort | uniq -d)
[ -z "$dupes" ] || err "duplicate slugs: $dupes"

if [ "$fail" -ne 0 ]; then
    log_warn "manifest check FAILED"
    exit 1
fi
log_ok "manifest check passed (30 products, IDs + stock frozen)"
