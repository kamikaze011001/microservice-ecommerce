#!/usr/bin/env sh
# Register the MongoDB source connector with the running Kafka Connect
# Deployment. Idempotent: PUT /connectors/<name>/config replaces existing
# config or creates new — same call either way.
#
# Mirrors the existing docker compose flow (scripts/kafka/mongo-connector.sh)
# but targets in-cluster Service DNS and uses JSON value converter (no
# Schema Registry dependency).
set -eu

CONNECT="${CONNECT_URL:-http://kafka-connect.infra.svc.cluster.local:8083}"
NAME="${CONNECTOR_NAME:-mongodb-source-connector}"

echo "waiting for Kafka Connect at ${CONNECT} ..."
i=0
until curl -sf "${CONNECT}/" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "timed out waiting for Kafka Connect"
    exit 1
  fi
  sleep 5
done
echo "Kafka Connect is up"

echo "waiting for MongoDB connector plugin to be installed ..."
i=0
until curl -sf "${CONNECT}/connector-plugins" 2>/dev/null \
  | grep -q "MongoSourceConnector"; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "timed out waiting for MongoSourceConnector plugin"
    curl -s "${CONNECT}/connector-plugins" || true
    exit 1
  fi
  sleep 5
done
echo "MongoSourceConnector plugin present"

cat >/tmp/connector.json <<'JSON'
{
  "connector.class": "com.mongodb.kafka.connect.MongoSourceConnector",
  "tasks.max": "1",
  "connection.uri": "mongodb://ecommerce:ecommerce123@mongodb.infra.svc.cluster.local:27017/?authSource=admin",
  "database": "ecommerce_inventory",
  "collection": "event",
  "topic.prefix": "ecommerce_db",
  "topic.suffix": "",
  "publish.full.document.only": "false",
  "change.stream.full.document": "updateLookup",
  "key.converter": "org.apache.kafka.connect.storage.StringConverter",
  "value.converter": "org.apache.kafka.connect.json.JsonConverter",
  "value.converter.schemas.enable": "false",
  "copy.existing": "true",
  "copy.existing.pipeline": "[]",
  "errors.tolerance": "all",
  "errors.log.enable": "true",
  "errors.log.include.messages": "true"
}
JSON

echo "registering connector ${NAME} ..."
HTTP=$(curl -s -o /tmp/resp.json -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  --data @/tmp/connector.json \
  "${CONNECT}/connectors/${NAME}/config")

if [ "$HTTP" != "200" ] && [ "$HTTP" != "201" ]; then
  echo "connector registration failed (HTTP ${HTTP})"
  cat /tmp/resp.json
  exit 1
fi

echo "connector ${NAME} registered (HTTP ${HTTP})"
