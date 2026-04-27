#!/bin/bash
# Tail logs for a service. Usage: logs.sh <name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

name=${1:-}
[ -z "$name" ] && { log_err "Usage: logs.sh <service-name>"; exit 1; }

log_file="$REPO_ROOT/logs/services/$name.log"
[ -f "$log_file" ] || { log_err "No log: $log_file"; exit 1; }

exec tail -f "$log_file"
