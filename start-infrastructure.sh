#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "E-Commerce Infrastructure Startup Script"
echo "========================================="
echo ""

# Load environment variables from .env file
if [ -f "docker/.env" ]; then
    echo -e "${BLUE}Loading environment variables from docker/.env${NC}"
    export $(grep -v '^#' docker/.env | grep -v '^$' | xargs)
    echo -e "${GREEN}✓ Environment variables loaded${NC}"
else
    echo -e "${YELLOW}Warning: docker/.env file not found, using default values${NC}"
    echo "You can copy docker/.env.example to docker/.env and customize the values"
    
    # Default environment variables (fallback)
    export MYSQL_MASTER_PASSWORD=${MYSQL_MASTER_PASSWORD:-masterpassword}
    export MYSQL_SLAVE1_PASSWORD=${MYSQL_SLAVE1_PASSWORD:-slave1password}
    export MYSQL_SLAVE2_PASSWORD=${MYSQL_SLAVE2_PASSWORD:-slave2password}
    export MYSQL_REPL_USER=${MYSQL_REPL_USER:-repl_user}
    export MYSQL_REPL_PASSWORD=${MYSQL_REPL_PASSWORD:-replica_ecommerce}
    export REDIS_PASSWORD=${REDIS_PASSWORD:-redis123}
    export MONGO_USERNAME=${MONGO_USERNAME:-ecommerce}
    export MONGO_PASSWORD=${MONGO_PASSWORD:-ecommerce123}
    export MONGO_DB_NAME=${MONGO_DB_NAME:-ecommerce_inventory}
fi

# Function to check if Docker is running
check_docker() {
    if ! docker info > /dev/null 2>&1; then
        echo -e "${RED}Error: Docker is not running. Please start Docker first.${NC}"
        exit 1
    fi
}

# Function to wait for service health
wait_for_service() {
    local service_name=$1
    local max_attempts=$2
    local attempt=1
    
    echo -e "${BLUE}Waiting for $service_name to be healthy...${NC}"
    
    while [ $attempt -le $max_attempts ]; do
        if docker compose -f "docker/$service_name.yml" ps | grep -q "healthy"; then
            echo -e "${GREEN}✓ $service_name is healthy${NC}"
            return 0
        fi
        
        echo "Attempt $attempt/$max_attempts: $service_name not ready yet..."
        sleep 10
        attempt=$((attempt + 1))
    done
    
    echo -e "${RED}✗ $service_name failed to become healthy after $max_attempts attempts${NC}"
    return 1
}

# Function to start a service
start_service() {
    local service_file=$1
    local service_name=$2
    
    echo -e "${BLUE}Starting $service_name...${NC}"
    
    if docker compose -f "docker/$service_file" up -d; then
        echo -e "${GREEN}✓ $service_name started successfully${NC}"
    else
        echo -e "${RED}✗ Failed to start $service_name${NC}"
        exit 1
    fi
}

# Function to show service status
show_services_status() {
    echo ""
    echo "========================================="
    echo "SERVICES STATUS"
    echo "========================================="
    
    echo -e "${BLUE}MySQL Cluster:${NC}"
    docker compose -f docker/mysql.yml ps
    echo ""
    
    echo -e "${BLUE}Redis:${NC}"
    docker compose -f docker/redis.yml ps
    echo ""
    
    echo -e "${BLUE}MongoDB:${NC}"
    docker compose -f docker/mongodb.yml ps
    echo ""
    
    echo -e "${BLUE}Kafka:${NC}"
    docker compose -f docker/kafka.yml ps
    echo ""
    
    echo -e "${BLUE}Vault:${NC}"
    docker compose -f docker/vault.yml ps
    echo ""
}

# Main execution
main() {
    # Change to script directory
    cd "$(dirname "$0")"
    
    echo -e "${YELLOW}Environment Variables:${NC}"
    echo "MYSQL_MASTER_PASSWORD: $MYSQL_MASTER_PASSWORD"
    echo "REDIS_PASSWORD: $REDIS_PASSWORD"
    echo "MONGO_USERNAME: $MONGO_USERNAME"
    echo "MONGO_DB_NAME: $MONGO_DB_NAME"
    echo ""
    
    # Check Docker
    check_docker
    
    # Start services in order
    echo "========================================="
    echo "STARTING INFRASTRUCTURE SERVICES"
    echo "========================================="
    
    # 1. Start MySQL cluster (with replication setup)
    start_service "mysql.yml" "MySQL Master-Slave Cluster"
    wait_for_service "mysql" 30
    
    # 2. Start Redis
    start_service "redis.yml" "Redis"
    sleep 5
    
    # 3. Start MongoDB
    start_service "mongodb.yml" "MongoDB"
    wait_for_service "mongodb" 20
    
    # 4. Start Kafka ecosystem
    start_service "kafka.yml" "Kafka Ecosystem"
    wait_for_service "kafka" 40
    
    # 5. Start Vault
    start_service "vault.yml" "HashiCorp Vault"
    sleep 10
    
    echo ""
    echo "========================================="
    echo "INFRASTRUCTURE STARTUP COMPLETE"
    echo "========================================="
    
    show_services_status
    
    echo ""
    echo -e "${GREEN}🎉 All infrastructure services are running!${NC}"
    echo ""
    echo "📋 SERVICE ENDPOINTS:"
    echo "   MySQL Master:     localhost:3306"
    echo "   MySQL Slave 1:    localhost:3307" 
    echo "   MySQL Slave 2:    localhost:3308"
    echo "   Redis:            localhost:6379"
    echo "   MongoDB:          localhost:27017"
    echo "   Kafka:            localhost:9092"
    echo "   Schema Registry:  localhost:8081"
    echo "   Kafka Connect:    localhost:8083"
    echo "   Vault:            localhost:8200"
    echo ""
    echo "🔐 DEFAULT CREDENTIALS:"
    echo "   MySQL Master: root/$MYSQL_MASTER_PASSWORD"
    echo "   Redis:        password: $REDIS_PASSWORD"
    echo "   MongoDB:      $MONGO_USERNAME/$MONGO_PASSWORD"
    echo "   Vault:        http://localhost:8200 (needs initialization)"
    echo ""
    echo "▶️  NEXT STEPS:"
    echo "   1. Initialize Vault: ./init-vault.sh"
    echo "   2. Install Maven modules: ./install-modules.sh"
    echo "   3. Start microservices individually with: mvn spring-boot:run"
    echo ""
}

# Handle script arguments
case "${1:-start}" in
    "start")
        main
        ;;
    "stop")
        echo "Stopping all infrastructure services..."
        docker compose -f docker/mysql.yml down
        docker compose -f docker/redis.yml down
        docker compose -f docker/mongodb.yml down
        docker compose -f docker/kafka.yml down
        docker compose -f docker/vault.yml down
        echo -e "${GREEN}All services stopped${NC}"
        ;;
    "status")
        show_services_status
        ;;
    "logs")
        if [ -n "$2" ]; then
            docker compose -f "docker/$2.yml" logs -f
        else
            echo "Usage: $0 logs <service-name>"
            echo "Available services: mysql, redis, mongodb, kafka, vault"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|status|logs <service>}"
        echo ""
        echo "Commands:"
        echo "  start   - Start all infrastructure services"
        echo "  stop    - Stop all infrastructure services"
        echo "  status  - Show status of all services"
        echo "  logs    - Show logs for a specific service"
        exit 1
        ;;
esac