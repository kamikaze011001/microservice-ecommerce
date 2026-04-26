#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/logs/services"
PID_DIR="$SCRIPT_DIR/logs/pids"

# =============================================================================
# ENV SETUP
# =============================================================================

load_env() {
    echo -e "${BLUE}Loading environment variables...${NC}"

    # Load docker/.env
    if [ -f "docker/.env" ]; then
        set -a
        source "docker/.env"
        set +a
        echo -e "${GREEN}✓ Loaded docker/.env${NC}"
    else
        echo -e "${RED}✗ docker/.env not found — copy from docker/.env.example and fill in values${NC}"
        exit 1
    fi

    # Extract VAULT_TOKEN from vault-keys.json (overrides empty value from .env)
    if [ -f "vault-keys.json" ]; then
        VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('vault-keys.json'))['root_token'])" 2>/dev/null || echo "")
        if [ -z "$VAULT_TOKEN" ]; then
            echo -e "${RED}✗ Could not extract VAULT_TOKEN from vault-keys.json${NC}"
            exit 1
        fi
        export VAULT_TOKEN
        echo -e "${GREEN}✓ VAULT_TOKEN loaded from vault-keys.json${NC}"
    else
        echo -e "${RED}✗ vault-keys.json not found — run ./init-vault.sh first${NC}"
        exit 1
    fi

    # Export PayPal credentials (needed by payment-service before Vault loads)
    export PAYPAL_CLIENT_ID
    export PAYPAL_CLIENT_SECRET
    export PAYPAL_TUNNEL_URL

    echo -e "${GREEN}✓ Environment ready${NC}"
    echo ""
}

# =============================================================================
# HELPERS
# =============================================================================

wait_for_port() {
    local service=$1
    local port=$2
    local max_attempts=${3:-36}   # 36 * 5s = 3 minutes max
    local attempt=1

    echo -e "${BLUE}Waiting for $service (port $port)...${NC}"
    while [ $attempt -le $max_attempts ]; do
        if (echo > /dev/tcp/localhost/$port) 2>/dev/null; then
            echo -e "${GREEN}✓ $service is up${NC}"
            return 0
        fi
        echo "  [$attempt/$max_attempts] Not ready yet..."
        sleep 5
        attempt=$((attempt + 1))
    done

    echo -e "${RED}✗ $service failed to start on port $port — check logs/$service.log${NC}"
    return 1
}

start_service() {
    local name=$1
    local dir="$SCRIPT_DIR/$name"

    if [ ! -d "$dir" ]; then
        echo -e "${RED}✗ Directory not found: $dir${NC}"
        exit 1
    fi

    mkdir -p "$LOG_DIR" "$PID_DIR"

    echo -e "${BLUE}Starting $name...${NC}"
    (cd "$dir" && mvn spring-boot:run) > "$LOG_DIR/$name.log" 2>&1 &
    echo $! > "$PID_DIR/$name.pid"
    echo -e "${GREEN}  Started (PID $!)${NC}"
}

# =============================================================================
# START
# =============================================================================

start_all() {
    load_env

    echo "========================================="
    echo "  Starting Spring Microservices"
    echo "========================================="
    echo ""

    # 1. Eureka — everything else registers here
    start_service "eureka-server"
    wait_for_port "eureka-server" 8761

    # 2. Auth + Gateway — can come up in parallel
    start_service "authorization-server"
    start_service "gateway"
    wait_for_port "authorization-server" 6666
    wait_for_port "gateway" 6868

    # 3. Inventory — must be up before order-service (gRPC on 9090)
    start_service "inventory-service"
    wait_for_port "inventory-service HTTP" 6969
    wait_for_port "inventory-service gRPC" 9090

    # 4. Remaining services — order-service depends on inventory gRPC being ready
    start_service "product-service"
    start_service "order-service"
    start_service "payment-service"
    start_service "orchestrator-service"

    wait_for_port "product-service" 7777
    wait_for_port "order-service" 9696
    wait_for_port "payment-service" 8484
    wait_for_port "orchestrator-service" 9999

    echo ""
    echo "========================================="
    echo -e "${GREEN}🎉 All services are running!${NC}"
    echo "========================================="
    echo ""
    echo "📋 ENDPOINTS:"
    echo "   Swagger UI:           http://localhost:6868/swagger-ui.html"
    echo "   Eureka Dashboard:     http://localhost:8761"
    echo "   Authorization Server: http://localhost:6666"
    echo "   Product Service:      http://localhost:7777"
    echo "   Inventory Service:    http://localhost:6969"
    echo "   Order Service:        http://localhost:9696"
    echo "   Payment Service:      http://localhost:8484"
    echo "   Orchestrator Service: http://localhost:9999"
    echo ""
    echo "📁 LOGS: $LOG_DIR/"
    echo ""
}

# =============================================================================
# STOP
# =============================================================================

stop_all() {
    echo -e "${BLUE}Stopping all Spring services...${NC}"

    if [ ! -d "$PID_DIR" ]; then
        echo -e "${YELLOW}No PID files found — services may not have been started with this script${NC}"
        return 0
    fi

    for pid_file in "$PID_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        local name=$(basename "$pid_file" .pid)
        local pid=$(cat "$pid_file")

        if kill -0 "$pid" 2>/dev/null; then
            echo "  Stopping $name (PID $pid)..."
            # Kill the entire process group (mvn spawns child JVM processes)
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null
            echo -e "${GREEN}  ✓ $name stopped${NC}"
        else
            echo -e "${YELLOW}  $name (PID $pid) was not running${NC}"
        fi
        rm -f "$pid_file"
    done

    echo -e "${GREEN}✓ All services stopped${NC}"
}

# =============================================================================
# STATUS
# =============================================================================

status_all() {
    echo "========================================="
    echo "  Spring Services Status"
    echo "========================================="

    declare -A SERVICE_PORTS=(
        [eureka-server]=8761
        [authorization-server]=6666
        [gateway]=6868
        [inventory-service]=6969
        [product-service]=7777
        [order-service]=9696
        [payment-service]=8484
        [orchestrator-service]=9999
    )

    for service in eureka-server authorization-server gateway inventory-service product-service order-service payment-service orchestrator-service; do
        local port=${SERVICE_PORTS[$service]}
        if (echo > /dev/tcp/localhost/$port) 2>/dev/null; then
            echo -e "  ${GREEN}● $service (port $port)${NC}"
        else
            echo -e "  ${RED}○ $service (port $port) — not running${NC}"
        fi
    done
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-start}" in
    "start")  start_all ;;
    "stop")   stop_all ;;
    "status") status_all ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        echo ""
        echo "  start   — Start all services in dependency order"
        echo "  stop    — Stop all services started by this script"
        echo "  status  — Show which services are currently running"
        exit 1
        ;;
esac
