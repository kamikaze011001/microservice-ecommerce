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

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

PID_DIR="$REPO_ROOT/logs/pids"
SERVICES_LIST="$REPO_ROOT/scripts/services.list"

port_for() {
    awk -v s="$1" '$1 !~ /^#/ && $1 == s {print $2; exit}' "$SERVICES_LIST"
}

kill_orphan_on_port() {
    local name=$1 port=$2
    [ -n "$port" ] && [ "$port" != "-" ] || return 0
    local orphans
    orphans=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    [ -n "$orphans" ] || return 0
    log_warn "$name: orphan(s) on :$port — killing $orphans"
    # shellcheck disable=SC2086
    kill $orphans 2>/dev/null || true
    sleep 1
    orphans=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$orphans" ]; then
        log_warn "$name: orphan(s) survived SIGTERM, sending SIGKILL"
        # shellcheck disable=SC2086
        kill -9 $orphans 2>/dev/null || true
    fi
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
    while read -r name port _grpc _tier; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue;; esac
        stop_one "$name"
    done < "$SERVICES_LIST"
    log_ok "All services stopped"
else
    stop_one "$target"
fi
