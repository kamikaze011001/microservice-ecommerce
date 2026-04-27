#!/bin/bash
# Enable KV v2 and load all docker/vault-configs/*.json into Vault.
# Idempotent: KV mount is created if missing; uploads overwrite previous data.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"

load_vault_token
[ -z "${VAULT_TOKEN:-}" ] && { log_err "VAULT_TOKEN not set"; exit 1; }

# Enable KV v2 secrets engine (no-op if already mounted)
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
    -d '{"type":"kv","options":{"version":"2"}}' \
    "$VAULT_ADDR/v1/sys/mounts/secret" >/dev/null || true

load_config() {
    local config_file=$1 vault_path=$2
    if [ ! -f "$config_file" ]; then
        log_warn "Skipping missing $config_file"
        return 0
    fi
    log_info "Importing $(basename "$config_file") -> secret/$vault_path"
    local payload
    payload=$(jq '{data: .}' "$config_file")
    curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
        -d "$payload" \
        "$VAULT_ADDR/v1/secret/data/$vault_path" >/dev/null
}

CFG_DIR="$REPO_ROOT/docker/vault-configs"
load_config "$CFG_DIR/ecommerce-common.json"        "ecommerce"
load_config "$CFG_DIR/authorization-server.json"    "authorization-server"
load_config "$CFG_DIR/gateway.json"                 "gateway"
load_config "$CFG_DIR/product-service.json"         "product-service"
load_config "$CFG_DIR/inventory-service.json"       "inventory-service"
load_config "$CFG_DIR/order-service.json"           "order-service"
load_config "$CFG_DIR/payment-service.json"         "payment-service"
load_config "$CFG_DIR/orchestrator-service.json"    "orchestrator-service"

log_ok "Vault secrets imported"
