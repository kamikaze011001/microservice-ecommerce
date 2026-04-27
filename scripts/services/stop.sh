#!/bin/bash
# Stop one service or all started services. Usage: stop.sh [name|all]   (default: all)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

PID_DIR="$REPO_ROOT/logs/pids"

stop_one() {
    local name=$1
    local pid_file="$PID_DIR/$name.pid"
    [ -f "$pid_file" ] || { log_warn "$name has no pidfile"; return 0; }
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
}

target=${1:-all}

if [ "$target" = "all" ]; then
    [ -d "$PID_DIR" ] || { log_warn "No PID directory"; exit 0; }
    for f in "$PID_DIR"/*.pid; do
        [ -f "$f" ] || continue
        stop_one "$(basename "$f" .pid)"
    done
    log_ok "All services stopped"
else
    stop_one "$target"
fi
