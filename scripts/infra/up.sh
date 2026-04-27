#!/bin/bash
# Bring up all infrastructure containers (MySQL, Redis, MongoDB, Kafka, Vault).
# Idempotent: docker compose up -d skips already-running containers.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

load_dotenv

if ! docker info >/dev/null 2>&1; then
    log_err "Docker is not running"
    exit 1
fi

cd "$REPO_ROOT"

start_compose() {
    local file=$1 label=$2
    log_info "Starting $label..."
    if docker compose -f "docker/$file" up -d; then
        log_ok "$label started"
    else
        log_err "Failed to start $label"
        exit 1
    fi
}

start_compose "mysql.yml"   "MySQL cluster"
start_compose "redis.yml"   "Redis"
start_compose "mongodb.yml" "MongoDB"
start_compose "kafka.yml"   "Kafka ecosystem"
start_compose "vault.yml"   "Vault"

log_ok "Infrastructure up"
