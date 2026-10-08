#!/bin/sh
# Brings every topic in $TOPICS_FILE to its declared partition count. Idempotent.
#
#   missing                      → create with the declared partitions + cleanup.policy
#   fewer partitions than listed → grow it (--alter); Kafka cannot shrink a topic
#   more partitions than listed  → warn and leave it alone
#
# Required env:
#   KAFKA_TOPICS  the kafka-topics command, e.g.
#                   compose: "docker exec docker-kafka-1 kafka-topics"
#                   k8s:     "/opt/kafka/bin/kafka-topics.sh"
#   BOOTSTRAP     bootstrap server as seen by that command
#   TOPICS_FILE   path to topics.txt
# Optional:
#   REPLICATION_FACTOR (default 1 — single broker in every env)
#
# POSIX sh on purpose: it runs both on the host and inside the apache/kafka image.
set -eu

: "${KAFKA_TOPICS:?KAFKA_TOPICS must be set}"
: "${BOOTSTRAP:?BOOTSTRAP must be set}"
: "${TOPICS_FILE:?TOPICS_FILE must be set}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-1}"

kt() {
  # shellcheck disable=SC2086  # KAFKA_TOPICS is intentionally word-split
  $KAFKA_TOPICS --bootstrap-server "$BOOTSTRAP" "$@"
}

current_partitions() {
  # Empty when the topic doesn't exist; otherwise the PartitionCount number.
  kt --describe --topic "$1" 2>/dev/null \
    | sed -n 's/.*PartitionCount:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    | head -n 1
}

i=0
until kt --list >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "Kafka unreachable at $BOOTSTRAP after 30 attempts" >&2
    exit 1
  fi
  echo "waiting for Kafka at $BOOTSTRAP ($i/30)"
  sleep 2
done

failed=0
# Strip comments and blank lines, then read "<name> <partitions> <policy>".
grep -v '^[[:space:]]*#' "$TOPICS_FILE" | grep -v '^[[:space:]]*$' |
{
  while read -r name partitions policy; do
    have="$(current_partitions "$name")"
    if [ -z "$have" ]; then
      if kt --create --if-not-exists --topic "$name" --partitions "$partitions" \
            --replication-factor "$REPLICATION_FACTOR" --config "cleanup.policy=$policy" >/dev/null; then
        echo "created  $name  partitions=$partitions"
      else
        echo "FAILED   create $name" >&2; failed=$((failed + 1))
      fi
    elif [ "$have" -lt "$partitions" ]; then
      # Growing re-maps hash(key) % N: records already on the topic keep their old
      # partition, so per-key order is not guaranteed across this moment.
      if kt --alter --topic "$name" --partitions "$partitions" >/dev/null; then
        echo "grown    $name  partitions=$have->$partitions"
      else
        echo "FAILED   alter $name" >&2; failed=$((failed + 1))
      fi
    elif [ "$have" -gt "$partitions" ]; then
      echo "WARN     $name has $have partitions, list says $partitions (Kafka cannot shrink; left as is)" >&2
    else
      echo "ok       $name  partitions=$have"
    fi
  done
  [ "$failed" -eq 0 ]
}
