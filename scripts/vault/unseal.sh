#!/bin/bash
# Unseal Vault using keys from vault-keys.json. Idempotent: exits 0 if already unsealed.

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

status=$(curl -s "$VAULT_ADDR/v1/sys/seal-status")
if echo "$status" | grep -q '"sealed":false'; then
    log_ok "Vault already unsealed"
    exit 0
fi

if [ ! -f "$KEYS_FILE" ]; then
    log_err "Vault not initialized — run 'make bootstrap' first."
    exit 1
fi

for i in 0 1 2; do
    key=$(python3 -c "import sys, json; print(json.load(open('$KEYS_FILE'))['keys'][$i])")
    [ -z "$key" ] && { log_err "Cannot extract unseal key $i"; exit 1; }
    log_info "Applying unseal key $((i+1))/3..."
    curl -s -X PUT -d "{\"key\":\"$key\"}" "$VAULT_ADDR/v1/sys/unseal" >/dev/null
done

result=$(curl -s "$VAULT_ADDR/v1/sys/seal-status")
if echo "$result" | grep -q '"sealed":false'; then
    log_ok "Vault unsealed"
else
    log_err "Failed to unseal Vault"
    exit 1
fi
