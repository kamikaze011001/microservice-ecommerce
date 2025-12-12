#!/bin/bash

# =============================================================================
# MongoDB Kafka Source Connector Installation Script
# =============================================================================
# This script installs and configures the MongoDB Source Connector for Kafka Connect
# to stream MongoDB change events to Kafka topics.
#
# Usage: ./install-mongodb-kafka-connector.sh [options]
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KAFKA_CONNECT_URL="${KAFKA_CONNECT_URL:-http://localhost:8083}"
CONNECTOR_NAME="${CONNECTOR_NAME:-mongodb-source-connector}"
CONNECTOR_PLUGIN_DIR="./docker/connectors-plugin"
MONGODB_CONNECTOR_VERSION="1.13.1"

# Load environment variables from docker/.env if exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/docker/.env" ]; then
    set -a
    source "${SCRIPT_DIR}/docker/.env"
    set +a
fi

# MongoDB Configuration (from environment or defaults)
MONGO_HOST="${MONGO_HOST:-ecommerce-mongodb}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USERNAME="${MONGO_USERNAME:-ecommerce}"
MONGO_PASSWORD="${MONGO_PASSWORD:-ecommerce123}"
MONGO_DB_NAME="${MONGO_DB_NAME:-ecommerce_inventory}"
MONGO_COLLECTION="${MONGO_COLLECTION:-event}"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_kafka_connect() {
    log_info "Checking Kafka Connect availability at ${KAFKA_CONNECT_URL}..."

    local max_retries=30
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        if curl -s "${KAFKA_CONNECT_URL}/connectors" > /dev/null 2>&1; then
            log_success "Kafka Connect is available"
            return 0
        fi
        retry_count=$((retry_count + 1))
        log_info "Waiting for Kafka Connect... (${retry_count}/${max_retries})"
        sleep 2
    done

    log_error "Kafka Connect is not available at ${KAFKA_CONNECT_URL}"
    return 1
}

check_connector_plugin() {
    log_info "Checking if MongoDB connector plugin is installed..."

    local plugins=$(curl -s "${KAFKA_CONNECT_URL}/connector-plugins" 2>/dev/null)

    if echo "$plugins" | grep -q "MongoSourceConnector"; then
        log_success "MongoDB Source connector plugin is installed"
        return 0
    else
        log_warning "MongoDB Source connector plugin not found"
        return 1
    fi
}

install_connector_plugin() {
    log_info "Installing MongoDB Kafka Connector plugin..."

    mkdir -p "${CONNECTOR_PLUGIN_DIR}"

    # Check if already downloaded
    if [ -d "${CONNECTOR_PLUGIN_DIR}/mongodb-kafka-connect-mongodb" ]; then
        log_info "MongoDB connector plugin directory already exists"
        return 0
    fi

    log_info "Downloading MongoDB Kafka Connector v${MONGODB_CONNECTOR_VERSION}..."

    local download_url="https://search.maven.org/remotecontent?filepath=org/mongodb/kafka/mongo-kafka-connect/${MONGODB_CONNECTOR_VERSION}/mongo-kafka-connect-${MONGODB_CONNECTOR_VERSION}-all.jar"

    mkdir -p "${CONNECTOR_PLUGIN_DIR}/mongodb-kafka-connect-mongodb"

    curl -L "${download_url}" -o "${CONNECTOR_PLUGIN_DIR}/mongodb-kafka-connect-mongodb/mongo-kafka-connect-${MONGODB_CONNECTOR_VERSION}-all.jar"

    if [ $? -eq 0 ]; then
        log_success "MongoDB connector plugin downloaded successfully"
        log_warning "Please restart Kafka Connect to load the new plugin:"
        log_warning "  docker compose -f docker/kafka.yml restart kafka-connect"
    else
        log_error "Failed to download MongoDB connector plugin"
        return 1
    fi
}

fix_mongodb_replica_set() {
    log_info "Checking MongoDB replica set configuration..."

    local rs_host=$(docker exec docker-ecommerce-mongodb-1 mongosh --quiet \
        -u "${MONGO_USERNAME}" -p "${MONGO_PASSWORD}" \
        --authenticationDatabase admin \
        --eval "rs.conf().members[0].host" 2>/dev/null || echo "")

    if [ "$rs_host" == "localhost:27017" ]; then
        log_warning "MongoDB replica set is configured with localhost, fixing..."

        docker exec docker-ecommerce-mongodb-1 mongosh --quiet \
            -u "${MONGO_USERNAME}" -p "${MONGO_PASSWORD}" \
            --authenticationDatabase admin \
            --eval '
            var cfg = rs.conf();
            cfg.members[0].host = "ecommerce-mongodb:27017";
            rs.reconfig(cfg, {force: true});
            ' > /dev/null 2>&1

        log_success "MongoDB replica set reconfigured to use ecommerce-mongodb:27017"
        sleep 3
    else
        log_success "MongoDB replica set is correctly configured: ${rs_host}"
    fi
}

configure_source_connector() {
    log_info "Configuring MongoDB Source Connector..."

    # Build MongoDB connection string
    local mongo_connection_string="mongodb://${MONGO_USERNAME}:${MONGO_PASSWORD}@${MONGO_HOST}:${MONGO_PORT}/?authSource=admin&replicaSet=rs0"

    log_info "Connection URI: mongodb://${MONGO_USERNAME}:****@${MONGO_HOST}:${MONGO_PORT}/?authSource=admin&replicaSet=rs0"
    log_info "Database: ${MONGO_DB_NAME}"
    log_info "Collection: ${MONGO_COLLECTION}"
    log_info "Output topic: ${MONGO_DB_NAME}.${MONGO_COLLECTION}"

    # Create connector configuration for MongoDB Source (Change Streams)
    local connector_config=$(cat <<EOF
{
    "name": "${CONNECTOR_NAME}",
    "config": {
        "connector.class": "com.mongodb.kafka.connect.MongoSourceConnector",
        "tasks.max": "1",

        "connection.uri": "${mongo_connection_string}",
        "database": "${MONGO_DB_NAME}",
        "collection": "${MONGO_COLLECTION}",

        "topic.prefix": "ecommerce_db",
        "topic.suffix": "",

        "publish.full.document.only": "false",
        "change.stream.full.document": "updateLookup",

        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "value.converter": "io.confluent.connect.avro.AvroConverter",
        "value.converter.schema.registry.url": "http://kafka-schema-registry:8081",

        "output.format.key": "json",
        "output.format.value": "schema",

        "copy.existing": "true",
        "copy.existing.pipeline": "[]",

        "errors.tolerance": "all",
        "errors.log.enable": true,
        "errors.log.include.messages": true
    }
}
EOF
)

    # Check if connector already exists
    local existing=$(curl -s -o /dev/null -w "%{http_code}" "${KAFKA_CONNECT_URL}/connectors/${CONNECTOR_NAME}" 2>/dev/null)

    if [ "$existing" == "200" ]; then
        log_info "Connector already exists, updating configuration..."
        local response=$(curl -s -X PUT \
            -H "Content-Type: application/json" \
            -d "$(echo "$connector_config" | jq '.config')" \
            "${KAFKA_CONNECT_URL}/connectors/${CONNECTOR_NAME}/config")
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
    else
        log_info "Creating new connector..."
        local response=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$connector_config" \
            "${KAFKA_CONNECT_URL}/connectors")
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
    fi

    # Verify connector was created
    sleep 3
    show_connector_status
}

delete_connector() {
    log_info "Deleting connector ${CONNECTOR_NAME}..."

    local response=$(curl -s -X DELETE "${KAFKA_CONNECT_URL}/connectors/${CONNECTOR_NAME}")

    if [ $? -eq 0 ]; then
        log_success "Connector deleted successfully"
    else
        log_error "Failed to delete connector"
        echo "$response"
    fi
}

show_connector_status() {
    log_info "Connector status for ${CONNECTOR_NAME}:"

    local status=$(curl -s "${KAFKA_CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>/dev/null)

    if echo "$status" | jq -e '.connector' > /dev/null 2>&1; then
        local connector_state=$(echo "$status" | jq -r '.connector.state')
        local task_state=$(echo "$status" | jq -r '.tasks[0].state // "NO_TASKS"')

        if [ "$connector_state" == "RUNNING" ] && [ "$task_state" == "RUNNING" ]; then
            log_success "Connector is RUNNING"
        else
            log_warning "Connector state: ${connector_state}, Task state: ${task_state}"
        fi

        echo "$status" | jq '.'
    else
        log_error "Could not get connector status"
        echo "$status"
    fi
}

show_status() {
    log_info "Kafka Connect Status"
    echo ""

    # List all connectors
    log_info "Available connectors:"
    curl -s "${KAFKA_CONNECT_URL}/connectors" | jq '.' 2>/dev/null || echo "[]"
    echo ""

    # List all plugins
    log_info "Available plugins:"
    curl -s "${KAFKA_CONNECT_URL}/connector-plugins" | jq '.[].class' 2>/dev/null || echo "[]"
    echo ""

    # Show specific connector status if exists
    local existing=$(curl -s -o /dev/null -w "%{http_code}" "${KAFKA_CONNECT_URL}/connectors/${CONNECTOR_NAME}" 2>/dev/null)

    if [ "$existing" == "200" ]; then
        show_connector_status
    else
        log_warning "Connector ${CONNECTOR_NAME} not found"
    fi
}

show_help() {
    cat << EOF
MongoDB Kafka Source Connector Installation Script

This script configures a MongoDB Source Connector to stream change events
from MongoDB to Kafka topics for the e-commerce microservices platform.

Architecture:
  MongoDB (Change Streams) → Kafka Connect → Kafka Topics → Orchestrator Service

Topic Naming:
  The connector outputs to: ecommerce_db.<database>.<collection>
  Default: ecommerce_db.ecommerce_inventory.event

Usage: $0 [options]

Options:
  (no args)          Full installation - fix replica set, check plugin, configure connector
  --install-only     Only install the connector plugin (download JAR)
  --configure-only   Only configure the connector (assumes plugin is installed)
  --delete           Delete the existing connector configuration
  --status           Check connector and Kafka Connect status
  --help             Show this help message

Environment Variables:
  KAFKA_CONNECT_URL   Kafka Connect REST API URL (default: http://localhost:8083)
  CONNECTOR_NAME      Name of the connector (default: mongodb-source-connector)
  MONGO_HOST          MongoDB host (default: ecommerce-mongodb)
  MONGO_PORT          MongoDB port (default: 27017)
  MONGO_USERNAME      MongoDB username (default: ecommerce)
  MONGO_PASSWORD      MongoDB password (from docker/.env)
  MONGO_DB_NAME       MongoDB database name (default: ecommerce_inventory)
  MONGO_COLLECTION    MongoDB collection to watch (default: event)

Examples:
  $0                              # Full installation and configuration
  $0 --status                     # Check connector status
  $0 --delete                     # Remove connector
  MONGO_COLLECTION=orders $0      # Watch different collection

Troubleshooting:
  1. If connector fails to connect, check MongoDB replica set config:
     docker exec docker-ecommerce-mongodb-1 mongosh -u ecommerce -p <password> --authenticationDatabase admin --eval "rs.conf()"

  2. Check Kafka Connect logs:
     docker compose -f docker/kafka.yml logs -f kafka-connect

  3. Verify Schema Registry is running:
     curl http://localhost:8081/subjects
EOF
}

# =============================================================================
# Main Script
# =============================================================================

main() {
    local install_only=false
    local configure_only=false
    local delete_mode=false
    local status_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --install-only)
                install_only=true
                shift
                ;;
            --configure-only)
                configure_only=true
                shift
                ;;
            --delete)
                delete_mode=true
                shift
                ;;
            --status)
                status_mode=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    echo "============================================="
    echo "MongoDB Kafka Source Connector Setup"
    echo "============================================="
    echo ""

    # Handle status mode
    if [ "$status_mode" = true ]; then
        check_kafka_connect || exit 1
        show_status
        exit 0
    fi

    # Handle delete mode
    if [ "$delete_mode" = true ]; then
        check_kafka_connect || exit 1
        delete_connector
        exit 0
    fi

    # Install only mode
    if [ "$install_only" = true ]; then
        install_connector_plugin
        exit 0
    fi

    # Configure only mode
    if [ "$configure_only" = true ]; then
        check_kafka_connect || exit 1
        if ! check_connector_plugin; then
            log_error "MongoDB connector plugin is not installed. Run with --install-only first."
            exit 1
        fi
        configure_source_connector
        exit 0
    fi

    # Full installation
    log_info "Starting full installation..."
    echo ""

    # Step 1: Install plugin if not present
    if [ ! -d "${CONNECTOR_PLUGIN_DIR}/mongodb-kafka-connect-mongodb" ]; then
        install_connector_plugin
        log_warning "Plugin installed. Please restart Kafka Connect and run this script again."
        log_warning "  docker compose -f docker/kafka.yml restart kafka-connect"
        exit 0
    fi

    # Step 2: Check Kafka Connect
    check_kafka_connect || exit 1

    # Step 3: Verify plugin is loaded
    if ! check_connector_plugin; then
        log_error "MongoDB connector plugin is not loaded in Kafka Connect"
        log_warning "Try restarting Kafka Connect:"
        log_warning "  docker compose -f docker/kafka.yml restart kafka-connect"
        exit 1
    fi

    # Step 4: Fix MongoDB replica set if needed
    fix_mongodb_replica_set

    # Step 5: Configure connector
    configure_source_connector

    echo ""
    log_success "MongoDB Kafka Source Connector setup complete!"
    echo ""
    echo "The connector will stream changes from:"
    echo "  MongoDB: ${MONGO_DB_NAME}.${MONGO_COLLECTION}"
    echo "  To Kafka topic: ecommerce_db.${MONGO_DB_NAME}.${MONGO_COLLECTION}"
    echo ""
    echo "Useful commands:"
    echo "  Check status:     $0 --status"
    echo "  Delete connector: $0 --delete"
    echo "  View logs:        docker compose -f docker/kafka.yml logs -f kafka-connect"
    echo "  List topics:      docker exec docker-kafka-1 kafka-topics --bootstrap-server localhost:9092 --list"
}

main "$@"