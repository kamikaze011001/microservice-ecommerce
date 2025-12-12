#!/bin/bash

# =============================================================================
# Kafka Topics Initialization Script
# =============================================================================
# This script creates all required Kafka topics for the e-commerce microservices
# platform, including Kafka Connect internal topics and application topics.
#
# Usage: ./init-kafka-topics.sh [options]
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KAFKA_CONTAINER="${KAFKA_CONTAINER:-docker-kafka-1}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-localhost:9092}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-1}"
PARTITIONS="${PARTITIONS:-3}"

# =============================================================================
# Topic Definitions
# =============================================================================

# Kafka Connect internal topics (compact cleanup policy)
CONNECT_TOPICS=(
    "connect-config:1:compact"
    "connect-offsets:25:compact"
    "connect-status:5:compact"
)

# Application topics for e-commerce microservices
APP_TOPICS=(
    # Order Service topics
    "order-service.order.success-status:${PARTITIONS}:delete"
    "order-service.order.failed-status:${PARTITIONS}:delete"
    "order-service.order.canceled-status:${PARTITIONS}:delete"

    # Inventory Service topics
    "inventory-service.product.update:${PARTITIONS}:delete"
    "inventory-service.inventory-product.update-quantity:${PARTITIONS}:delete"

    # Product Service topics
    "product-service.product.update-quantity:${PARTITIONS}:delete"

    # Dead Letter Queue topics
    "dlq-mongodb-sink:1:delete"
    "dlq-order-processing:1:delete"
)

# MongoDB Change Stream topic (created by connector, but we can pre-create)
MONGO_TOPICS=(
    "ecommerce_db.ecommerce_inventory.event:${PARTITIONS}:delete"
)

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

check_kafka() {
    log_info "Checking Kafka availability..."

    local max_retries=30
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        if docker exec ${KAFKA_CONTAINER} kafka-topics --bootstrap-server ${BOOTSTRAP_SERVER} --list > /dev/null 2>&1; then
            log_success "Kafka is available"
            return 0
        fi
        retry_count=$((retry_count + 1))
        log_info "Waiting for Kafka... (${retry_count}/${max_retries})"
        sleep 2
    done

    log_error "Kafka is not available"
    return 1
}

create_topic() {
    local topic_spec=$1
    local topic_name=$(echo $topic_spec | cut -d: -f1)
    local partitions=$(echo $topic_spec | cut -d: -f2)
    local cleanup_policy=$(echo $topic_spec | cut -d: -f3)

    # Check if topic exists
    if docker exec ${KAFKA_CONTAINER} kafka-topics --bootstrap-server ${BOOTSTRAP_SERVER} --describe --topic ${topic_name} > /dev/null 2>&1; then
        log_warning "Topic '${topic_name}' already exists, skipping"
        return 0
    fi

    log_info "Creating topic: ${topic_name} (partitions: ${partitions}, cleanup: ${cleanup_policy})"

    docker exec ${KAFKA_CONTAINER} kafka-topics \
        --bootstrap-server ${BOOTSTRAP_SERVER} \
        --create \
        --topic ${topic_name} \
        --partitions ${partitions} \
        --replication-factor ${REPLICATION_FACTOR} \
        --config cleanup.policy=${cleanup_policy} \
        2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "Created topic: ${topic_name}"
    else
        log_error "Failed to create topic: ${topic_name}"
        return 1
    fi
}

create_topics() {
    local topic_array=("$@")
    local failed=0

    for topic_spec in "${topic_array[@]}"; do
        create_topic "$topic_spec" || ((failed++))
    done

    return $failed
}

list_topics() {
    log_info "Current Kafka topics:"
    echo ""
    docker exec ${KAFKA_CONTAINER} kafka-topics \
        --bootstrap-server ${BOOTSTRAP_SERVER} \
        --list | sort
    echo ""
}

describe_topics() {
    log_info "Topic details:"
    echo ""
    docker exec ${KAFKA_CONTAINER} kafka-topics \
        --bootstrap-server ${BOOTSTRAP_SERVER} \
        --describe
}

delete_topic() {
    local topic_name=$1

    log_info "Deleting topic: ${topic_name}"

    docker exec ${KAFKA_CONTAINER} kafka-topics \
        --bootstrap-server ${BOOTSTRAP_SERVER} \
        --delete \
        --topic ${topic_name} \
        2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "Deleted topic: ${topic_name}"
    else
        log_warning "Could not delete topic: ${topic_name} (may not exist)"
    fi
}

delete_all_app_topics() {
    log_warning "Deleting all application topics..."

    for topic_spec in "${APP_TOPICS[@]}" "${MONGO_TOPICS[@]}"; do
        local topic_name=$(echo $topic_spec | cut -d: -f1)
        delete_topic "$topic_name"
    done
}

show_help() {
    cat << EOF
Kafka Topics Initialization Script

This script creates all required Kafka topics for the e-commerce platform.

Topics Created:
  Kafka Connect Internal:
    - connect-config     (connector configurations)
    - connect-offsets    (connector offsets)
    - connect-status     (connector status)

  Application Topics:
    - order-service.order.success-status
    - order-service.order.failed-status
    - order-service.order.canceled-status
    - inventory-service.product.update
    - inventory-service.inventory-product.update-quantity
    - product-service.product.update-quantity
    - ecommerce_db.ecommerce_inventory.event (MongoDB change stream)

  Dead Letter Queues:
    - dlq-mongodb-sink
    - dlq-order-processing

Usage: $0 [options]

Options:
  (no args)     Create all required topics
  --list        List existing topics
  --describe    Show detailed topic information
  --delete-app  Delete all application topics (not Kafka Connect topics)
  --help        Show this help message

Environment Variables:
  KAFKA_CONTAINER     Docker container name (default: docker-kafka-1)
  BOOTSTRAP_SERVER    Kafka bootstrap server (default: localhost:9092)
  REPLICATION_FACTOR  Topic replication factor (default: 1)
  PARTITIONS          Default partition count (default: 3)

Examples:
  $0                  # Create all topics
  $0 --list           # List existing topics
  $0 --describe       # Show topic details
  PARTITIONS=6 $0     # Create with 6 partitions
EOF
}

# =============================================================================
# Main Script
# =============================================================================

main() {
    # Parse arguments
    case "${1:-}" in
        --list)
            check_kafka || exit 1
            list_topics
            exit 0
            ;;
        --describe)
            check_kafka || exit 1
            describe_topics
            exit 0
            ;;
        --delete-app)
            check_kafka || exit 1
            delete_all_app_topics
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        "")
            # Default: create topics
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac

    echo "============================================="
    echo "Kafka Topics Initialization"
    echo "============================================="
    echo ""
    echo "Configuration:"
    echo "  Kafka Container:    ${KAFKA_CONTAINER}"
    echo "  Bootstrap Server:   ${BOOTSTRAP_SERVER}"
    echo "  Replication Factor: ${REPLICATION_FACTOR}"
    echo "  Default Partitions: ${PARTITIONS}"
    echo ""

    # Check Kafka availability
    check_kafka || exit 1

    echo ""
    log_info "Creating Kafka Connect internal topics..."
    create_topics "${CONNECT_TOPICS[@]}"

    echo ""
    log_info "Creating application topics..."
    create_topics "${APP_TOPICS[@]}"

    echo ""
    log_info "Creating MongoDB change stream topics..."
    create_topics "${MONGO_TOPICS[@]}"

    echo ""
    echo "============================================="
    log_success "Topic initialization complete!"
    echo "============================================="
    echo ""

    list_topics

    echo "Next steps:"
    echo "  1. Start Kafka Connect: docker compose -f docker/kafka.yml up -d kafka-connect"
    echo "  2. Configure connectors: ./install-mongodb-kafka-connector.sh"
    echo "  3. Start microservices"
}

main "$@"