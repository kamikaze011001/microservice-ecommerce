#!/bin/bash
# First-run Vault init: creates 5 unseal keys + root token, saves to vault-keys.json.
# Idempotent: skips if Vault is already initialized.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
KEYS_FILE="$REPO_ROOT/vault-keys.json"

if ! curl -s "$VAULT_ADDR/v1/sys/health" >/dev/null; then
    log_err "Vault not reachable at $VAULT_ADDR"
    exit 1
fi

status=$(curl -s "$VAULT_ADDR/v1/sys/init")
if echo "$status" | grep -q '"initialized":true'; then
    log_warn "Vault already initialized"
    if [ ! -f "$KEYS_FILE" ]; then
        log_err "Vault initialized but $KEYS_FILE missing — cannot recover"
        exit 1
    fi
    exit 0
fi

log_info "Initializing Vault (5 shares, threshold 3)..."
init_result=$(curl -s -X PUT -d '{"secret_shares":5,"secret_threshold":3}' "$VAULT_ADDR/v1/sys/init")
echo "$init_result" > "$KEYS_FILE"
chmod 600 "$KEYS_FILE"
log_ok "Vault initialized — keys saved to vault-keys.json"
