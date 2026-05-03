#!/bin/bash
# Smoke-check the seeded catalog. Requires the gateway and product-service
# to be running (make up) and seed-data to have completed.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

GATEWAY="${GATEWAY_URL:-http://localhost:8080}"

log_info "GET $GATEWAY/product-service/v1/products?page=1&size=12"
body=$(curl -sSf "$GATEWAY/product-service/v1/products?page=1&size=12")

total=$(echo "$body" | jq -r '.data.total // .data.totalElements // .data.totalItems // empty')
if [ -z "$total" ]; then
    log_warn "Could not extract total from response — dumping body for inspection"
    echo "$body" | jq . || echo "$body"
    exit 1
fi
if [ "$total" -lt 30 ]; then
    log_warn "Expected total >= 30, got $total"
    exit 1
fi
log_ok "Catalog total: $total"

first_image=$(echo "$body" | jq -r '.data.data[0].image_url // .data.items[0].image_url // .data.content[0].image_url // empty')
if [ -z "$first_image" ]; then
    log_warn "Could not find image_url on first product — dumping body"
    echo "$body" | jq . || echo "$body"
    exit 1
fi

log_info "HEAD $first_image"
status=$(curl -sI -o /dev/null -w '%{http_code}' "$first_image")
content_type=$(curl -sI "$first_image" | awk -F': ' 'tolower($1)=="content-type"{print $2}' | tr -d '\r')
if [ "$status" != "200" ]; then
    log_warn "Image HEAD returned $status (expected 200)"
    exit 1
fi
case "$content_type" in
    image/jpeg*|image/jpg*) ;;
    *) log_warn "Image Content-Type was '$content_type' (expected image/jpeg)"; exit 1 ;;
esac
log_ok "First image reachable: $first_image"

log_ok "Seed verification passed"
