#!/bin/bash
# Stop all infrastructure containers. Preserves volumes.
# Pass --volumes to wipe data (used by `make nuke`).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

cd "$REPO_ROOT"

DOWN_ARGS=()
if [ "${1:-}" = "--volumes" ]; then
    DOWN_ARGS+=("-v")
    log_warn "Wiping volumes — all data will be lost"
fi

for f in vault.yml kafka.yml mongodb.yml redis.yml mysql.yml; do
    log_info "Stopping $f..."
    docker compose -f "docker/$f" down "${DOWN_ARGS[@]}" || true
done

log_ok "Infrastructure down"
