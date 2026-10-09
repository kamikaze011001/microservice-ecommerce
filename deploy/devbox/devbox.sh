#!/usr/bin/env bash
# The devbox: GitOps on the local cluster. See docs/platform/01-gitops.html.
#
#   CONTEXT=microecom deploy/devbox/devbox.sh <command>
#
#   platform   install Gitea (namespace devbox) + Argo CD (namespace argocd)
#   push       push HEAD to Gitea's devbox/microecom branch `devbox` (the chart
#              Argo CD renders); seed devbox/env-config on first run only
#   apps       apply the ApplicationSet → one Argo CD Application per service
#   wait       block until every prod-like Application is Synced + Healthy
#   open       port-forward the UIs (Argo CD, Gitea, Grafana) and print URLs
#   close      stop those port-forwards
#   status     one line per Application: sync, health, image
#
# CONTEXT is required and never taken from the ambient kubectl context — same
# rule as secrets-seed / kafka-chaos-proof. `make devbox-*` passes microecom.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../scripts/lib/colors.sh
. "$ROOT/deploy/scripts/lib/colors.sh"
DEVBOX="$ROOT/deploy/devbox"
RUN_DIR="$ROOT/deploy/.run"
mkdir -p "$RUN_DIR"

: "${CONTEXT:?set CONTEXT=<kube context> (make devbox-* passes microecom)}"
case "$CONTEXT" in
  *eks*) log_err "refusing context '$CONTEXT': the devbox is local-only"; exit 1 ;;
esac
K="kubectl --context $CONTEXT"
H="helm --kube-context $CONTEXT"

ARGOCD_CHART_VERSION=10.10.2
GITEA_CHART_VERSION=12.7.0

GITEA_USER=devbox
GITEA_PASS=devbox-local
GITEA_LOCAL_PORT=3300
GITEA_LOCAL="http://$GITEA_USER:$GITEA_PASS@localhost:$GITEA_LOCAL_PORT"
GITEA_IN_CLUSTER=http://gitea-http.devbox.svc.cluster.local:3000
ARGOCD_LOCAL_PORT=8180
GRAFANA_LOCAL_PORT=3301

# Your working copy of the env repo. Edit, commit, push here to change an env.
ENV_CLONE="$RUN_DIR/env-config"

# ── port-forwards (same PID-file pattern as cluster.sh's registry forward) ───

stop_forward() {
  local name=$1 pidfile="$RUN_DIR/devbox-$1.pid" pid
  [[ -f "$pidfile" ]] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  rm -f "$pidfile"
}

# start_forward <name> <namespace> <service> <local-port> <service-port> <probe-path>
start_forward() {
  local name=$1 ns=$2 svc=$3 lport=$4 rport=$5 probe=$6
  local pidfile="$RUN_DIR/devbox-$name.pid" log="$RUN_DIR/devbox-$name.log" pid
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null \
     && curl -fsS -o /dev/null "http://localhost:$lport$probe" 2>/dev/null; then
    return 0
  fi
  stop_forward "$name"
  if lsof -nP -iTCP:"$lport" -sTCP:LISTEN >/dev/null 2>&1; then
    log_err "host port $lport is already in use (wanted for $name)"; return 1
  fi
  $K -n "$ns" port-forward "service/$svc" "$lport:$rport" >"$log" 2>&1 &
  pid=$!
  echo "$pid" >"$pidfile"
  for _ in $(seq 1 20); do
    if curl -fsS -o /dev/null "http://localhost:$lport$probe" 2>/dev/null; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then
      log_err "$name forward exited; see $log"; rm -f "$pidfile"; return 1
    fi
    sleep 1
  done
  log_err "$name forward did not become ready; see $log"; stop_forward "$name"; return 1
}

gitea_forward() { start_forward gitea devbox gitea-http "$GITEA_LOCAL_PORT" 3000 /api/healthz; }

# ── commands ────────────────────────────────────────────────────────────────

cmd_platform() {
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null 2>&1 || true
  helm repo update argo gitea-charts >/dev/null

  log_info "installing Gitea (namespace devbox)"
  $H upgrade --install gitea gitea-charts/gitea --version "$GITEA_CHART_VERSION" \
    --namespace devbox --create-namespace -f "$DEVBOX/gitea-values.yaml" \
    --wait --timeout 10m

  log_info "installing Argo CD (namespace argocd)"
  $H upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace -f "$DEVBOX/argocd-values.yaml" \
    --wait --timeout 10m

  # Argo CD finds repo credentials in Secrets carrying this label. Both repos
  # are on the same Gitea, so one credential template covers them by URL prefix.
  log_info "registering Gitea credentials with Argo CD"
  $K -n argocd create secret generic devbox-gitea-creds \
    --from-literal=type=git \
    --from-literal=url="$GITEA_IN_CLUSTER/$GITEA_USER" \
    --from-literal=username="$GITEA_USER" \
    --from-literal=password="$GITEA_PASS" \
    --dry-run=client -o yaml \
    | $K label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
    | $K apply -f - >/dev/null
  log_ok "platform ready (Gitea + Argo CD)"
}

cmd_push() {
  gitea_forward
  cd "$ROOT"

  # The chart Argo CD renders is the one on this branch. Committed state only:
  # an uncommitted chart edit isn't in HEAD, so it isn't deployed.
  if ! git diff --quiet HEAD -- deploy/charts; then
    log_warn "deploy/charts has uncommitted changes — they are NOT pushed (commit them first)"
  fi
  log_info "pushing $(git rev-parse --short HEAD) ($(git branch --show-current)) → gitea devbox/microecom@devbox"
  # --force: `devbox` means "what I'm testing now", not a shared history.
  git push --force --quiet "$GITEA_LOCAL/$GITEA_USER/microecom.git" HEAD:refs/heads/devbox

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -u "$GITEA_USER:$GITEA_PASS" \
    "http://localhost:$GITEA_LOCAL_PORT/api/v1/repos/$GITEA_USER/env-config")"
  if [[ "$code" == 404 ]]; then
    # First run only. After this the Gitea repo is the source of truth; seeding
    # again would wipe the env's history, which is the whole point of having it.
    log_info "seeding devbox/env-config from deploy/devbox/env-repo"
    local seed="$RUN_DIR/env-config-seed"
    rm -rf "$seed" && mkdir -p "$seed"
    cp -R "$DEVBOX/env-repo/." "$seed/"
    git -C "$seed" init --quiet -b main
    git -C "$seed" add -A
    git -C "$seed" -c user.name=devbox -c user.email=devbox@microecom.local \
      commit --quiet -m "seed prod-like from microecom $(git rev-parse --short HEAD)"
    git -C "$seed" push --quiet "$GITEA_LOCAL/$GITEA_USER/env-config.git" main
    rm -rf "$seed"
  elif [[ "$code" != 200 ]]; then
    log_err "Gitea API answered $code for devbox/env-config"; return 1
  fi

  if [[ -d "$ENV_CLONE/.git" ]]; then
    git -C "$ENV_CLONE" pull --quiet --ff-only
  else
    git clone --quiet "$GITEA_LOCAL/$GITEA_USER/env-config.git" "$ENV_CLONE"
  fi
  log_ok "env repo working copy: $ENV_CLONE"
}

cmd_apps() {
  # One owner per object. A Deployment in `apps` without Argo CD's tracking
  # annotation came from `make k8s-apps-helm`; adopting it under a second
  # manager would leave two tools fighting over the same object.
  local foreign
  foreign="$($K -n apps get deploy -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.annotations["argocd.argoproj.io/tracking-id"] == null) | .metadata.name' || true)"
  if [[ -n "$foreign" ]]; then
    log_err "apps namespace already has Deployments not managed by Argo CD:"
    printf '    %s\n' $foreign >&2
    log_err "they come from 'make k8s-apps-helm'. Remove them first:"
    log_err "    helm --kube-context $CONTEXT upgrade microecom deploy/charts/microecom -n infra -f deploy/charts/microecom/envs/local-k8s.yaml --wait"
    log_err "(re-applying the release with apps.enabled at its default false removes only the apps)"
    return 1
  fi
  $K apply -f "$DEVBOX/applicationset.yaml"
  log_ok "ApplicationSet applied — Argo CD is creating one Application per service"
}

cmd_status() {
  $K -n argocd get applications -l devbox.env \
    -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revisions[1],IMAGES:.status.summary.images[*]'
}

cmd_wait() {
  local timeout="${DEVBOX_WAIT_TIMEOUT:-1500}" start=$SECONDS total ready
  log_info "waiting for every prod-like Application to be Synced + Healthy (up to ${timeout}s)"
  while :; do
    total="$($K -n argocd get applications -l devbox.env=prod-like --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$($K -n argocd get applications -l devbox.env=prod-like -o json 2>/dev/null \
      | jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy")] | length')"
    if [[ "$total" -gt 0 && "$ready" == "$total" ]]; then
      log_ok "$ready/$total Applications Synced + Healthy"; return 0
    fi
    if (( SECONDS - start > timeout )); then
      log_err "timed out: $ready/$total ready"; cmd_status; return 1
    fi
    printf '  %s/%s ready (%ss)\n' "$ready" "$total" "$((SECONDS - start))"
    sleep 20
  done
}

cmd_open() {
  gitea_forward
  start_forward argocd argocd argocd-server "$ARGOCD_LOCAL_PORT" 80 /healthz
  start_forward grafana monitoring grafana "$GRAFANA_LOCAL_PORT" 80 /api/health || log_warn "Grafana forward failed (is infra up?)"
  local argo_pass
  argo_pass="$($K -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<secret missing>')"
  cat <<EOF

  Argo CD   http://localhost:$ARGOCD_LOCAL_PORT     admin / $argo_pass
  Gitea     http://localhost:$GITEA_LOCAL_PORT     $GITEA_USER / $GITEA_PASS   (repos: devbox/env-config, devbox/microecom)
  Grafana   http://localhost:$GRAFANA_LOCAL_PORT     admin / admin

  Change an env:  cd $ENV_CLONE && \$EDITOR envs/prod-like/services/<svc>.yaml && git commit -am '...' && git push
  Stop forwards:  make devbox-close

EOF
}

cmd_close() {
  for n in gitea argocd grafana; do stop_forward "$n"; done
  log_ok "devbox port-forwards stopped"
}

case "${1:-}" in
  platform|push|apps|wait|open|close|status) "cmd_$1" ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
