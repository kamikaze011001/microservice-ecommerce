#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "Vault Login Helper Script"
echo "========================================="
echo ""

# Configuration
VAULT_ADDR="http://localhost:8200"
VAULT_INIT_FILE="vault-keys.json"

# Function to check if Vault is running
check_vault_running() {
    if ! curl -s "$VAULT_ADDR/v1/sys/health" > /dev/null; then
        echo -e "${RED}❌ Vault is not running at $VAULT_ADDR${NC}"
        echo "Please start Vault first:"
        echo "  ./start-infrastructure.sh"
        exit 1
    fi
    echo -e "${GREEN}✅ Vault is running${NC}"
}

# Function to check if Vault is sealed
check_vault_sealed() {
    status=$(curl -s "$VAULT_ADDR/v1/sys/seal-status")
    if echo "$status" | grep -q '"sealed":true'; then
        echo -e "${YELLOW}🔒 Vault is sealed. Attempting to unseal...${NC}"
        ./init-vault.sh unseal
        echo ""
    else
        echo -e "${GREEN}🔓 Vault is unsealed${NC}"
    fi
}

# Function to get root token
get_root_token() {
    if [ ! -f "$VAULT_INIT_FILE" ]; then
        echo -e "${RED}❌ Vault keys file not found: $VAULT_INIT_FILE${NC}"
        echo "Please initialize Vault first:"
        echo "  ./init-vault.sh"
        exit 1
    fi
    
    root_token=$(cat "$VAULT_INIT_FILE" | python3 -c "import sys, json; print(json.load(sys.stdin)['root_token'])" 2>/dev/null || echo "")
    
    if [ -z "$root_token" ]; then
        echo -e "${RED}❌ Cannot extract root token from $VAULT_INIT_FILE${NC}"
        exit 1
    fi
    
    echo "$root_token"
}

# Function to set environment variables
set_vault_env() {
    local token=$1
    
    echo "export VAULT_ADDR=\"$VAULT_ADDR\""
    echo "export VAULT_TOKEN=\"$token\""
    echo ""
    echo -e "${YELLOW}💡 To set these in your current session, run:${NC}"
    echo -e "${BLUE}source <(./vault-login.sh env)${NC}"
}

# Function to open browser
open_browser() {
    local token=$1
    
    echo -e "${BLUE}🌐 Opening Vault UI in browser...${NC}"
    
    # Try different browsers
    if command -v xdg-open > /dev/null; then
        xdg-open "$VAULT_ADDR/ui" > /dev/null 2>&1 &
    elif command -v open > /dev/null; then
        open "$VAULT_ADDR/ui" > /dev/null 2>&1 &
    elif command -v google-chrome > /dev/null; then
        google-chrome "$VAULT_ADDR/ui" > /dev/null 2>&1 &
    elif command -v firefox > /dev/null; then
        firefox "$VAULT_ADDR/ui" > /dev/null 2>&1 &
    else
        echo -e "${YELLOW}Cannot auto-open browser. Please go to: $VAULT_ADDR/ui${NC}"
    fi
}

# Function to show secrets info
show_secrets_info() {
    echo -e "${BLUE}📋 CONFIGURED SECRETS:${NC}"
    echo "   /secret/ecommerce           - Database, Redis, MongoDB, Kafka, email configs"
    echo "   /secret/authorization-server - JWT token lifetimes and authentication"
    echo "   /secret/gateway             - JWT validation and caching settings"
    echo "   /secret/product-service     - Kafka topics for product events"
    echo "   /secret/inventory-service   - gRPC port and inventory Kafka topics"
    echo "   /secret/order-service       - gRPC client and order Kafka topics"
    echo "   /secret/payment-service     - PayPal API credentials"
    echo "   /secret/orchestrator-service - Orchestration Kafka topics"
}

# Function to test token
test_token() {
    local token=$1
    
    echo -e "${BLUE}🧪 Testing token access...${NC}"
    
    response=$(curl -s -H "X-Vault-Token: $token" "$VAULT_ADDR/v1/auth/token/lookup-self")
    
    if echo "$response" | grep -q '"errors"'; then
        echo -e "${RED}❌ Token test failed${NC}"
        return 1
    else
        echo -e "${GREEN}✅ Token is valid${NC}"
        return 0
    fi
}

# Main execution
main() {
    cd "$(dirname "$0")"
    
    check_vault_running
    check_vault_sealed
    
    echo ""
    echo -e "${BLUE}🔑 Getting root token...${NC}"
    root_token=$(get_root_token)
    
    if test_token "$root_token"; then
        echo ""
        echo "========================================="
        echo "VAULT LOGIN INFORMATION"
        echo "========================================="
        echo ""
        echo -e "${GREEN}🎉 Vault login ready!${NC}"
        echo ""
        echo -e "${YELLOW}🔐 ROOT TOKEN:${NC}"
        echo "$root_token"
        echo ""
        echo -e "${YELLOW}🌐 VAULT UI:${NC}"
        echo "$VAULT_ADDR/ui"
        echo ""
        show_secrets_info
        echo ""
        echo -e "${YELLOW}⚙️  ENVIRONMENT VARIABLES:${NC}"
        set_vault_env "$root_token"
        
        # Ask if user wants to open browser
        echo ""
        read -p "Open Vault UI in browser? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            open_browser "$root_token"
        fi
        
    else
        echo -e "${RED}❌ Login failed${NC}"
        exit 1
    fi
}

# Handle script arguments
case "${1:-login}" in
    "login")
        main
        ;;
    "env")
        # Just output environment variables for sourcing
        root_token=$(get_root_token)
        echo "export VAULT_ADDR=\"$VAULT_ADDR\""
        echo "export VAULT_TOKEN=\"$root_token\""
        ;;
    "token")
        # Just output the token
        get_root_token
        ;;
    "ui"|"open")
        # Open UI
        root_token=$(get_root_token)
        open_browser "$root_token"
        echo "Opening $VAULT_ADDR/ui"
        echo "Token: $root_token"
        ;;
    *)
        echo "Usage: $0 {login|env|token|ui}"
        echo ""
        echo "Commands:"
        echo "  login  - Full login process with info (default)"
        echo "  env    - Output environment variables for sourcing"
        echo "  token  - Just output the root token"
        echo "  ui     - Open Vault UI in browser"
        echo ""
        echo "Examples:"
        echo "  ./vault-login.sh              # Full login process"
        echo "  source <(./vault-login.sh env) # Set env vars"
        echo "  ./vault-login.sh ui           # Open browser"
        exit 1
        ;;
esac