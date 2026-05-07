#!/bin/bash
# Replay a Mongo→Kafka change-stream event for a single order. Useful when the
# CDC connector was down at the time of the original write — touching the doc
# fires a fresh change event the orchestrator can consume.
#
# Usage: scripts/kafka/replay-mongo-event.sh <orderId> [eventName]
#   eventName defaults to "Payment.Success"

set -e

ORDER_ID="$1"
EVENT_NAME="${2:-Payment.Success}"

if [ -z "$ORDER_ID" ]; then
    echo "Usage: $0 <orderId> [eventName]" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "${REPO_ROOT}/docker/.env" ] && { set -a; source "${REPO_ROOT}/docker/.env"; set +a; }

MONGO_USERNAME="${MONGO_USERNAME:-ecommerce}"
MONGO_PASSWORD="${MONGO_PASSWORD:-ecommerce123}"
MONGO_DB_NAME="${MONGO_DB_NAME:-ecommerce_inventory}"
MONGO_COLLECTION="${MONGO_COLLECTION:-event}"

docker exec docker-ecommerce-mongodb-1 mongosh --quiet \
    -u "${MONGO_USERNAME}" -p "${MONGO_PASSWORD}" \
    --authenticationDatabase admin \
    "${MONGO_DB_NAME}" \
    --eval "
        const doc = db.${MONGO_COLLECTION}.findOne({
            name: '${EVENT_NAME}',
            data: { \$regex: '${ORDER_ID}' }
        }, { sort: { createdAt: -1 } });
        if (!doc) {
            print('No ${EVENT_NAME} event found for order ${ORDER_ID}');
            quit(1);
        }
        const res = db.${MONGO_COLLECTION}.updateOne(
            { _id: doc._id },
            { \$set: { replayedAt: new Date() } }
        );
        printjson({ matched: res.matchedCount, modified: res.modifiedCount, _id: doc._id });
    "
