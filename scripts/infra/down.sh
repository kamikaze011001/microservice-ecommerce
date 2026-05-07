#!/bin/bash
# Stop infrastructure containers.
#
# Default: `docker compose stop` — preserves containers + volumes (anonymous
#   and named alike). This is the daily-loop semantics: turn things off, leave
#   state untouched.
#
# --volumes: `docker compose down -v` — removes containers, networks, AND
#   volumes. Used by `make nuke`. Destroys all local data.
#
# Why not `docker compose down` (without -v) for the default? It removes
# containers, which orphans anonymous volumes. Zookeeper used to lose its
# cluster ID this way while Kafka kept its named volume → broker refused to
# start with "Invalid cluster.id" on next make up.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

cd "$REPO_ROOT"

WIPE=false
if [ "${1:-}" = "--volumes" ]; then
    WIPE=true
    log_warn "Wiping volumes — all data will be lost"
fi

for f in vault.yml kafka.yml mongodb.yml redis.yml mysql.yml; do
    if [ "$WIPE" = true ]; then
        log_info "Removing $f (containers + volumes)..."
        docker compose -f "docker/$f" down -v || true
    else
        log_info "Stopping $f..."
        docker compose -f "docker/$f" stop || true
    fi
done

if [ "$WIPE" = true ]; then
    log_ok "Infrastructure removed (volumes wiped)"
else
    log_ok "Infrastructure stopped (containers + volumes preserved)"
fi
