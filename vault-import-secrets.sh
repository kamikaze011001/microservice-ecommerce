#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "Vault Secrets Import Script"
echo "========================================="
echo ""

# Configuration
VAULT_ADDR="http://localhost:8200"
VAULT_INIT_FILE="vault-keys.json"
VAULT_CONFIGS_DIR="docker/vault-configs"

# Function to check if Vault is running and unsealed
check_vault_ready() {
    echo -e "${BLUE}Checking Vault status...${NC}"
    
    # Check if running
    if ! curl -s "$VAULT_ADDR/v1/sys/health" > /dev/null; then
        echo -e "${RED}❌ Vault is not running at $VAULT_ADDR${NC}"
        echo "Please start Vault first: ./start-infrastructure.sh"
        exit 1
    fi
    
    # Check if sealed
    status=$(curl -s "$VAULT_ADDR/v1/sys/seal-status")
    if echo "$status" | grep -q '"sealed":true'; then
        echo -e "${RED}❌ Vault is sealed${NC}"
        echo "Please unseal Vault first: ./init-vault.sh unseal"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Vault is running and unsealed${NC}"
}

# Function to get root token
get_root_token() {
    if [ ! -f "$VAULT_INIT_FILE" ]; then
        echo -e "${RED}❌ Vault keys file not found: $VAULT_INIT_FILE${NC}"
        echo "Please initialize Vault first: ./init-vault.sh"
        exit 1
    fi
    
    root_token=$(cat "$VAULT_INIT_FILE" | python3 -c "import sys, json; print(json.load(sys.stdin)['root_token'])" 2>/dev/null || echo "")
    
    if [ -z "$root_token" ]; then
        echo -e "${RED}❌ Cannot extract root token from $VAULT_INIT_FILE${NC}"
        exit 1
    fi
    
    echo "$root_token"
}

# Function to enable KV secrets engine if not already enabled
enable_kv_engine() {
    local token=$1
    
    echo -e "${BLUE}Checking KV secrets engine...${NC}"
    
    # Check if secret mount exists
    mounts=$(curl -s -H "X-Vault-Token: $token" "$VAULT_ADDR/v1/sys/mounts")
    
    if echo "$mounts" | grep -q '"secret/"'; then
        echo -e "${GREEN}✅ KV secrets engine already enabled${NC}"
    else
        echo -e "${YELLOW}Enabling KV secrets engine...${NC}"
        curl -s -X POST -H "X-Vault-Token: $token" \
            -d '{"type":"kv","options":{"version":"2"}}' \
            "$VAULT_ADDR/v1/sys/mounts/secret" > /dev/null
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ KV secrets engine enabled${NC}"
        else
            echo -e "${RED}❌ Failed to enable KV secrets engine${NC}"
            exit 1
        fi
    fi
}

# Function to import a single JSON config file to Vault
import_config_file() {
    local config_file=$1
    local vault_path=$2
    local token=$3
    
    if [ ! -f "$config_file" ]; then
        echo -e "${YELLOW}⚠️  Config file not found: $config_file (skipping)${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Importing $config_file → /secret/$vault_path${NC}"
    
    # Validate JSON first
    if ! python3 -m json.tool "$config_file" > /dev/null 2>&1; then
        echo -e "${RED}❌ Invalid JSON in $config_file${NC}"
        return 1
    fi
    
    # Wrap the JSON content in Vault's KV v2 data structure
    vault_payload=$(python3 -c "
import json
import sys

try:
    with open('$config_file', 'r') as f:
        config_data = json.load(f)
    
    vault_data = {'data': config_data}
    print(json.dumps(vault_data))
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to prepare data for $config_file${NC}"
        return 1
    fi
    
    # Import to Vault
    response=$(curl -s -w "%{http_code}" -X POST -H "X-Vault-Token: $token" \
        -d "$vault_payload" \
        "$VAULT_ADDR/v1/secret/data/$vault_path")
    
    http_code="${response: -3}"
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        echo -e "${GREEN}✅ Successfully imported $config_file${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to import $config_file (HTTP: $http_code)${NC}"
        return 1
    fi
}

# Function to import all configuration files
import_all_configs() {
    local token=$1
    local success_count=0
    local total_count=0
    
    echo ""
    echo -e "${BLUE}Starting import of all configuration files...${NC}"
    echo ""
    
    # List of configurations to import
    declare -A configs=(
        ["$VAULT_CONFIGS_DIR/ecommerce-common.json"]="ecommerce"
        ["$VAULT_CONFIGS_DIR/authorization-server.json"]="authorization-server"
        ["$VAULT_CONFIGS_DIR/gateway.json"]="gateway"
        ["$VAULT_CONFIGS_DIR/product-service.json"]="product-service"
        ["$VAULT_CONFIGS_DIR/inventory-service.json"]="inventory-service"
        ["$VAULT_CONFIGS_DIR/order-service.json"]="order-service"
        ["$VAULT_CONFIGS_DIR/payment-service.json"]="payment-service"
        ["$VAULT_CONFIGS_DIR/orchestrator-service.json"]="orchestrator-service"
    )
    
    # Import each configuration
    for config_file in "${!configs[@]}"; do
        vault_path="${configs[$config_file]}"
        total_count=$((total_count + 1))
        
        if import_config_file "$config_file" "$vault_path" "$token"; then
            success_count=$((success_count + 1))
        fi
        echo ""
    done
    
    echo "========================================="
    echo "IMPORT SUMMARY"
    echo "========================================="
    echo -e "${GREEN}Successfully imported: $success_count/$total_count configurations${NC}"
    
    if [ $success_count -eq $total_count ]; then
        echo -e "${GREEN}🎉 All configurations imported successfully!${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️  Some configurations failed to import${NC}"
        return 1
    fi
}

# Function to verify imported secrets
verify_secrets() {
    local token=$1
    
    echo ""
    echo -e "${BLUE}Verifying imported secrets...${NC}"
    echo ""
    
    # List all secrets
    secrets_response=$(curl -s -H "X-Vault-Token: $token" "$VAULT_ADDR/v1/secret/metadata?list=true")
    
    if echo "$secrets_response" | grep -q '"keys"'; then
        echo -e "${GREEN}📋 Available secrets:${NC}"
        echo "$secrets_response" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    if 'data' in data and 'keys' in data['data']:
        for key in sorted(data['data']['keys']):
            print(f'   ✓ /secret/{key}')
    else:
        print('   No secrets found')
except:
    print('   Error reading secrets list')
"
    else
        echo -e "${YELLOW}⚠️  No secrets found or error reading secrets${NC}"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  import     - Import all configuration files (default)"
    echo "  verify     - Verify imported secrets"
    echo "  single     - Import single config file"
    echo "  help       - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Import all configs"
    echo "  $0 import            # Import all configs"
    echo "  $0 verify            # Verify imported secrets"
    echo "  $0 single ecommerce-common.json ecommerce  # Import single file"
}

# Function to import single config
import_single() {
    local filename=$1
    local vault_path=$2
    local token=$3
    
    if [ -z "$filename" ] || [ -z "$vault_path" ]; then
        echo -e "${RED}❌ Usage: $0 single <filename> <vault-path>${NC}"
        echo "Example: $0 single ecommerce-common.json ecommerce"
        exit 1
    fi
    
    local full_path="$VAULT_CONFIGS_DIR/$filename"
    import_config_file "$full_path" "$vault_path" "$token"
}

# Main execution
main() {
    cd "$(dirname "$0")"
    
    local command="${1:-import}"
    
    check_vault_ready
    
    echo -e "${BLUE}Getting authentication token...${NC}"
    root_token=$(get_root_token)
    
    enable_kv_engine "$root_token"
    
    case "$command" in
        "import")
            import_all_configs "$root_token"
            verify_secrets "$root_token"
            ;;
        "verify")
            verify_secrets "$root_token"
            ;;
        "single")
            import_single "$2" "$3" "$root_token"
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            echo -e "${RED}❌ Unknown command: $command${NC}"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"