#!/bin/bash
# Fast idempotent check that the Mongo→Kafka CDC connector exists and is
# RUNNING. Falls back to the full installer only when it's absent or failed.
# Wired into `make up` so a Docker restart that wipes Connect's internal
# topics cannot leave the saga pipeline silently broken.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAFKA_CONNECT_URL="${KAFKA_CONNECT_URL:-http://localhost:8093}"
CONNECTOR_NAME="${CONNECTOR_NAME:-mongodb-source-connector}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# Wait briefly for Kafka Connect to be reachable (it may still be starting).
for i in {1..15}; do
    if curl -sf -o /dev/null "${KAFKA_CONNECT_URL}/connectors"; then
        break
    fi
    [ $i -eq 15 ] && {
        echo -e "${RED}[ensure-connector]${NC} Kafka Connect unreachable at ${KAFKA_CONNECT_URL}; skipping."
        exit 0
    }
    sleep 2
done

status=$(curl -s "${KAFKA_CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>/dev/null || true)
connector_state=$(echo "$status" | jq -r '.connector.state // "MISSING"' 2>/dev/null || echo "MISSING")
task_state=$(echo "$status" | jq -r '.tasks[0].state // "MISSING"' 2>/dev/null || echo "MISSING")

if [ "$connector_state" = "RUNNING" ] && [ "$task_state" = "RUNNING" ]; then
    echo -e "${GREEN}[ensure-connector]${NC} ${CONNECTOR_NAME} is RUNNING"
    exit 0
fi

echo -e "${YELLOW}[ensure-connector]${NC} ${CONNECTOR_NAME} state=${connector_state} task=${task_state} — re-registering"
bash "${SCRIPT_DIR}/mongo-connector.sh"
