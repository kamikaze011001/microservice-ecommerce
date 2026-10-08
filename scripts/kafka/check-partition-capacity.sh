#!/usr/bin/env bash
# Fails if any Kafka-consuming service could run more consumers than a topic has
# partitions. In a consumer group each partition goes to exactly one consumer, so
# consumers beyond the partition count sit idle — scaling past it buys nothing
# while the HPA believes it added capacity.
#
#   consumers(svc) = max pods (hpa.maxReplicas, else replicas, else the default)
#                    × listener concurrency (spring.kafka.listener.concurrency /
#                      @KafkaListener(concurrency=…), default 1)
#   must be ≤ the smallest partition count among the keyed topics in topics.txt
#
# Usage: scripts/kafka/check-partition-capacity.sh   (also: make kafka-capacity-check)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALUES="${VALUES:-$ROOT/deploy/charts/microecom/charts/apps/values.yaml}"
TOPICS_FILE="${TOPICS_FILE:-$ROOT/deploy/k8s-jobs/04-kafka-connect-register/topics.txt}"
CONSUMERS="${CONSUMERS:-order-service inventory-service product-service orchestrator-service}"

# Smallest partition count among business topics (dead-letter topics excluded).
min_partitions="$(grep -v '^[[:space:]]*#' "$TOPICS_FILE" | awk 'NF && $1 !~ /^dlq-/ {print $2}' | sort -n | head -n 1)"
default_replicas="$(awk '/^  replicas:/ {print $2; exit}' "$VALUES")"

# Max pods for one service: its block runs from "  <svc>:" to the next 2-space key.
max_pods() {
  awk -v svc="  $1:" -v def="$default_replicas" '
    $0 == svc            { inblock = 1; next }
    inblock && /^  [a-z]/ { inblock = 0 }
    inblock && /hpa:/     { if (match($0, /maxReplicas: *[0-9]+/)) { split(substr($0, RSTART, RLENGTH), a, /: */); hpa = a[2] } }
    inblock && /^    replicas:/ { rep = $2 }
    END { print (hpa ? hpa : (rep ? rep : def)) }
  ' "$VALUES"
}

# Highest listener concurrency configured anywhere in the service; 1 if unset.
max_concurrency() {
  local c
  c="$(grep -rhoE 'concurrency[[:space:]]*[:=][[:space:]]*"?[0-9]+' "$ROOT/$1/src/main" 2>/dev/null \
        | grep -oE '[0-9]+$' | sort -n | tail -n 1 || true)"
  echo "${c:-1}"
}

fail=0
printf '%-22s %5s %12s %10s   (min partitions: %s)\n' service pods concurrency consumers "$min_partitions"
for svc in $CONSUMERS; do
  pods="$(max_pods "$svc")"; conc="$(max_concurrency "$svc")"; total=$((pods * conc))
  status=ok
  if [ "$total" -gt "$min_partitions" ]; then status="FAIL — exceeds $min_partitions partitions"; fail=1; fi
  printf '%-22s %5s %12s %10s   %s\n' "$svc" "$pods" "$conc" "$total" "$status"
done
exit "$fail"
