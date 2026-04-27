#!/bin/bash
# Parse scripts/services.list. Source, don't execute.
# After sourcing services.list, $SERVICES holds an array of "name port grpc tier" strings.
# This file exposes helpers for iterating that array.

REGISTRY_FILE="$REPO_ROOT/scripts/services.list"

# Load $SERVICES from the registry file.
load_registry() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        log_err "scripts/services.list not found"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$REGISTRY_FILE"
}

# svc_field <line> <field_index>  (1-indexed: 1=name, 2=http, 3=grpc, 4=tier)
svc_field() {
    echo "$1" | awk -v i="$2" '{print $i}'
}

# Iterate registry: prints "name http grpc tier" one per line.
svc_list() {
    for line in "${SERVICES[@]}"; do
        echo "$line"
    done
}

# Get the registry line for a single service name. Returns 1 if not found.
svc_get() {
    local name=$1
    for line in "${SERVICES[@]}"; do
        if [ "$(svc_field "$line" 1)" = "$name" ]; then
            echo "$line"
            return 0
        fi
    done
    return 1
}

# Drift guard: warn if any *-service / gateway / eureka-server directory
# exists in the repo root but is not in the registry.
check_drift() {
    local registered drift_found=0
    registered=$(svc_list | awk '{print $1}')
    for dir in "$REPO_ROOT"/*-service "$REPO_ROOT"/gateway "$REPO_ROOT"/eureka-server; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        if ! echo "$registered" | grep -qx "$name"; then
            log_err "Drift: directory '$name' exists but is not in scripts/services.list"
            drift_found=1
        fi
    done
    [ "$drift_found" -eq 0 ]
}
