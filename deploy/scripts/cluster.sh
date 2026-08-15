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
TUNNEL_PIDFILE="$RUN_DIR/tunnel.pid"
mkdir -p "$RUN_DIR"

usage() {
  echo "usage: cluster.sh <up|down|stop|start|tunnel|tunnel-stop|registry-forward|registry-stop|status>"
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

  # Best-effort: the tunnel only matters for browsing the ingress hosts, so a
  # missing sudo credential must not fail an otherwise healthy bring-up.
  start_tunnel || log_info "tunnel not started; run 'sudo -v && make k8s-tunnel' when you need it"

  log_ok "minikube profile '$CLUSTER_NAME' is ready"
  log_info "host pushes through localhost:$HOST_REGISTRY_PORT; pods pull through $CLUSTER_REGISTRY"
}

cmd_down() {
  # Non-fatal: minikube delete removes the cluster regardless, and a tunnel we
  # could not signal must not block teardown.
  stop_tunnel || true
  stop_registry_forward
  log_info "deleting minikube profile '$CLUSTER_NAME'"
  minikube delete -p "$CLUSTER_NAME"
  log_ok "cluster deleted"
}

cmd_stop() {
  stop_tunnel || true
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

  # Re-seed Vault through the canonical secrets path. This used to apply
  # k8s/infra/jobs/03-vault-seed, deleted with the rest of k8s/ in Phase 8 —
  # missed by the deletion sweep because this is a SCRIPT the Makefile calls,
  # and `make -n` shows which commands run, never which files they open.
  #
  # --context is passed explicitly and never inherited: secrets-seed.sh refuses
  # an ambient context for --env k8s, and this function has just started that
  # exact profile, so $CLUSTER_NAME is the only correct target.
  log_info "re-seeding Vault"
  "$ROOT/deploy/scripts/secrets-seed.sh" --env k8s --context "$CLUSTER_NAME"

  log_info "restarting applications"
  kubectl -n apps rollout restart deployment
  kubectl -n apps rollout status deployment --timeout=10m

  start_tunnel || log_info "tunnel not started; run 'sudo -v && make k8s-tunnel' when you need it"

  log_ok "cluster resumed"
}

# The ingress-nginx Service is a LoadBalancer, which on the docker driver is
# only reachable through `minikube tunnel` -- a HOST process that binds
# 127.0.0.1:80 and :443 and proxies into the cluster. kind did not need this:
# its extraPortMappings had the (already privileged) Docker daemon publish 80
# on the node container at creation time. minikube publishes no such port, so
# the bind happens in userspace and needs root.
#
# Run it in the background with a PID file, mirroring start_registry_forward,
# so the tunnel is not tied to a terminal the user must keep open.
# Probe with a TCP connect, NOT `lsof`. The tunnel re-execs under sudo, so the
# listening socket is owned by root -- and an unprivileged `lsof -iTCP:80` does
# not list other users' sockets at all. It reports "nothing on :80" against a
# perfectly healthy tunnel, which then trips the timeout below and tears down a
# working tunnel. A connect test is ownership-blind, so it sees what a browser
# would see. /dev/tcp keeps this dependency-free (no nc/lsof/curl needed) -- it
# is a bash builtin, which the shebang guarantees; it does NOT work under zsh.
tunnel_is_listening() {
  (exec 3<>/dev/tcp/127.0.0.1/80) >/dev/null 2>&1
}

stop_tunnel() {
  if [[ -f "$TUNNEL_PIDFILE" ]]; then
    local pid
    pid="$(cat "$TUNNEL_PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log_info "stopped minikube tunnel (pid=$pid)"
    fi
    rm -f "$TUNNEL_PIDFILE"
  fi

  # `minikube tunnel` re-executes itself under sudo to bind the privileged
  # ports, so killing the PID we launched can leave the root-owned child
  # holding :80. Clear it explicitly or the next start fails on a used port.
  # An unprivileged `pkill` cannot signal that child at all, so try sudo first
  # and only fall back for the case where the process is still ours.
  if pgrep -f "minikube tunnel" >/dev/null 2>&1; then
    sudo -n pkill -f "minikube tunnel" 2>/dev/null \
      || pkill -f "minikube tunnel" 2>/dev/null \
      || true
  fi

  # Verify rather than assume: without a cached sudo credential the kill above
  # is a no-op on the root-owned process and :80 stays bound. Say so, with the
  # command that actually works, instead of reporting a stop that did not happen.
  local attempt
  for attempt in 1 2 3; do
    tunnel_is_listening || return 0
    sleep 1
  done
  log_err ":80 is still bound -- the root-owned tunnel outlived the kill."
  log_err "clear it with:"
  log_err "    sudo pkill -f 'minikube tunnel'"
  return 1
}

start_tunnel() {
  if ! minikube status -p "$CLUSTER_NAME" >/dev/null 2>&1; then
    log_err "cluster '$CLUSTER_NAME' is not running; run '$0 up' first"
    return 1
  fi

  stop_tunnel

  # Binding :80/:443 needs root. Backgrounded there is no TTY to answer a
  # password prompt, so require a cached credential and say exactly how to get
  # one rather than launching something that will silently die.
  #
  # macOS sudo defaults to tty_tickets: the cached credential is scoped to the
  # terminal that created it. `sudo -v` in another window does not count, and a
  # caller with no TTY at all (an agent shell, CI, a cron job) can never satisfy
  # this check -- such a caller must bind :80 some other way.
  if ! sudo -n true 2>/dev/null; then
    log_err "sudo credentials are not cached; minikube tunnel cannot bind :80/:443"
    if ! tty -s; then
      log_err "this shell has no TTY, so sudo cannot be primed from here at all."
      log_err "run this from an interactive terminal:"
    else
      log_err "run this first, in THIS terminal (sudo caches per-tty on macOS):"
    fi
    log_err "    sudo -v && make k8s-tunnel"
    return 1
  fi

  log_info "starting minikube tunnel in the background"
  nohup minikube tunnel -p "$CLUSTER_NAME" >"$RUN_DIR/tunnel.log" 2>&1 &
  local pid=$!
  echo "$pid" >"$TUNNEL_PIDFILE"

  local attempt
  for attempt in $(seq 1 30); do
    # Check for a real listener, NOT the Service's EXTERNAL-IP: minikube
    # leaves EXTERNAL-IP 127.0.0.1 on the Service after the tunnel exits, so
    # that field reports success against a dead tunnel.
    if tunnel_is_listening; then
      log_ok "tunnel ready (:80 and :443 bound)"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      log_err "tunnel exited; see $RUN_DIR/tunnel.log"
      rm -f "$TUNNEL_PIDFILE"
      return 1
    fi
    sleep 1
  done

  log_err "tunnel did not bind :80 in time; see $RUN_DIR/tunnel.log"
  stop_tunnel || true
  return 1
}

cmd_tunnel() {
  start_tunnel
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
  if [[ ! -f "$REGISTRY_FORWARD_PIDFILE" ]]; then
    echo "  not running"
  else
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
  fi

  echo
  echo "Ingress tunnel:"
  # Report the listener, not the Service EXTERNAL-IP -- minikube leaves
  # EXTERNAL-IP 127.0.0.1 behind after the tunnel dies.
  if tunnel_is_listening; then
    echo "  running (:80 bound; http://microecom.local reachable)"
  elif [[ -f "$TUNNEL_PIDFILE" ]]; then
    echo "  stale PID file -- :80 is NOT bound; run 'sudo -v && make k8s-tunnel'"
  else
    echo "  not running -- run 'sudo -v && make k8s-tunnel'"
  fi
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  stop) cmd_stop ;;
  start) cmd_start ;;
  tunnel) cmd_tunnel ;;
  tunnel-stop) stop_tunnel ;;
  registry-forward) start_registry_forward ;;
  registry-stop) stop_registry_forward ;;
  status) cmd_status ;;
  *) usage ;;
esac
