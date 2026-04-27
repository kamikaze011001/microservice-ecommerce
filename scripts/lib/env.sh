#!/bin/bash
# Load docker/.env and (optionally) extract VAULT_TOKEN from vault-keys.json.
# Source, don't execute. Caller decides whether vault token is required.

# Resolves repo root from any caller location: $REPO_ROOT is exported.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

load_dotenv() {
    if [ -f "$REPO_ROOT/docker/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        source "$REPO_ROOT/docker/.env"
        set +a
        log_ok "Loaded docker/.env"
    else
        log_err "docker/.env not found — copy from docker/.env.example and fill in values"
        return 1
    fi
}

load_vault_token() {
    if [ ! -f "$REPO_ROOT/vault-keys.json" ]; then
        log_err "vault-keys.json not found — run 'make bootstrap' first"
        return 1
    fi
    VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('$REPO_ROOT/vault-keys.json'))['root_token'])" 2>/dev/null)
    if [ -z "$VAULT_TOKEN" ]; then
        log_err "Could not extract VAULT_TOKEN from vault-keys.json"
        return 1
    fi
    export VAULT_TOKEN
    log_ok "VAULT_TOKEN loaded"
}
