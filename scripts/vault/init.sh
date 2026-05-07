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

# Sync the fresh root token back into docker/.env so the vault CLI / e2e docs
# don't keep pointing at a dead token after `make nuke`. Without this, every
# fresh bootstrap leaves VAULT_TOKEN stale and hand-run vault commands fail
# with "permission denied / invalid token".
ENV_FILE="$REPO_ROOT/docker/.env"
ROOT_TOKEN=$(grep -o '"root_token":"[^"]*"' "$KEYS_FILE" | cut -d'"' -f4)
if [ -n "$ROOT_TOKEN" ] && [ -f "$ENV_FILE" ]; then
    if grep -q '^VAULT_TOKEN=' "$ENV_FILE"; then
        # In-place rewrite. Use a tmp file for portability across BSD/GNU sed.
        awk -v tok="$ROOT_TOKEN" '/^VAULT_TOKEN=/{print "VAULT_TOKEN=" tok; next} {print}' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
    else
        printf '\nVAULT_TOKEN=%s\n' "$ROOT_TOKEN" >> "$ENV_FILE"
    fi
    log_ok "VAULT_TOKEN synced into docker/.env"
fi
