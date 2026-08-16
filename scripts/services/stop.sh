#!/bin/bash
# Stop one service or all started services. Usage: stop.sh [name|all]   (default: all)
#
# Two-step kill per service:
#   1. SIGTERM the PID in logs/pids/<name>.pid (if present)
#   2. Fallback: kill anything still listening on the service's canonical port
#      from scripts/services.list. Without step 2, orphans started outside the
#      pidfile system (direct `mvn spring-boot:run`, sessions before pidfile
#      tracking existed) survive `make nuke` and silently break fresh
#      bootstraps — the port stays bound, so a new boot crashes on the
#      Atomikos transaction-log lock and seed-data fails on missing tables.
#      Step 2 is also the only thing that reaps `pnpm dev`'s forked Vite child,
#      whose PID is not the one we wrote to the pidfile.
#
# services.list stores entries as quoted bash array elements, so it MUST be read
# through registry.sh (which sources it, letting bash strip the quotes). Parsing
# the raw text yields names like `"gateway` and silently stops nothing.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/registry.sh
source "$REPO_ROOT/scripts/lib/registry.sh"
# shellcheck source=../lib/proc.sh
source "$REPO_ROOT/scripts/lib/proc.sh"

PID_DIR="$REPO_ROOT/logs/pids"

load_registry

port_for() {
    local line
    line=$(svc_get "$1") || return 0
    svc_field "$line" 2
}

stop_one() {
    local name=$1
    local pid_file="$PID_DIR/$name.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Stopping $name (PID $pid)..."
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
            log_ok "$name stopped"
        else
            log_warn "$name (PID $pid) was not running"
        fi
        rm -f "$pid_file"
    fi
    kill_orphan_on_port "$name" "$(port_for "$name")"
}

target=${1:-all}

if [ "$target" = "all" ]; then
    # Iterate every service in services.list — covers both pidfile-tracked
    # processes AND port orphans that have no pidfile.
    while IFS= read -r line; do
        stop_one "$(svc_field "$line" 1)"
    done < <(svc_list)
    log_ok "All services stopped"
else
    svc_get "$target" >/dev/null || { log_err "Unknown service: $target"; exit 1; }
    stop_one "$target"
fi
