#!/bin/bash
# Show status of all infrastructure compose stacks.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

cd "$REPO_ROOT"

for f in mysql.yml redis.yml mongodb.yml kafka.yml vault.yml; do
    log_info "=== $f ==="
    docker compose -f "docker/$f" ps
    echo
done
