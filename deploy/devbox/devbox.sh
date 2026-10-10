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
#   portal     build + deploy the devbox portal UI (namespace devbox, :8282)
#
#   version <svc>               the tag a build of <svc> would get right now
#   ship    <svc> [env]         build → push image → commit tag to env → sync
#   deploy  <svc> <tag> [env]   pin an existing tag (rollback / roll forward)
#   tags    <svc>               registry tags, newest first, with env markers
#   gc      [keep] [apply]      delete old tags; never one an env references
#   proof                       ship → rollback → history → drift, PASS/FAIL
#
#   env-list                    envs in the env repo, with namespace + health
#   env-create <name>           preview-<name>: namespace, DBs, topics, CDC
#                               connector, Redis, seed, apps (small by default)
#   env-delete <name> [apply]   remove all of it; dry run unless apply = 1
#   env-proof  [name]           two envs, one order stream each — PASS/FAIL
#
#   api-test [env]               Bruno contract suite (api-tests/) as a pod in the env
#   perf <scenario> [env] [prof] k6 run tagged with every image version
#   perf-runs                    recorded runs, newest first
#   perf-compare <a> <b>         p95/errors per request + versions that differ
#
# CONTEXT is required and never taken from the ambient kubectl context — same
# rule as secrets-seed / kafka-chaos-proof. `make devbox-*` passes microecom.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../scripts/lib/colors.sh
. "$ROOT/deploy/scripts/lib/colors.sh"
# shellcheck source=lib/version.sh
. "$ROOT/deploy/devbox/lib/version.sh"
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
REGISTRY_UI_LOCAL_PORT=8181
PORTAL_LOCAL_PORT=8282
# The host side of the minikube registry addon (cluster.sh's forward). Pods
# pull the same repositories as localhost:5000 through the node proxy.
REGISTRY_HOST=localhost:5001
DEFAULT_ENV=prod-like
# Tags `gc` always keeps, whatever their age: the bootstrap tag every service
# file starts on, so `deploy <svc> dev` is always a valid way back.
GC_PROTECTED_TAGS="dev"

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
  log_info "installing the registry browser (namespace devbox)"
  $K apply -f "$DEVBOX/registry-ui.yaml" >/dev/null
  $K -n devbox rollout status deploy/registry-ui --timeout=3m >/dev/null
  log_ok "platform ready (Gitea + Argo CD + registry UI)"
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
  local env=${1:-$DEFAULT_ENV} timeout="${DEVBOX_WAIT_TIMEOUT:-1500}" start=$SECONDS total ready
  log_info "waiting for every $env Application to be Synced + Healthy (up to ${timeout}s)"
  while :; do
    total="$($K -n argocd get applications -l devbox.env="$env" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$($K -n argocd get applications -l devbox.env="$env" -o json 2>/dev/null \
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
  start_forward registry-ui devbox registry-ui "$REGISTRY_UI_LOCAL_PORT" 80 / || log_warn "registry UI forward failed (run make devbox-platform)"
  start_forward portal devbox devbox-portal "$PORTAL_LOCAL_PORT" 80 /api/links || log_warn "portal forward failed (run make devbox-portal)"
  local argo_pass
  argo_pass="$($K -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<secret missing>')"
  cat <<EOF

  Portal    http://localhost:$PORTAL_LOCAL_PORT     envs, versions, deploy, history, perf runs
  Argo CD   http://localhost:$ARGOCD_LOCAL_PORT     admin / $argo_pass
  Gitea     http://localhost:$GITEA_LOCAL_PORT     $GITEA_USER / $GITEA_PASS   (repos: devbox/env-config, devbox/microecom)
  Grafana   http://localhost:$GRAFANA_LOCAL_PORT     admin / admin
  Registry  http://localhost:$REGISTRY_UI_LOCAL_PORT     read-only; delete old tags with make devbox-gc

  Ship your code: make devbox-ship svc=<svc>     Roll back: make devbox-deploy svc=<svc> tag=<tag>
  Change an env:  cd $ENV_CLONE && \$EDITOR envs/prod-like/services/<svc>.yaml && git commit -am '...' && git push
  Stop forwards:  make devbox-close

EOF
}

cmd_close() {
  for n in gitea argocd grafana registry-ui registry portal vm; do stop_forward "$n"; done
  log_ok "devbox port-forwards stopped"
}

# The portal is platform tooling: built from deploy/devbox/portal, tagged like
# the apps (last commit touching it, or -dirty-<time>), applied with kubectl —
# not through the ApplicationSet, which is for the envs it manages.
cmd_portal() {
  local tag image
  tag="$(cd "$ROOT" && version_of devbox-portal)"
  ensure_registry
  if ! is_dirty_tag "$tag" && image_exists devbox-portal "$tag"; then
    log_info "devbox-portal:$tag is already in the registry — no rebuild"
  else
    log_info "building devbox-portal:$tag"
    docker build -q -t "$REGISTRY_HOST/devbox-portal:$tag" "$DEVBOX/portal" >/dev/null
    docker push -q "$REGISTRY_HOST/devbox-portal:$tag" >/dev/null
  fi
  $K -n devbox create secret generic devbox-portal --from-literal=gitea-password="$GITEA_PASS" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
  image="localhost:5000/devbox-portal:$tag"
  sed "s#PORTAL_IMAGE#$image#" "$DEVBOX/portal/k8s.yaml" | $K apply -f - >/dev/null
  $K -n devbox rollout status deploy/devbox-portal --timeout=5m >/dev/null
  # kubectl port-forward binds to ONE pod: after a rollout an existing forward
  # points at the deleted pod ("lost connection to pod") while its PID file
  # still exists. Re-open it against the new pod.
  stop_forward portal
  start_forward portal devbox devbox-portal "$PORTAL_LOCAL_PORT" 80 /api/links \
    || log_warn "portal forward failed — make devbox-open"
  log_ok "devbox-portal $tag running — http://localhost:$PORTAL_LOCAL_PORT"
}

# ── versions: ship / deploy / tags / gc / proof ─────────────────────────────

ensure_registry() {
  curl -fsS --max-time 5 -o /dev/null "http://$REGISTRY_HOST/v2/" 2>/dev/null && return 0
  log_info "registry not reachable on $REGISTRY_HOST — starting a forward"
  start_forward registry kube-system registry "${REGISTRY_HOST##*:}" 80 /v2/
}

# Both manifest flavours: buildx pushes OCI indexes, plain docker v2 manifests.
MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

image_exists() {  # <svc> <tag>
  curl -fsS --max-time 5 -o /dev/null -I -H "Accept: $MANIFEST_ACCEPT" \
    "http://$REGISTRY_HOST/v2/$1/manifests/$2" 2>/dev/null
}

image_digest() {  # <svc> <tag>
  curl -fsS --max-time 5 -I -H "Accept: $MANIFEST_ACCEPT" \
    "http://$REGISTRY_HOST/v2/$1/manifests/$2" 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }'
}

# When the image was built: manifest → (first real platform, if an index) →
# config blob → .created. Empty if anything along the way is missing.
image_created() {  # <svc> <tag>
  local m cfg sub
  m="$(curl -fsS --max-time 5 -H "Accept: $MANIFEST_ACCEPT" "http://$REGISTRY_HOST/v2/$1/manifests/$2" 2>/dev/null)" || return 0
  if jq -e '.manifests' >/dev/null 2>&1 <<<"$m"; then
    sub="$(jq -r '[.manifests[] | select(.platform.architecture != "unknown")][0].digest' <<<"$m")"
    m="$(curl -fsS --max-time 5 -H "Accept: $MANIFEST_ACCEPT" "http://$REGISTRY_HOST/v2/$1/manifests/$sub" 2>/dev/null)" || return 0
  fi
  cfg="$(jq -r '.config.digest // empty' <<<"$m")"
  [[ -n "$cfg" ]] || return 0
  curl -fsS --max-time 5 "http://$REGISTRY_HOST/v2/$1/blobs/$cfg" 2>/dev/null | jq -r '.created // empty' | cut -c1-19
}

registry_tags() {  # <svc> — one tag per line
  curl -fsS --max-time 5 "http://$REGISTRY_HOST/v2/$1/tags/list" 2>/dev/null | jq -r '.tags // [] | .[]'
}

# <svc> — "created<TAB>tag" per line, newest first
registry_tags_by_age() {
  local t
  for t in $(registry_tags "$1"); do printf '%s\t%s\n' "$(image_created "$1" "$t")" "$t"; done | sort -r
}

env_file() { echo "$ENV_CLONE/envs/$1/services/$2.yaml"; }

# Envs whose service file currently pins <svc>:<tag>, space-separated.
envs_using() {  # <svc> <tag>
  local f e
  for f in "$ENV_CLONE"/envs/*/services/"$1".yaml; do
    [[ -f "$f" ]] || continue
    e="${f#"$ENV_CLONE"/envs/}"; e="${e%%/*}"
    if [[ "$(current_tag "$e" "$1")" == "$2" ]]; then printf '%s ' "$e"; fi
  done
  # An `[[ ]] && printf` as the last command would make a non-match the
  # function's exit status, and `set -e` kills the caller silently.
}

env_sync_clone() {
  gitea_forward
  if [[ -d "$ENV_CLONE/.git" ]]; then
    git -C "$ENV_CLONE" pull --quiet --ff-only
  else
    git clone --quiet "$GITEA_LOCAL/$GITEA_USER/env-config.git" "$ENV_CLONE"
  fi
}

current_tag() {  # <env> <svc>
  awk '/^    image:/ { img = 1; next } img && /^      tag:/ { print $2; exit } /^    [a-z]/ { img = 0 }' "$(env_file "$1" "$2")"
}

set_tag() {  # <env> <svc> <tag>
  local f; f="$(env_file "$1" "$2")"
  [[ -f "$f" ]] || { log_err "no service file $f (unknown env or service)"; return 1; }
  perl -0pi -e "s/(\n    image:\n      tag:)[^\n]*/\$1 $3/" "$f"
  [[ "$(current_tag "$1" "$2")" == "$3" ]] || { log_err "could not set image.tag in $f"; return 1; }
}

env_commit_push() {  # <subject> <body>
  git -C "$ENV_CLONE" add -A
  git -C "$ENV_CLONE" -c user.name="$(git -C "$ROOT" config user.name || echo devbox)" \
    -c user.email="$(git -C "$ROOT" config user.email || echo devbox@microecom.local)" \
    commit --quiet -m "$1" -m "$2"
  git -C "$ENV_CLONE" push --quiet origin main
}

# Ask Argo CD to look now instead of on its 60s poll, then wait until the
# Application reports THIS env commit Synced + Healthy and the Deployment has
# finished rolling out the expected tag.
sync_wait() {  # <env> <svc> <tag>
  local app="$1-$2" want rev sync health img start=$SECONDS
  want="$(git -C "$ENV_CLONE" rev-parse HEAD)"
  $K -n argocd annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  log_info "waiting for $app to run $3 (env commit ${want:0:7})"
  while :; do
    IFS=$'\t' read -r rev sync health < <($K -n argocd get application "$app" -o json \
      | jq -r '[.status.sync.revisions[1] // "-", .status.sync.status // "-", .status.health.status // "-"] | @tsv')
    img="$($K -n apps get deploy "$2" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [[ "$rev" == "$want" && "$sync" == Synced && "$health" == Healthy && "$img" == *":$3" ]] \
       && $K -n apps rollout status deploy/"$2" --timeout=5s >/dev/null 2>&1; then
      log_ok "$app → $3 (Synced, Healthy, $((SECONDS - start))s)"
      return 0
    fi
    if (( SECONDS - start > ${DEVBOX_SYNC_TIMEOUT:-600} )); then
      log_err "$app did not converge: rev=${rev:0:7} sync=$sync health=$health image=$img"
      return 1
    fi
    sleep 5
  done
}

cmd_version() {
  local svc=${1:?usage: version <svc>}
  (cd "$ROOT" && version_of "$svc")
}

cmd_ship() {
  local svc=${1:?usage: ship <svc> [env]} env=${2:-$DEFAULT_ENV} tag prev
  env_sync_clone
  [[ -f "$(env_file "$env" "$svc")" ]] || { log_err "no $svc in env '$env' ($(env_file "$env" "$svc"))"; return 1; }
  tag="$(cd "$ROOT" && version_of "$svc")"
  ensure_registry
  if ! is_dirty_tag "$tag" && image_exists "$svc" "$tag"; then
    log_info "$svc:$tag is already in the registry — same inputs, no rebuild"
  else
    log_info "building $svc:$tag"
    (cd "$ROOT" && REGISTRY="$REGISTRY_HOST" TAG="$tag" SVC="$svc" deploy/images/build.sh)
  fi

  # The chart travels with the code: this branch's chart renders the new image.
  cmd_push >/dev/null
  prev="$(current_tag "$env" "$svc")"
  if [[ "$prev" == "$tag" ]]; then
    log_info "$env already pins $svc:$tag — nothing to commit"
  else
    set_tag "$env" "$svc" "$tag"
    env_commit_push "ship $svc $prev → $tag" \
      "from $(git -C "$ROOT" branch --show-current)@$(git -C "$ROOT" rev-parse --short HEAD) by make devbox-ship"
  fi
  sync_wait "$env" "$svc" "$tag"
  # Post-deploy smoke: the version is live, so check the API contract still
  # holds. SMOKE=0 skips it (devbox-proof does, to keep its timing honest).
  if [[ "${SMOKE:-1}" == 1 ]]; then cmd_api_test "$env"; fi
}

cmd_deploy() {
  local svc=${1:?usage: deploy <svc> <tag> [env]} tag=${2:?usage: deploy <svc> <tag> [env]} env=${3:-$DEFAULT_ENV} prev
  ensure_registry
  env_sync_clone
  if ! image_exists "$svc" "$tag"; then
    # A tag the registry doesn't have is a guaranteed ImagePullBackOff —
    # refuse before git records it.
    log_err "$svc:$tag is not in the registry. Available:"
    cmd_tags "$svc" >&2
    return 1
  fi
  prev="$(current_tag "$env" "$svc")"
  if [[ "$prev" == "$tag" ]]; then
    log_info "$env already pins $svc:$tag"
  else
    set_tag "$env" "$svc" "$tag"
    env_commit_push "deploy $svc $prev → $tag" "pinned by make devbox-deploy"
  fi
  sync_wait "$env" "$svc" "$tag"
}

cmd_tags() {
  local svc=${1:?usage: tags <svc>} created t used
  ensure_registry >/dev/null
  printf '%-28s %-20s %s\n' TAG BUILT "USED BY"
  while IFS=$'\t' read -r created t; do
    [[ -n "$t" ]] || continue
    used="$(envs_using "$svc" "$t")"
    printf '%-28s %-20s %s\n' "$t" "${created:--}" "${used:+← $used}"
  done < <(registry_tags_by_age "$svc")
}

# Retention, per service: keep (a) every tag an env file pins right now,
# (b) GC_PROTECTED_TAGS, (c) the newest <keep> of the rest. Remove the others —
# but never a manifest whose digest a kept tag shares: the registry removes by
# digest, so that would take the kept tag with it. Dry run unless <apply> = 1.
cmd_gc() {
  local keep=${1:-5} apply=${2:-0} svc created t d pinned kept n planned=0 pod
  local -a doomed=()
  ensure_registry
  env_sync_clone >/dev/null
  for svc in $(curl -fsS --max-time 5 "http://$REGISTRY_HOST/v2/_catalog?n=1000" | jq -r '.repositories[]'); do
    pinned=" $GC_PROTECTED_TAGS "
    for f in "$ENV_CLONE"/envs/*/services/"$svc".yaml; do
      [[ -f "$f" ]] || continue
      e="${f#"$ENV_CLONE"/envs/}"; e="${e%%/*}"
      pinned+="$(current_tag "$e" "$svc") "
    done
    kept=" "; n=0
    local -a cand=()
    while IFS=$'\t' read -r created t; do
      [[ -n "$t" ]] || continue
      d="$(image_digest "$svc" "$t")"
      if [[ "$pinned" == *" $t "* ]]; then kept+="$d "; continue; fi
      if (( n < keep )); then kept+="$d "; n=$((n + 1)); continue; fi
      cand+=("$svc|$t|$d")
    done < <(registry_tags_by_age "$svc")
    for c in ${cand[@]+"${cand[@]}"}; do
      if [[ "$kept" == *" ${c##*|} "* ]]; then
        log_info "keeping ${c%%|*}:$(cut -d'|' -f2 <<<"$c") — same image as a kept tag"
      else
        doomed+=("$c")
      fi
    done
  done

  for c in ${doomed[@]+"${doomed[@]}"}; do
    svc="${c%%|*}"; t="$(cut -d'|' -f2 <<<"$c")"; d="${c##*|}"
    planned=$((planned + 1))
    if [[ "$apply" == 1 ]]; then
      if curl -fsS --max-time 10 -o /dev/null -X DELETE "http://$REGISTRY_HOST/v2/$svc/manifests/$d"; then
        echo "  removed $svc:$t"
      else
        log_warn "could not remove $svc:$t"
      fi
    else
      echo "  would remove $svc:$t"
    fi
  done
  if (( planned == 0 )); then log_ok "nothing to remove (keep=$keep)"; return 0; fi
  if [[ "$apply" != 1 ]]; then
    log_info "$planned tag(s) would be removed. Re-run with APPLY=1 to remove them."
    return 0
  fi
  # Removing a manifest only drops the reference; layers stay on disk until the
  # registry's own collector sweeps blobs nothing points at. Don't run it while
  # a build is pushing — a half-pushed image looks unreferenced.
  pod="$($K -n kube-system get pods -o json \
    | jq -r '.items[] | select(any(.spec.containers[]; .name == "registry")) | .metadata.name' | head -1)"
  log_info "reclaiming disk: registry garbage-collect in $pod"
  # The collector logs at debug level on stderr — hundreds of lines; keep the count.
  n="$($K -n kube-system exec "$pod" -c registry -- \
    registry garbage-collect --delete-untagged /etc/distribution/config.yml 2>&1 | grep -c 'Deleting blob' || true)"
  log_ok "gc done — $n blob(s) freed"
}

# Phase 2's acceptance check — each step proves one promise. Prints a
# PASS/FAIL table, exits non-zero on any FAIL, and leaves order-service on the
# freshly shipped tag.
cmd_proof() {
  local svc=order-service env=$DEFAULT_ENV new prev back failed=0 healed=false
  local -a results=()
  check() { if eval "$2"; then results+=("PASS|$1"); else results+=("FAIL|$1"); failed=1; fi; }
  # Running = the Deployment names the tag, the rollout is done, AND every pod's
  # imageID carries that tag's registry digest. The tag alone isn't enough: two
  # tags can name the same bytes, and then a "rollback" changes nothing.
  running() {
    local want_digest ids
    want_digest="$(image_digest "$svc" "$1")"
    [[ "$($K -n apps get deploy "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}')" == *":$1" ]] \
      && $K -n apps rollout status deploy/"$svc" --timeout=10s >/dev/null 2>&1 || return 1
    ids="$($K -n apps get pods -l app.kubernetes.io/name="$svc" -o json \
      | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .status.containerStatuses[0].imageID')"
    [[ -n "$ids" && -n "$want_digest" ]] && ! grep -qv "@$want_digest\$" <<<"$ids"
  }

  env_sync_clone
  ensure_registry
  prev="$(current_tag "$env" "$svc")"
  new="$(cd "$ROOT" && version_of "$svc")"
  back="$prev"; [[ "$back" == "$new" ]] && back=dev

  if SMOKE=0 cmd_ship "$svc" "$env"; then check "ship: $svc runs $new" "running $new"
  else check "ship: $svc runs $new" false; fi

  # The rollback target must be DIFFERENT BYTES, or the rollback proves nothing.
  # Same build inputs reproduce the same image (dev and a fresh build often
  # share a digest), so derive a distinct "previous version": the new image plus
  # a label — a new digest, nothing else changed.
  if [[ "$(image_digest "$svc" "$back")" == "$(image_digest "$svc" "$new")" ]]; then
    back=proof-previous
    log_info "rollback target has the same digest as $new — building $svc:$back (same image + a label)"
    printf 'FROM %s/%s:%s\nLABEL devbox.proof="%s"\n' "$REGISTRY_HOST" "$svc" "$new" "$(date +%s)" \
      | docker build -q -t "$REGISTRY_HOST/$svc:$back" - >/dev/null
    docker push -q "$REGISTRY_HOST/$svc:$back" >/dev/null
  fi
  log_info "proof: shipped $svc:$new · roll back to $back · roll forward · drift"
  check "rollback target $back is different bytes from $new" \
    "[[ \"\$(image_digest $svc $back)\" != \"\$(image_digest $svc $new)\" ]]"

  if cmd_deploy "$svc" "$back" "$env"; then check "rollback: $svc runs $back" "running $back"
  else check "rollback: $svc runs $back" false; fi
  check "history: env repo's last commit for $svc is the rollback" \
    "git -C '$ENV_CLONE' log -1 --format=%s -- envs/$env/services/$svc.yaml | grep -q '→ $back\$'"
  if cmd_deploy "$svc" "$new" "$env"; then check "roll forward: $svc runs $new again" "running $new"
  else check "roll forward: $svc runs $new again" false; fi
  check "history: Argo CD's revision == env repo HEAD" \
    "[[ \"\$($K -n argocd get application $env-$svc -o jsonpath='{.status.sync.revisions[1]}')\" == \"\$(git -C '$ENV_CLONE' rev-parse HEAD)\" ]]"

  log_info "drift: kubectl set image $svc → :$back behind git's back"
  $K -n apps set image deploy/"$svc" "$svc=localhost:5000/$svc:$back" >/dev/null
  for _ in $(seq 1 24); do
    sleep 5
    if [[ "$($K -n apps get deploy "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}')" == *":$new" ]]; then
      healed=true; break
    fi
  done
  check "drift: self-heal puts $new back" "$healed"
  $K -n apps rollout status deploy/"$svc" --timeout=5m >/dev/null 2>&1 || true

  echo
  for r in "${results[@]}"; do
    if [[ "${r%%|*}" == PASS ]]; then printf '  \033[32mPASS\033[0m  %s\n' "${r#*|}"
    else printf '  \033[31mFAIL\033[0m  %s\n' "${r#*|}"; fi
  done
  echo
  return "$failed"
}

# ── envs: create / delete / list / proof ────────────────────────────────────
#
# What an env OWNS is decided by lib/env_gen.py alone (names, topics, files),
# so create, delete and the proof can never disagree about it.

ENV_GEN="$DEVBOX/lib/env_gen.py"
TOPICS_FILE="$ROOT/deploy/k8s-jobs/04-kafka-connect-register/topics.txt"
MAX_PREVIEWS="${MAX_PREVIEWS:-1}"

env_names() {  # <env> → shell assignments (NS MYSQL_DB MONGO_DB PREFIX CONNECTOR CDC_PREFIX CDC_TOPIC)
  python3 "$ENV_GEN" names --env "$1" | jq -r '
    "NS=\(.namespace|@sh) MYSQL_DB=\(.mysqlDb|@sh) MONGO_DB=\(.mongoDb|@sh) PREFIX=\(.prefix|@sh) CONNECTOR=\(.connector|@sh) CDC_PREFIX=\(.connectorTopicPrefix|@sh) CDC_TOPIC=\(.cdcTopic|@sh)"'
}

preview_name() {  # <name> → preview-<name> (accepts either form)
  local n=${1:?env name required (e.g. cart → preview-cart)}
  [[ "$n" == preview-* ]] && echo "$n" || echo "preview-$n"
}

# Root credentials are read INSIDE the infra pods from their own env/config —
# never put on this host's argv.
mysql_root() {  # <sql>
  $K -n infra exec -i mysql-0 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B 2>/dev/null' <<<"$1"
}
mongo_root() {  # <js>  (root/root is the infra chart's local-only admin user)
  $K -n infra exec -i mongodb-0 -c mongodb -- mongosh --quiet -u root -p root --authenticationDatabase admin <<<"$1"
}
kafka_sh() {  # <script> — runs in kafka-0 with the Kafka CLI on PATH
  $K -n infra exec -i kafka-0 -c kafka -- sh -c 'PATH=/opt/kafka/bin:$PATH; sh -s' <<<"$1"
}
connect_curl() {  # <args...> — curl from the Kafka Connect pod (it has curl)
  $K -n infra exec -i deploy/kafka-connect -c connect -- curl -fsS "$@"
}

cmd_env_list() {
  env_sync_clone >/dev/null
  printf '%-22s %-24s %s\n' ENV NAMESPACE "APPS (synced+healthy / total)"
  local d e total ready
  for d in "$ENV_CLONE"/envs/*/; do
    e="$(basename "$d")"
    total="$($K -n argocd get applications -l devbox.env="$e" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$($K -n argocd get applications -l devbox.env="$e" -o json 2>/dev/null \
      | jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy")] | length')"
    printf '%-22s %-24s %s/%s\n' "$e" "$(awk '/^    apps:/ { print $2; exit }' "$d/env.yaml")" "$ready" "$total"
  done
}

cmd_env_create() {
  local env; env="$(preview_name "${1:-}")"
  local NS MYSQL_DB MONGO_DB PREFIX CONNECTOR CDC_PREFIX CDC_TOPIC
  eval "$(env_names "$env")"
  env_sync_clone

  local existing
  existing="$(find "$ENV_CLONE/envs" -mindepth 1 -maxdepth 1 -type d -name 'preview-*' ! -name "$env" | wc -l | tr -d ' ')"
  if (( existing >= MAX_PREVIEWS )); then
    # Each preview is a full copy (~3 GB of requests even when small). The
    # cap protects the laptop, not a rule: raise it on purpose.
    log_err "already $existing preview env(s), cap is MAX_PREVIEWS=$MAX_PREVIEWS — delete one, or re-run with MAX_PREVIEWS=$((existing + 1))"
    return 1
  fi

  log_info "creating $env → namespace $NS, databases $MYSQL_DB, topics $PREFIX*"

  # 1. Namespace first, with app-secrets copied in: pods read mail/PayPal
  #    settings from it at start, and the optional secretRef would otherwise
  #    start them silently without.
  $K create namespace "$NS" --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K label namespace "$NS" devbox.env="$env" --overwrite >/dev/null
  $K -n apps get secret app-secrets -o json 2>/dev/null \
    | jq --arg ns "$NS" '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: $ns}}' \
    | $K apply -f - >/dev/null || log_warn "no app-secrets in apps to copy (mail/PayPal settings will be empty)"

  # 2. MySQL: an empty database the app user owns; Hibernate creates tables at
  #    boot, replication carries it to the replicas like any other database.
  mysql_root "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\`; GRANT ALL PRIVILEGES ON \`$MYSQL_DB\`.* TO 'ecommerce'@'%';"

  # 3. Kafka: the env's topics (auto-create is off cluster-wide).
  log_info "creating $(python3 "$ENV_GEN" topics --env "$env" --topics-file "$TOPICS_FILE" | wc -l | tr -d ' ') topics"
  kafka_sh "$(python3 "$ENV_GEN" topics --env "$env" --topics-file "$TOPICS_FILE" | while read -r t p c; do
    echo "kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists --topic '$t' --partitions $p --config cleanup.policy=$c >/dev/null"
  done)"

  # 4. Mongo: seed this env's database (api_role, catalog) BEFORE apps start —
  #    the gateway reads routes' roles from it at boot.
  MONGO_DB_NAME="$MONGO_DB" "$ROOT/deploy/scripts/seed.sh" --env k8s --stage pre-apps --context "$CONTEXT" >/dev/null \
    && log_ok "seeded Mongo $MONGO_DB"

  # 5. CDC: prod-like's connector config, re-pointed at this env's database
  #    and topic prefix. Copying it (not re-typing it) keeps the two in step.
  connect_curl "http://localhost:8083/connectors/$BASE_CONNECTOR_NAME/config" \
    | jq --arg db "$MONGO_DB" --arg p "$CDC_PREFIX" --arg n "$CONNECTOR" \
        '.name = $n | .database = $db | ."topic.prefix" = $p' \
    | connect_curl -X PUT -H 'Content-Type: application/json' --data @- \
        "http://localhost:8083/connectors/$CONNECTOR/config" >/dev/null \
    && log_ok "connector $CONNECTOR → $CDC_TOPIC"

  # 6. The env's files, committed: this is what makes it exist for Argo CD.
  if [[ ! -d "$ENV_CLONE/envs/$env" ]]; then
    local resolved; resolved="$(mktemp)"
    python3 "$ROOT/deploy/scripts/lib/secrets_resolve.py" --secrets-dir "$ROOT/deploy/secrets" --env k8s >"$resolved"
    python3 "$ENV_GEN" files --env "$env" --template-dir "$ENV_CLONE/envs/$DEFAULT_ENV" \
      --resolved "$resolved" --out "$ENV_CLONE/envs/$env"
    rm -f "$resolved"
    env_commit_push "create env $env" "from envs/$DEFAULT_ENV by make devbox-env-create (namespace $NS)"
  fi
  $K -n argocd annotate applicationset microecom-envs argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
  cmd_wait "$env"

  # 7. MySQL data needs the tables Hibernate just created; the reconcile then
  #    rebuilds the stock counters in THIS env's Redis.
  MYSQL_DB_NAME="$MYSQL_DB" APPS_NAMESPACE="$NS" \
    "$ROOT/deploy/scripts/seed.sh" --env k8s --stage post-apps --context "$CONTEXT" >/dev/null \
    && log_ok "seeded MySQL $MYSQL_DB (+ stock counters in $env's Redis)"
  $K -n infra exec -i mysql-0 -c mysql -- sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $MYSQL_DB 2>/dev/null" \
    <"$ROOT/deploy/k8s-jobs/06-perftest-seed/perftest-users.sql" && log_ok "seeded perftest users"

  log_ok "$env is up"
  cat <<EOF

  Browser:   http://$env.microecom.local      (API: http://api.$env.microecom.local)
  One-time:  add to /etc/hosts →  127.0.0.1 $env.microecom.local api.$env.microecom.local
             and keep the tunnel up →  sudo -v && make k8s-tunnel
  In-cluster gateway: http://gateway.$NS:6868

EOF
}

BASE_CONNECTOR_NAME=mongodb-source-connector

cmd_env_delete() {
  local env apply=${2:-0}; env="$(preview_name "${1:-}")"
  [[ "$env" != "$DEFAULT_ENV" ]] || { log_err "refusing to delete $DEFAULT_ENV"; return 1; }
  local NS MYSQL_DB MONGO_DB PREFIX CONNECTOR CDC_PREFIX CDC_TOPIC
  eval "$(env_names "$env")"
  env_sync_clone >/dev/null

  cat <<EOF
  $env owns:
    env repo     envs/$env/  ($(ls "$ENV_CLONE/envs/$env/services" 2>/dev/null | wc -l | tr -d ' ') service files)
    namespace    $NS
    MySQL        $MYSQL_DB      Mongo  $MONGO_DB
    Kafka        $(python3 "$ENV_GEN" topics --env "$env" --topics-file "$TOPICS_FILE" | wc -l | tr -d ' ') topics + consumer groups + schema subjects prefixed $PREFIX
    connector    $CONNECTOR
EOF
  if [[ "$apply" != 1 ]]; then
    log_info "dry run — re-run with APPLY=1 to delete all of the above"
    return 0
  fi

  # Apps first (so nothing is still writing), then the data they used.
  if [[ -d "$ENV_CLONE/envs/$env" ]]; then
    git -C "$ENV_CLONE" rm -rq "envs/$env"
    env_commit_push "delete env $env" "by make devbox-env-delete"
  fi
  $K -n argocd annotate applicationset microecom-envs argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
  local start=$SECONDS
  while [[ -n "$($K -n argocd get applications -l devbox.env="$env" -o name 2>/dev/null)" ]]; do
    (( SECONDS - start < 300 )) || { log_err "Applications for $env still present after 300s"; return 1; }
    sleep 5
  done
  log_ok "Applications and their resources removed"

  connect_curl -X DELETE "http://localhost:8083/connectors/$CONNECTOR" >/dev/null 2>&1 || true
  kafka_sh "
    for t in $(python3 "$ENV_GEN" topics --env "$env" --topics-file "$TOPICS_FILE" | awk '{print $1}' | tr '\n' ' '); do
      kafka-topics.sh --bootstrap-server localhost:9092 --delete --if-exists --topic \"\$t\" >/dev/null 2>&1
    done
    for g in \$(kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list 2>/dev/null | grep '^$PREFIX'); do
      kafka-consumer-groups.sh --bootstrap-server localhost:9092 --delete --group \"\$g\" >/dev/null 2>&1
    done"
  # Subject names follow topic names; delete soft, then permanently.
  for s in $(connect_curl http://schema-registry.infra.svc.cluster.local:8081/subjects | jq -r --arg p "$PREFIX" '.[] | select(startswith($p))'); do
    connect_curl -X DELETE "http://schema-registry.infra.svc.cluster.local:8081/subjects/$s" >/dev/null 2>&1 || true
    connect_curl -X DELETE "http://schema-registry.infra.svc.cluster.local:8081/subjects/$s?permanent=true" >/dev/null 2>&1 || true
  done
  log_ok "Kafka: connector, topics, consumer groups, schema subjects removed"

  mysql_root "DROP DATABASE IF EXISTS \`$MYSQL_DB\`;"
  mongo_root "db.getSiblingDB('$MONGO_DB').dropDatabase()" >/dev/null
  $K delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
  log_ok "$env deleted (databases dropped, namespace $NS gone)"
}

# Two envs, one order stream each. Orders sent to the preview's gateway must
# complete inside the preview — saga, topics, databases, Redis — and leave
# prod-like's data and topics untouched. Then deleting the env must remove
# everything it owned. Exits non-zero on any FAIL; KEEP=1 skips the delete.
cmd_env_proof() {
  local env; env="$(preview_name "${1:-proof}")"
  local NS MYSQL_DB MONGO_DB PREFIX CONNECTOR CDC_PREFIX CDC_TOPIC failed=0
  local -a results=()
  eval "$(env_names "$env")"
  check() { if eval "$2"; then results+=("PASS|$1"); else results+=("FAIL|$1"); failed=1; fi; }
  end_offsets() {  # <topic> → sum of end offsets (0 if missing)
    kafka_sh "kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic '$1' 2>/dev/null" \
      | awk -F: '{ s += $3 } END { print s + 0 }'
  }
  orders() { mysql_root "SELECT COUNT(*) FROM \`$1\`.\`order\`${2:+ WHERE status = '$2'};"; }

  [[ -n "$($K -n argocd get applications -l devbox.env="$env" -o name 2>/dev/null)" ]] || cmd_env_create "$env"

  local prod_orders prod_success prod_cdc
  prod_orders="$(orders ecommerce_dev)"
  prod_success="$(end_offsets order-service.order.success-status)"
  prod_cdc="$(end_offsets ecommerce_db.ecommerce_inventory.event)"
  log_info "prod-like before: $prod_orders orders, success-topic end offset $prod_success"

  log_info "k6: 3 users × 40s of checkout against $env's gateway"
  $K -n "$NS" run devbox-env-proof-k6 --rm -i --restart=Never --image=grafana/k6:0.54.0 --quiet -- \
    run --quiet --vus 3 --duration 40s -e BASE_URL="http://gateway:6868" -e INGRESS_ORIGIN="http://api.$env.microecom.local" \
    -e PRODUCT_IDS=67c000000000000000000001,67c000000000000000000002,67c000000000000000000003 - \
    <"$ROOT/deploy/k6-stress/payment-flow.js" >"$RUN_DIR/env-proof-k6.log" 2>&1 || true
  grep -E 'checks\.|iterations\.' "$RUN_DIR/env-proof-k6.log" | sed 's/^/    /'

  # payment-flow.js approves 90% / cancels 5% / fails 5% on purpose. A PayPal
  # cancel abandons the payment ATTEMPT, not the order: the saga stays
  # AWAITING_PAYMENT for a retry until saga-ttl-minutes (30) expires it
  # (SagaOrchestrationServiceImpl). So a PROCESSING order is legitimate iff its
  # saga is AWAITING_PAYMENT, not expired, with a CANCELED payment and no
  # successful one. Anything else PROCESSING is unexplained — and fails.
  # (Two earlier versions asserted "all completed", then "none PROCESSING";
  # both contradicted what the workload does by design.)
  unexplained() {
    mysql_root "SELECT COALESCE(SUM(CASE WHEN s.state = 'AWAITING_PAYMENT' AND s.expires_at > NOW()
        AND EXISTS (SELECT 1 FROM \`$MYSQL_DB\`.payment p WHERE p.order_id = o.id AND p.status = 'CANCELED')
        AND NOT EXISTS (SELECT 1 FROM \`$MYSQL_DB\`.payment p WHERE p.order_id = o.id AND p.status IN ('SUCCESS','PROCESSING'))
      THEN 0 ELSE 1 END), 0)
      FROM \`$MYSQL_DB\`.\`order\` o LEFT JOIN \`$MYSQL_DB\`.saga_instance s ON s.order_id = o.id
      WHERE o.status = 'PROCESSING';"
  }
  local start=$SECONDS
  while [[ "$(unexplained)" != 0 ]] && (( SECONDS - start < 180 )); do sleep 5; done

  local pv_orders pv_done pv_cancel pv_failed pv_waiting pv_unexplained
  pv_orders="$(orders "$MYSQL_DB")"; pv_done="$(orders "$MYSQL_DB" COMPLETED)"
  pv_cancel="$(orders "$MYSQL_DB" CANCELED)"; pv_failed="$(orders "$MYSQL_DB" FAILED)"
  pv_unexplained="$(unexplained)"; pv_waiting=$(( $(orders "$MYSQL_DB" PROCESSING) - pv_unexplained ))
  check "preview took orders ($pv_orders)" "(( pv_orders > 0 ))"
  check "every preview order settled in the preview: completed $pv_done, failed $pv_failed, canceled $pv_cancel, awaiting retry after a PayPal cancel $pv_waiting, unexplained $pv_unexplained" \
    "(( pv_unexplained == 0 && pv_done > 0 && pv_done + pv_cancel + pv_failed + pv_waiting == pv_orders ))"
  check "preview's own success topic carried them" "(( \$(end_offsets ${PREFIX}order-service.order.success-status) >= pv_done ))"
  check "preview's own CDC topic carried the saga trigger" "(( \$(end_offsets $CDC_TOPIC) > 0 ))"
  check "prod-like orders unchanged ($prod_orders)" "[[ \$(orders ecommerce_dev) == $prod_orders ]]"
  check "prod-like success topic unchanged" "[[ \$(end_offsets order-service.order.success-status) == $prod_success ]]"
  check "prod-like CDC topic unchanged" "[[ \$(end_offsets ecommerce_db.ecommerce_inventory.event) == $prod_cdc ]]"

  # Browser path (3c), through the real ingress-nginx controller with Host
  # headers — from inside the cluster, so it needs no sudo tunnel.
  local shop="$env.microecom.local" api="api.$env.microecom.local" ing=ingress-nginx-controller.infra.svc.cluster.local
  local browser
  browser="$($K -n "$NS" run devbox-env-proof-browser --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- sh -c "
    echo config=\$(curl -s -H 'Host: $shop' http://$ing/config.js)
    echo products=\$(curl -s -o /dev/null -w %{http_code} -H 'Host: $api' 'http://$ing/product-service/v1/products?page=1&size=1')
    echo cors_own=\$(curl -s -o /dev/null -D - -X OPTIONS -H 'Host: $api' -H 'Origin: http://$shop' -H 'Access-Control-Request-Method: GET' http://$ing/product-service/v1/products | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2)
    echo cors_prod=\$(curl -s -o /dev/null -D - -X OPTIONS -H 'Host: $api' -H 'Origin: http://microecom.local' -H 'Access-Control-Request-Method: GET' http://$ing/product-service/v1/products | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2)
    echo prod_config=\$(curl -s -H 'Host: microecom.local' http://$ing/config.js)
  " 2>/dev/null)"
  printf '%s\n' "$browser" | sed 's/^/    /'
  check "browser: $shop's /config.js points the SPA at $api" "grep -q 'config=.*apiBaseUrl: \"http://$api\"' <<<\"\$browser\""
  check "browser: $api serves the catalog through its Ingress" "grep -qx 'products=200' <<<\"\$browser\""
  check "browser: CORS allows http://$shop" "grep -qx 'cors_own=http://$shop' <<<\"\$browser\""
  check "browser: CORS refuses prod-like's origin" "grep -qx 'cors_prod=' <<<\"\$browser\""
  check "browser: prod-like's storefront config untouched" "! grep -q 'prod_config=.*$env' <<<\"\$browser\""

  if [[ "${KEEP:-0}" != 1 ]]; then
    cmd_env_delete "$env" 1
    check "delete: namespace $NS gone" "! $K get namespace $NS >/dev/null 2>&1"
    check "delete: MySQL $MYSQL_DB dropped" "[[ -z \$(mysql_root \"SHOW DATABASES LIKE '$MYSQL_DB'\") ]]"
    check "delete: Mongo $MONGO_DB dropped" "! mongo_root \"db.adminCommand('listDatabases').databases.map(d => d.name).join(' ')\" | grep -qw $MONGO_DB"
    check "delete: no ${PREFIX}* topics left" "[[ -z \$(kafka_sh 'kafka-topics.sh --bootstrap-server localhost:9092 --list' | grep '^${PREFIX}\|^${CDC_PREFIX}') ]]"
    check "delete: connector $CONNECTOR gone" "! connect_curl http://localhost:8083/connectors | grep -q '\"$CONNECTOR\"'"
    check "delete: prod-like still Synced + Healthy" "DEVBOX_WAIT_TIMEOUT=60 cmd_wait $DEFAULT_ENV >/dev/null"
  fi

  echo
  for r in "${results[@]}"; do
    if [[ "${r%%|*}" == PASS ]]; then printf '  \033[32mPASS\033[0m  %s\n' "${r#*|}"
    else printf '  \033[31mFAIL\033[0m  %s\n' "${r#*|}"; fi
  done
  echo
  return "$failed"
}

# ── API contract tests (phase 6) ────────────────────────────────────────────
#
# api-tests/ is a Bruno collection: open it in the Bruno GUI to click around,
# or run it here. The collection is streamed into a one-off node pod IN the
# env's namespace, so `gateway:6868` is that env's gateway — the same trick as
# the k6 runs. Exits non-zero when any test fails.
BRUNO_CLI_VERSION=4.2.1

cmd_api_test() {
  local env=${1:-$DEFAULT_ENV} ns origin code=0 log
  env_sync_clone >/dev/null
  [[ -d "$ENV_CLONE/envs/$env" ]] || { log_err "no env '$env' (make devbox-env-list)"; return 1; }
  if [[ "$env" == "$DEFAULT_ENV" ]]; then ns=apps; origin=http://api.microecom.local
  else
    local NS MYSQL_DB MONGO_DB PREFIX CONNECTOR CDC_PREFIX CDC_TOPIC; eval "$(env_names "$env")"
    ns=$NS; origin="http://api.$env.microecom.local"
  fi
  log="$RUN_DIR/api-test-$env.log"
  log_info "API contract tests (api-tests/, Bruno $BRUNO_CLI_VERSION) against $env"
  # shellcheck disable=SC2016 # expanded inside the pod
  # COPYFILE_DISABLE: macOS tar would add an AppleDouble `._x.bru` for every
  # file, which Bruno counts as extra (skipped) requests.
  COPYFILE_DISABLE=1 tar -C "$ROOT/api-tests" --exclude node_modules -cf - . | $K -n "$ns" run "devbox-api-test-$(date +%H%M%S)" --rm -i --restart=Never \
    --image=node:20-alpine --quiet -- sh -c '
      mkdir -p /c && cd /c && tar xf - &&
      npx -y "@usebruno/cli@$0" run -r --env devbox \
        --env-var baseUrl=http://gateway:6868 --env-var "apiOrigin=$1" \
        --reporter-skip-all-headers 2>&1' "$BRUNO_CLI_VERSION" "$origin" >"$log" 2>&1 || code=$?
  # Only FAILED tests (✕), each with its request and reason — not "non-2xx
  # requests": the suite's negative tests expect 400/401/403 and pass. The log
  # is full of ANSI colour (which also makes grep call it binary): strip it.
  sed 's/\x1b\[[0-9;]*m//g' "$log" | awk '
    /^[0-9][0-9] [^ ].* \([0-9][0-9][0-9] / { req = $0; shown = 0; next }
    /^ +✕ / { if (!shown) { print "    " req; shown = 1 }
              sub(/^ +/, ""); print "      " $0; getline; sub(/^ +/, ""); print "        " $0 }' | head -30
  sed 's/\x1b\[[0-9;]*m//g' "$log" | sed -n '/Execution Summary/,$p' | grep -aE 'Requests|Tests|Assertions' \
    | sed 's/[│┌┐└┘├┤─]//g; s/^ */    /'
  if [[ "$code" == 0 ]]; then log_ok "$env: API contract holds"
  else log_err "$env: API contract broken — full output in $log"; fi
  return "$code"
}

# shellcheck source=lib/perf.sh
. "$DEVBOX/lib/perf.sh"

case "${1:-}" in
  api-test)
    shift; cmd_api_test "$@" ;;
  perf|perf-runs|perf-compare)
    cmd="cmd_${1//-/_}"; shift; "$cmd" "$@" ;;
  env-list|env-create|env-delete|env-proof)
    cmd="cmd_${1//-/_}"; shift; "$cmd" "$@" ;;
  platform|push|apps|wait|open|close|status|version|ship|deploy|tags|gc|proof|portal)
    cmd="cmd_$1"; shift; "$cmd" "$@" ;;
  *) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
