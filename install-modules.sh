#!/bin/bash

set -e

echo "========================================="
echo "Maven Modules Installation Script"
echo "========================================="
echo "This script will install all Maven modules in dependency order"
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to install a module
install_module() {
    local module_path=$1
    local module_name=$2
    
    echo -e "${BLUE}Installing ${module_name}...${NC}"
    cd "$module_path"
    
    if mvn clean install -DskipTests; then
        echo -e "${GREEN}✓ ${module_name} installed successfully${NC}"
    else
        echo -e "${RED}✗ Failed to install ${module_name}${NC}"
        exit 1
    fi
    
    cd - > /dev/null
    echo ""
}

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
echo "Working directory: $SCRIPT_DIR"
echo ""

# Core modules installation (in dependency order)
echo "========================================="
echo "PHASE 1: Installing Core Modules"
echo "========================================="

install_module "$SCRIPT_DIR/core/common-dto" "common-dto"
install_module "$SCRIPT_DIR/core/grpc-common" "grpc-common" 
install_module "$SCRIPT_DIR/core/core-jwt-util" "core-jwt-util"
install_module "$SCRIPT_DIR/core/core-redis" "core-redis"
install_module "$SCRIPT_DIR/core/core-routing-db" "core-routing-db"
install_module "$SCRIPT_DIR/core/core-paypal" "core-paypal"
install_module "$SCRIPT_DIR/core/core-email" "core-email"
install_module "$SCRIPT_DIR/core/core-exception-api" "core-exception-api"

echo "========================================="
echo "PHASE 2: Installing Service Modules"
echo "========================================="

# Infrastructure services first
install_module "$SCRIPT_DIR/eureka-server" "eureka-server"

# Core business services
install_module "$SCRIPT_DIR/authorization-server" "authorization-server"
install_module "$SCRIPT_DIR/gateway" "gateway"
install_module "$SCRIPT_DIR/product-service" "product-service"
install_module "$SCRIPT_DIR/inventory-service" "inventory-service"
install_module "$SCRIPT_DIR/order-service" "order-service"
install_module "$SCRIPT_DIR/payment-service" "payment-service"
install_module "$SCRIPT_DIR/orchestrator-service" "orchestrator-service"

echo "========================================="
echo "INSTALLATION COMPLETE"
echo "========================================="
echo -e "${GREEN}All modules have been successfully installed!${NC}"
echo ""
echo "Next steps:"
echo "1. Start the infrastructure services (MySQL, Redis, Kafka, Vault)"
echo "2. Run individual services with: mvn spring-boot:run"
echo "3. Access services through the gateway at: http://localhost:8080"
echo ""