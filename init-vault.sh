
#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "HashiCorp Vault Initialization Script"
echo "========================================="
echo ""

# Vault configuration
VAULT_ADDR="http://localhost:8200"
VAULT_INIT_FILE="vault-keys.json"

# Check if vault is accessible
check_vault() {
    echo -e "${BLUE}Checking Vault accessibility...${NC}"
    
    if ! curl -s "$VAULT_ADDR/v1/sys/health" > /dev/null; then
        echo -e "${RED}Error: Cannot connect to Vault at $VAULT_ADDR${NC}"
        echo "Please ensure Vault is running: ./start-infrastructure.sh"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Vault is accessible${NC}"
}

# Initialize Vault
init_vault() {
    echo -e "${BLUE}Initializing Vault...${NC}"
    
    # Check if already initialized
    status=$(curl -s "$VAULT_ADDR/v1/sys/init")
    if echo "$status" | grep -q '"initialized":true'; then
        echo -e "${YELLOW}Vault is already initialized${NC}"
        if [ ! -f "$VAULT_INIT_FILE" ]; then
            echo -e "${RED}Error: Vault is initialized but $VAULT_INIT_FILE not found${NC}"
            echo "Please provide the unseal keys and root token manually"
            exit 1
        fi
        return 0
    fi
    
    # Initialize with 5 key shares and threshold of 3
    echo "Initializing Vault with 5 key shares (threshold: 3)..."
    init_result=$(curl -s -X PUT -d '{"secret_shares":5,"secret_threshold":3}' "$VAULT_ADDR/v1/sys/init")
    
    # Save keys and token to file
    echo "$init_result" > "$VAULT_INIT_FILE"
    chmod 600 "$VAULT_INIT_FILE"
    
    echo -e "${GREEN}✓ Vault initialized successfully${NC}"
    echo -e "${YELLOW}⚠️  IMPORTANT: Vault keys saved to $VAULT_INIT_FILE - keep this file secure!${NC}"
}

# Unseal Vault
unseal_vault() {
    echo -e "${BLUE}Unsealing Vault...${NC}"
    
    # Check if already unsealed
    status=$(curl -s "$VAULT_ADDR/v1/sys/seal-status")
    if echo "$status" | grep -q '"sealed":false'; then
        echo -e "${GREEN}✓ Vault is already unsealed${NC}"
        return 0
    fi
    
    # Extract unseal keys from file
    key1=$(cat "$VAULT_INIT_FILE" | python3 -c "import sys, json; print(json.load(sys.stdin)['keys'][0])" 2>/dev/null || echo "")
    key2=$(cat "$VAULT_INIT_FILE" | python3 -c "import sys, json; print(json.load(sys.stdin)['keys'][1])" 2>/dev/null || echo "")
    key3=$(cat "$VAULT_INIT_FILE" | python3 -c "import sys, json; print(json.load(sys.stdin)['keys'][2])" 2>/dev/null || echo "")
    
    if [ -z "$key1" ] || [ -z "$key2" ] || [ -z "$key3" ]; then
        echo -e "${RED}Error: Cannot extract unseal keys from $VAULT_INIT_FILE${NC}"
        exit 1
    fi
    
    # Unseal with 3 keys (threshold)
    echo "Applying unseal key 1/3..."
    curl -s -X PUT -d "{\"key\":\"$key1\"}" "$VAULT_ADDR/v1/sys/unseal" > /dev/null
    
    echo "Applying unseal key 2/3..."
    curl -s -X PUT -d "{\"key\":\"$key2\"}" "$VAULT_ADDR/v1/sys/unseal" > /dev/null
    
    echo "Applying unseal key 3/3..."
    result=$(curl -s -X PUT -d "{\"key\":\"$key3\"}" "$VAULT_ADDR/v1/sys/unseal")
    
    if echo "$result" | grep -q '"sealed":false'; then
        echo -e "${GREEN}✓ Vault unsealed successfully${NC}"
    else
        echo -e "${RED}✗ Failed to unseal Vault${NC}"
        exit 1
    fi
}

# Function to load configuration from JSON file to Vault
load_config_to_vault() {
    local config_file=$1
    local vault_path=$2
    local root_token=$3
    
    if [ ! -f "$config_file" ]; then
        echo -e "${YELLOW}Warning: Config file $config_file not found, skipping...${NC}"
        return 0
    fi
    
    echo "Loading configuration from $config_file to $vault_path..."
    
    # Wrap the JSON content in Vault's data structure
    local vault_data=$(cat "$config_file" | jq '{data: .}')
    
    curl -s -X POST -H "X-Vault-Token: $root_token" \
        -d "$vault_data" \
        "$VAULT_ADDR/v1/secret/data/$vault_path" > /dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Loaded $config_file to $vault_path${NC}"
    else
        echo -e "${RED}✗ Failed to load $config_file to $vault_path${NC}"
    fi
}

# Configure Vault for the application
configure_vault() {
    echo -e "${BLUE}Configuring Vault for e-commerce application...${NC}"
    
    # Extract root token
    root_token=$(cat "$VAULT_INIT_FILE" | python3 -c "import sys, json; print(json.load(sys.stdin)['root_token'])" 2>/dev/null || echo "")
    
    if [ -z "$root_token" ]; then
        echo -e "${RED}Error: Cannot extract root token from $VAULT_INIT_FILE${NC}"
        exit 1
    fi
    
    export VAULT_TOKEN="$root_token"
    
    # Enable KV secrets engine
    echo "Enabling KV secrets engine..."
    curl -s -X POST -H "X-Vault-Token: $root_token" \
        -d '{"type":"kv","options":{"version":"2"}}' \
        "$VAULT_ADDR/v1/sys/mounts/secret" > /dev/null
    
    # Load service-specific configurations from JSON files
    echo "Loading service configurations..."
    
    # Common configuration for all services
    load_config_to_vault "docker/vault-configs/ecommerce-common.json" "ecommerce" "$root_token"
    
    # Service-specific configurations
    load_config_to_vault "docker/vault-configs/authorization-server.json" "authorization-server" "$root_token"
    load_config_to_vault "docker/vault-configs/gateway.json" "gateway" "$root_token"
    load_config_to_vault "docker/vault-configs/product-service.json" "product-service" "$root_token"
    load_config_to_vault "docker/vault-configs/inventory-service.json" "inventory-service" "$root_token"
    load_config_to_vault "docker/vault-configs/order-service.json" "order-service" "$root_token"
    load_config_to_vault "docker/vault-configs/payment-service.json" "payment-service" "$root_token"
    load_config_to_vault "docker/vault-configs/orchestrator-service.json" "orchestrator-service" "$root_token"
    
    echo -e "${GREEN}✓ Vault configured with all service configurations${NC}"
}

# Main execution
main() {
    cd "$(dirname "$0")"
    
    check_vault
    init_vault
    unseal_vault
    configure_vault
    
    echo ""
    echo "========================================="
    echo "VAULT INITIALIZATION COMPLETE"
    echo "========================================="
    echo ""
    echo -e "${GREEN}🎉 Vault is ready for the e-commerce application!${NC}"
    echo ""
    echo "📋 VAULT INFORMATION:"
    echo "   Vault URL:    $VAULT_ADDR"
    echo "   UI Access:    $VAULT_ADDR/ui"
    echo "   Keys File:    $VAULT_INIT_FILE"
    echo ""
    
    # Show root token
    root_token=$(cat "$VAULT_INIT_FILE" | python3 -c "import sys, json; print(json.load(sys.stdin)['root_token'])" 2>/dev/null || echo "Not available")
    echo -e "${YELLOW}🔑 Root Token: $root_token${NC}"
    echo ""
    
    echo "🔐 CONFIGURED SECRETS:"
    echo "   /secret/ecommerce           - Common database, Redis, MongoDB, Kafka, email configs"
    echo "   /secret/authorization-server - JWT token lifetimes and authentication key"
    echo "   /secret/gateway             - JWT validation and caching settings"
    echo "   /secret/product-service     - Kafka topics for product events"
    echo "   /secret/inventory-service   - gRPC port and inventory Kafka topics"
    echo "   /secret/order-service       - gRPC client config and order Kafka topics"
    echo "   /secret/payment-service     - PayPal API credentials and webhook paths"
    echo "   /secret/orchestrator-service - Orchestration Kafka topics and groups"
    echo ""
    
    echo -e "${YELLOW}⚠️  SECURITY NOTES:${NC}"
    echo "   1. Store $VAULT_INIT_FILE securely - it contains unseal keys"
    echo "   2. Update PayPal and Email secrets with real credentials"
    echo "   3. Generate proper JWT keys for production"
    echo "   4. Use Vault policies for production deployments"
    echo ""
}

# Handle script arguments
case "${1:-init}" in
    "init")
        main
        ;;
    "unseal")
        check_vault
        unseal_vault
        echo -e "${GREEN}✓ Vault unsealed${NC}"
        ;;
    "status")
        echo "Vault Status:"
        curl -s "$VAULT_ADDR/v1/sys/health" | python3 -m json.tool 2>/dev/null || echo "Cannot connect to Vault"
        ;;
    *)
        echo "Usage: $0 {init|unseal|status}"
        echo ""
        echo "Commands:"
        echo "  init    - Initialize and configure Vault (default)"
        echo "  unseal  - Unseal Vault using saved keys"
        echo "  status  - Show Vault status"
        exit 1
        ;;
esac