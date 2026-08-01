#!/usr/bin/env bash
# Minikube lifecycle for the local Kubernetes environment.
set -euo pipefail

CLUSTER_NAME="${MINIKUBE_PROFILE:-microecom}"
NODES="${MINIKUBE_NODES:-4}"
CPUS="${MINIKUBE_CPUS:-4}"
MEMORY="${MINIKUBE_MEMORY:-6g}"
KUBERNETES_VERSION="${MINIKUBE_KUBERNETES_VERSION:-1.30.0}"
HOST_REGISTRY_PORT="${MINIKUBE_REGISTRY_PORT:-5001}"
CLUSTER_REGISTRY="localhost:5000"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/deploy/scripts/lib/colors.sh"

RUN_DIR="$ROOT/deploy/.run"
REGISTRY_FORWARD_PIDFILE="$RUN_DIR/registry-forward.pid"
mkdir -p "$RUN_DIR"

usage() {
  echo "usage: cluster.sh <up|down|stop|start|tunnel|registry-forward|registry-stop|status>"
  exit 1
}

stop_registry_forward() {
  if [[ ! -f "$REGISTRY_FORWARD_PIDFILE" ]]; then
    return
  fi

  local pid
  pid="$(cat "$REGISTRY_FORWARD_PIDFILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    log_info "stopped registry forward (pid=$pid)"
  fi
  rm -f "$REGISTRY_FORWARD_PIDFILE"
}

start_registry_forward() {
  if ! kubectl get service registry -n kube-system >/dev/null 2>&1; then
    log_err "registry addon not found; run '$0 up' first"
    return 1
  fi

  stop_registry_forward

  if lsof -nP -iTCP:"$HOST_REGISTRY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    log_err "host port $HOST_REGISTRY_PORT is already in use"
    return 1
  fi

  log_info "starting registry forward: localhost:$HOST_REGISTRY_PORT -> kube-system/registry:80"
  kubectl port-forward -n kube-system service/registry "$HOST_REGISTRY_PORT":80 \
    >"$RUN_DIR/registry-forward.log" 2>&1 &
  local pid=$!
  echo "$pid" >"$REGISTRY_FORWARD_PIDFILE"

  local attempt
  for attempt in $(seq 1 15); do
    if curl -fsS -o /dev/null "http://localhost:$HOST_REGISTRY_PORT/v2/" 2>/dev/null; then
      log_ok "registry forward ready"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      log_err "registry forward exited; see $RUN_DIR/registry-forward.log"
      rm -f "$REGISTRY_FORWARD_PIDFILE"
      return 1
    fi
    sleep 1
  done

  log_err "registry forward did not become ready; see $RUN_DIR/registry-forward.log"
  stop_registry_forward
  return 1
}

enable_registry() {
  log_info "enabling minikube registry addon"
  minikube addons enable registry -p "$CLUSTER_NAME"

  ensure_registry_storage

  log_info "waiting for the registry addon"
  kubectl -n kube-system rollout status daemonset/registry-proxy --timeout=5m
}

ensure_registry_storage() {
  kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: kube-system
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
YAML

  kubectl -n kube-system patch deployment registry --type=merge -p \
    '{"metadata":{"labels":{"addonmanager.kubernetes.io/mode":"EnsureExists"}}}' >/dev/null
  kubectl -n kube-system patch deployment registry --type=strategic -p \
    '{"spec":{"template":{"spec":{"containers":[{"name":"registry","volumeMounts":[{"name":"registry-data","mountPath":"/var/lib/registry"}]}],"volumes":[{"name":"registry-data","persistentVolumeClaim":{"claimName":"registry-data"}}]}}}}' >/dev/null
  kubectl -n kube-system rollout status deployment/registry --timeout=5m
}

profile_exists() {
  minikube profile list -o json 2>/dev/null \
    | grep -q "\"Name\":\"$CLUSTER_NAME\""
}

apply_node_limits() {
  local node
  while read -r node; do
    docker update \
      --cpus "$CPUS" \
      --memory "$MEMORY" \
      --memory-swap "$MEMORY" \
      "$node" >/dev/null
  done < <(minikube node list -p "$CLUSTER_NAME" | awk '{print $1}')
}

cmd_up() {
  log_info "starting minikube profile '$CLUSTER_NAME'"
  if profile_exists \
    && [[ "$(minikube status -p "$CLUSTER_NAME" --format='{{.Host}}' 2>/dev/null)" == "Running" ]]; then
    log_info "profile is already running"
  elif profile_exists; then
    minikube start -p "$CLUSTER_NAME"
  else
    minikube start \
      -p "$CLUSTER_NAME" \
      --driver=docker \
      --nodes="$NODES" \
      --cpus="$CPUS" \
      --memory="$MEMORY" \
      --kubernetes-version="$KUBERNETES_VERSION" \
      --insecure-registry="$CLUSTER_REGISTRY"
  fi

  apply_node_limits
  enable_registry
  start_registry_forward

  log_ok "minikube profile '$CLUSTER_NAME' is ready"
  log_info "host pushes through localhost:$HOST_REGISTRY_PORT; pods pull through $CLUSTER_REGISTRY"
  log_info "start ingress in another terminal with: make k8s-tunnel"
}

cmd_down() {
  stop_registry_forward
  log_info "deleting minikube profile '$CLUSTER_NAME'"
  minikube delete -p "$CLUSTER_NAME"
  log_ok "cluster deleted"
}

cmd_stop() {
  stop_registry_forward
  log_info "stopping minikube profile '$CLUSTER_NAME'"
  minikube stop -p "$CLUSTER_NAME"
  log_ok "cluster stopped with data preserved"
}

cmd_start() {
  cd "$ROOT"
  log_info "resuming minikube profile '$CLUSTER_NAME'"
  if [[ "$(minikube status -p "$CLUSTER_NAME" --format='{{.Host}}' 2>/dev/null || true)" != "Running" ]]; then
    minikube start -p "$CLUSTER_NAME"
  fi
  apply_node_limits

  enable_registry
  start_registry_forward

  log_info "waiting for Vault"
  kubectl -n infra wait \
    --for=condition=ready pod \
    -l app.kubernetes.io/name=vault \
    --timeout=5m

  log_info "re-seeding Vault"
  kubectl -n bootstrap delete job vault-seed --ignore-not-found >/dev/null
  kubectl apply -k k8s/infra/jobs/03-vault-seed
  kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/vault-seed

  log_info "restarting applications"
  kubectl -n apps rollout restart deployment
  kubectl -n apps rollout status deployment --timeout=10m
  log_ok "cluster resumed"
}

cmd_tunnel() {
  log_info "starting minikube tunnel; keep this process running"
  minikube tunnel -p "$CLUSTER_NAME"
}

cmd_status() {
  minikube status -p "$CLUSTER_NAME" || true
  echo
  kubectl get nodes -o wide 2>/dev/null || echo "(cluster not running)"
  echo
  echo "Registry addon:"
  kubectl get service registry -n kube-system 2>/dev/null || echo "  not enabled"
  echo
  echo "Registry port-forward:"

  if [[ ! -f "$REGISTRY_FORWARD_PIDFILE" ]]; then
    echo "  not running"
    return
  fi

  local pid
  pid="$(cat "$REGISTRY_FORWARD_PIDFILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "  running (pid=$pid, localhost:$HOST_REGISTRY_PORT -> service/registry:80)"
    if curl -fsS -o /dev/null "http://localhost:$HOST_REGISTRY_PORT/v2/" 2>/dev/null; then
      echo "  health: OK"
    else
      echo "  health: unavailable"
    fi
  else
    echo "  stale PID file"
  fi
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  stop) cmd_stop ;;
  start) cmd_start ;;
  tunnel) cmd_tunnel ;;
  registry-forward) start_registry_forward ;;
  registry-stop) stop_registry_forward ;;
  status) cmd_status ;;
  *) usage ;;
esac
