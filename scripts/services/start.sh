#!/bin/bash
# Start one service or all services per scripts/services.list, in tier order.
# Usage: start.sh [name|all]   (default: all)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=../lib/wait.sh
source "$REPO_ROOT/scripts/lib/wait.sh"
# shellcheck source=../lib/registry.sh
source "$REPO_ROOT/scripts/lib/registry.sh"

LOG_DIR="$REPO_ROOT/logs/services"
PID_DIR="$REPO_ROOT/logs/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

load_dotenv
load_vault_token
export PAYPAL_CLIENT_ID PAYPAL_CLIENT_SECRET PAYPAL_TUNNEL_URL

load_registry
check_drift || {
    log_err "Aborting due to registry drift — update scripts/services.list"
    exit 1
}

# Resolve a JDK for a service that pins a newer Java than the one on PATH.
# The ambient JDK can compile any `--release` <= its own major, so a service
# pinned to Java 17 or 21 builds fine on ambient 21 and keeps the ambient JDK
# (prints nothing). Only a pom asking for a *higher* release than the running
# JDK — mock-paypal-service pins Java 25 — needs a step-up. In that case we
# look up the lowest-major, highest-patch match in sdkman's candidate dir and
# echo its path; nothing is hardcoded to this machine. Empty output => caller
# launches under the ambient JDK unchanged.
service_java_home() {
    local dir=$1
    local pom="$dir/pom.xml"
    [ -f "$pom" ] || return 0
    local want have
    want=$(sed -n 's:.*<java\.version>\([0-9][0-9]*\)</java\.version>.*:\1:p' "$pom" | head -1)
    [ -n "$want" ] || return 0
    have=$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$have" ] && [ "$want" -le "$have" ] && return 0

    local sdk_root="${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java"
    [ -d "$sdk_root" ] || return 0
    local best="" best_major=0 cand major
    for cand in "$sdk_root"/*/; do
        cand=${cand%/}; cand=${cand##*/}
        [ "$cand" = "current" ] && continue
        major=${cand%%.*}; major=${major%%-*}
        case "$major" in ''|*[!0-9]*) continue;; esac
        [ "$major" -ge "$want" ] || continue
        if [ -z "$best" ] || [ "$major" -lt "$best_major" ] \
           || { [ "$major" -eq "$best_major" ] && [[ "$cand" > "$best" ]]; }; then
            best=$cand; best_major=$major
        fi
    done
    [ -n "$best" ] && echo "$sdk_root/$best"
}

start_one() {
    local name=$1
    local dir="$REPO_ROOT/$name"
    [ -d "$dir" ] || { log_err "Directory not found: $dir"; return 1; }

    if [ -f "$PID_DIR/$name.pid" ] && kill -0 "$(cat "$PID_DIR/$name.pid")" 2>/dev/null; then
        log_warn "$name already running (PID $(cat "$PID_DIR/$name.pid"))"
        return 0
    fi

    local jhome
    jhome=$(service_java_home "$dir")

    log_info "Starting $name..."
    if [ -n "$jhome" ]; then
        log_info "$name pins a newer Java than PATH — launching under ${jhome##*/}"
        (cd "$dir" && JAVA_HOME="$jhome" PATH="$jhome/bin:$PATH" mvn spring-boot:run) > "$LOG_DIR/$name.log" 2>&1 &
    else
        (cd "$dir" && mvn spring-boot:run) > "$LOG_DIR/$name.log" 2>&1 &
    fi
    echo $! > "$PID_DIR/$name.pid"
    log_ok "$name started (PID $!)"
}

wait_tier() {
    local tier=$1
    while IFS= read -r line; do
        local name http grpc t
        name=$(svc_field "$line" 1)
        http=$(svc_field "$line" 2)
        grpc=$(svc_field "$line" 3)
        t=$(svc_field "$line" 4)
        [ "$t" = "$tier" ] || continue
        wait_for_port "$name HTTP" "$http"
        if [ "$grpc" != "-" ]; then
            wait_for_port "$name gRPC" "$grpc"
        fi
    done < <(svc_list)
}

start_tier() {
    local tier=$1
    local started=0
    while IFS= read -r line; do
        local name t
        name=$(svc_field "$line" 1)
        t=$(svc_field "$line" 4)
        [ "$t" = "$tier" ] || continue
        start_one "$name"
        started=$((started + 1))
    done < <(svc_list)
    [ "$started" -eq 0 ] && return 0
    wait_tier "$tier"
}

target=${1:-all}

if [ "$target" = "all" ]; then
    for tier in 0 1 2 3; do
        start_tier "$tier"
    done
    log_ok "All services running"
else
    line=$(svc_get "$target") || { log_err "Unknown service: $target"; exit 1; }
    start_one "$target"
    http=$(svc_field "$line" 2)
    grpc=$(svc_field "$line" 3)
    wait_for_port "$target HTTP" "$http"
    if [ "$grpc" != "-" ]; then
        wait_for_port "$target gRPC" "$grpc"
    fi
fi
