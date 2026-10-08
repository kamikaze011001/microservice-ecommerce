#!/usr/bin/env bash
# Replays <topic>.DLT back onto <topic> through the owning service's actuator endpoint
# (POST /actuator/dltreplay/<topic> on the internal management port = HTTP port + 10000).
#
#   scripts/kafka/dlt-replay.sh <service> <topic>                       # compose (default)
#   ENV=k8s CONTEXT=microecom scripts/kafka/dlt-replay.sh <service> <topic>
#   make dlt-replay svc=order-service topic=order-service.order.failed-status [ENV=k8s CONTEXT=…]
#
# Fix whatever made the records fail BEFORE replaying — otherwise they fail again and
# land back in the DLT. Each record is replayed once: progress is committed per call.
# The service only accepts topics it consumes itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
svc="${1:?usage: dlt-replay.sh <service> <topic>}"
topic="${2:?usage: dlt-replay.sh <service> <topic>}"
env="${ENV:-compose}"

http_port="$(grep -E "^[[:space:]]*\"${svc}[[:space:]]" "$ROOT/scripts/services.list" | awk '{print $2}' || true)"
if [[ -z "$http_port" ]]; then
  echo "dlt-replay: unknown service '$svc' (not in scripts/services.list)" >&2
  exit 1
fi
mgmt_port=$((http_port + 10000))
url="http://localhost:${mgmt_port}/actuator/dltreplay/${topic}"

case "$env" in
  compose)
    curl -fsS -X POST "$url"
    ;;
  k8s)
    # Never act on whatever cluster kubectl happens to point at.
    context="${CONTEXT:?ENV=k8s needs an explicit CONTEXT=<kube-context>}"
    kubectl --context "$context" -n apps port-forward "deploy/${svc}" "${mgmt_port}:${mgmt_port}" >/dev/null 2>&1 &
    pf=$!
    trap 'kill "$pf" 2>/dev/null || true' EXIT
    for _ in $(seq 1 20); do
      curl -fsS -o /dev/null "http://localhost:${mgmt_port}/actuator/health" 2>/dev/null && break
      sleep 0.5
    done
    curl -fsS -X POST "$url"
    ;;
  *)
    echo "dlt-replay: ENV must be compose or k8s, got '$env'" >&2
    exit 1
    ;;
esac
echo
