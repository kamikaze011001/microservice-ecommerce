# shellcheck shell=bash
# Perf as a golden path (devbox phase 4). Sourced by devbox.sh — uses its $K,
# start_forward, env_sync_clone, current_tag, env_names.
#
#   perf <scenario> [env] [profile]   run k6 against an env, tagged with every
#                                     service's image version; record the run
#   perf-runs                         recorded runs, newest first
#   perf-compare <run-a> <run-b>      p95 / error rate per request, and which
#                                     versions differ between the two runs
#
# VictoriaMetrics is the only store: k6 remote-writes its metrics with
# devbox_* labels, and each run adds one devbox_perf_run sample (value = k6's
# exit code, 0 = thresholds held). No local state to lose or drift.

VM_LOCAL_PORT=8429
VM_LOCAL="http://localhost:$VM_LOCAL_PORT"
VM_IN_CLUSTER=http://vmsingle.monitoring.svc.cluster.local:8428
PERF_DASHBOARD="${DEVBOX:-}/dashboards/devbox-perf.json"

vm_forward() { start_forward vm monitoring vmsingle "$VM_LOCAL_PORT" 8428 /health; }

vm_query() {  # <promql> → JSON result array
  curl -fsS --max-time 15 "$VM_LOCAL/api/v1/query" --data-urlencode "query=$1" | jq -c '.data.result'
}

# scenario → script, and the k6 arguments for a profile. The payment script
# has fixed stages (its load profile), so smoke = a small CLI override; the
# storefront script picks its own shape from PROFILE.
perf_script() {
  case "$1" in
    payment)    echo "$ROOT/deploy/k6-stress/payment-flow.js" ;;
    storefront) echo "$ROOT/deploy/k6-stress/storefront-flow.js" ;;
    *) log_err "unknown scenario '$1' (payment | storefront)"; return 1 ;;
  esac
}
perf_profile_args() {  # <scenario> <profile>
  case "$1:$2" in
    payment:smoke)                  echo "--vus 3 --duration 30s" ;;
    payment:load)                   echo "" ;;
    storefront:smoke|storefront:soak|storefront:stress) echo "-e PROFILE=$2" ;;
    *) log_err "profile '$2' isn't defined for $1 (payment: smoke|load; storefront: smoke|soak|stress)"; return 1 ;;
  esac
}

# "authorization-server=dev,bff-service=dev,…,order-service=ac48ad8" — what
# the env ran, read from the env repo (the truth), not from the cluster.
env_versions() {  # <env>
  local f svc out=""
  for f in "$ENV_CLONE"/envs/"$1"/services/*.yaml; do
    svc="$(basename "$f" .yaml)"
    [[ "$svc" == redis ]] && continue
    out+="${out:+,}$svc=$(current_tag "$1" "$svc")"
  done
  echo "$out"
}

ensure_perf_dashboard() {
  start_forward grafana monitoring grafana "$GRAFANA_LOCAL_PORT" 80 /api/health >/dev/null || return 0
  jq -n --slurpfile d "$PERF_DASHBOARD" '{dashboard: $d[0], overwrite: true, folderId: 0}' \
    | curl -fsS -u admin:admin -H 'Content-Type: application/json' --data @- \
        "http://localhost:$GRAFANA_LOCAL_PORT/api/dashboards/db" >/dev/null \
    || log_warn "could not upload the devbox-perf dashboard (Grafana down?)"
}

cmd_perf() {
  local scenario=${1:?usage: perf <payment|storefront> [env] [profile]} env=${2:-$DEFAULT_ENV}
  local profile=${3:-smoke} script args run ns versions start code
  script="$(perf_script "$scenario")" || return 1
  args="$(perf_profile_args "$scenario" "$profile")" || return 1
  env_sync_clone >/dev/null
  [[ -d "$ENV_CLONE/envs/$env" ]] || { log_err "no env '$env' (make devbox-env-list)"; return 1; }
  if [[ "$env" == "$DEFAULT_ENV" ]]; then ns=apps; else
    local NS MYSQL_DB MONGO_DB PREFIX CONNECTOR CDC_PREFIX CDC_TOPIC; eval "$(env_names "$env")"; ns=$NS; fi
  versions="$(env_versions "$env")"
  run="$env-$scenario-$(date +%m%d-%H%M%S)"

  log_info "perf run $run ($profile) against $env"
  echo "    versions: $versions"
  start=$SECONDS; code=0
  # `|| code=$?`: a failed threshold is a RESULT to record, not a reason for
  # set -e to abort before the run is written down.
  # shellcheck disable=SC2086 # $args is a list of k6 flags
  $K -n "$ns" run "devbox-perf-$(date +%H%M%S)" --rm -i --restart=Never --image=grafana/k6:0.54.0 --quiet \
    --env="K6_PROMETHEUS_RW_SERVER_URL=$VM_IN_CLUSTER/api/v1/write" \
    --env='K6_PROMETHEUS_RW_TREND_STATS=p(95),p(99),avg,max' \
    -- run --quiet -o experimental-prometheus-rw $args \
    --tag devbox_run="$run" --tag devbox_env="$env" --tag devbox_scenario="$scenario" --tag devbox_profile="$profile" \
    -e BASE_URL=http://gateway:6868 \
    -e INGRESS_ORIGIN="$( [[ "$env" == "$DEFAULT_ENV" ]] && echo http://api.microecom.local || echo "http://api.$env.microecom.local")" \
    -e PRODUCT_IDS=67c000000000000000000001,67c000000000000000000002,67c000000000000000000003 \
    - <"$script" >"$RUN_DIR/perf-$run.log" 2>&1 || code=$?
  grep -E '✓|✗|checks\.|iterations\.|http_req_failed' "$RUN_DIR/perf-$run.log" | sed 's/^/    /'

  # One sample per run carries everything the comparison needs to name it.
  vm_forward >/dev/null
  printf 'devbox_perf_run{run="%s",env="%s",scenario="%s",profile="%s",duration_s="%s",versions="%s"} %s\n' \
    "$run" "$env" "$scenario" "$profile" "$((SECONDS - start))" "$versions" "$code" \
    | curl -fsS --max-time 10 --data-binary @- "$VM_LOCAL/api/v1/import/prometheus" \
    || log_warn "could not record the run in VictoriaMetrics"
  # VictoriaMetrics hides samples younger than -search.latencyOffset (30s) from
  # queries, so a compare run right after this would say "no recorded run".
  # Return only once the record is visible.
  local seen=0
  for _ in $(seq 1 30); do
    [[ "$(vm_query "devbox_perf_run{run=\"$run\"}" | jq length)" -gt 0 ]] && { seen=1; break; }
    sleep 2
  done
  (( seen )) || log_warn "run $run not queryable yet — give VictoriaMetrics a minute before comparing"
  ensure_perf_dashboard

  if [[ "$code" == 0 ]]; then log_ok "$run: thresholds held"
  else log_err "$run: k6 exited $code (99 = a threshold failed) — see $RUN_DIR/perf-$run.log"; fi
  echo "    compare:  make devbox-perf-compare a=<earlier run> b=$run"
  echo "    grafana:  http://localhost:$GRAFANA_LOCAL_PORT/d/devbox-perf  (make devbox-open)"
  return "$code"
}

cmd_perf_runs() {
  vm_forward >/dev/null
  { printf 'RUN\tPROFILE\tRESULT\tDURATION\n'
    vm_query 'last_over_time(devbox_perf_run[90d])' | jq -r '
      sort_by(.metric.run) | reverse | .[] |
      [.metric.run, .metric.profile, (if .value[1] == "0" then "PASS" else "FAIL(" + .value[1] + ")" end), .metric.duration_s + "s"] | @tsv'
  } | column -t -s $'\t'
}

# versions_diff "<svc=tag,…>" "<svc=tag,…>" — the services whose tag differs.
# Separate so tests/perf-test.sh can pin it without a cluster.
versions_diff() {
  jq -rn --arg va "$1" --arg vb "$2" '
    def m: if . == "" then {} else split(",") | map(split("=") | {(.[0]): .[1]}) | add end;
    ($va | m) as $A | ($vb | m) as $B
    | [($A + $B | keys)[] | select($A[.] != $B[.]) | "    \(.)  \($A[.] // "-") → \($B[.] // "-")"]
    | if length == 0 then "    none — same code, so any delta is noise or environment" else .[] end'
}

cmd_perf_compare() {
  local a=${1:?usage: perf-compare <run-a> <run-b>} b=${2:?usage: perf-compare <run-a> <run-b>}
  vm_forward >/dev/null
  local meta_a meta_b
  meta_a="$(vm_query "last_over_time(devbox_perf_run{run=\"$a\"}[90d])" | jq -c '.[0].metric // empty')"
  meta_b="$(vm_query "last_over_time(devbox_perf_run{run=\"$b\"}[90d])" | jq -c '.[0].metric // empty')"
  [[ -n "$meta_a" ]] || { log_err "no recorded run '$a' (make devbox-perf-runs)"; return 1; }
  [[ -n "$meta_b" ]] || { log_err "no recorded run '$b' (make devbox-perf-runs)"; return 1; }

  # Whole-run figures: k6's prometheus output keeps trend stats cumulative over
  # the test, so a run's LAST sample is its overall p95. Setup requests
  # (admin login, inventory top-up) aren't the workload — excluded.
  per_name() {  # <metric> <run> <agg>
    vm_query "$3 by (name) (last_over_time($1{devbox_run=\"$2\",group!=\"::setup\"}[90d]))" \
      | jq -c 'map({(.metric.name): (.value[1] | tonumber)}) | add // {}'
  }
  local p95a p95b erra errb reqa reqb
  p95a="$(per_name k6_http_req_duration_p95 "$a" max)"; p95b="$(per_name k6_http_req_duration_p95 "$b" max)"
  erra="$(per_name k6_http_req_failed_rate "$a" max)"; errb="$(per_name k6_http_req_failed_rate "$b" max)"
  reqa="$(per_name k6_http_reqs_total "$a" sum)";     reqb="$(per_name k6_http_reqs_total "$b" sum)"

  echo
  printf '  A  %s   (%s, %ss)\n  B  %s   (%s, %ss)\n\n' \
    "$a" "$(jq -r .profile <<<"$meta_a")" "$(jq -r .duration_s <<<"$meta_a")" \
    "$b" "$(jq -r .profile <<<"$meta_b")" "$(jq -r .duration_s <<<"$meta_b")"
  jq -rn --argjson pa "$p95a" --argjson pb "$p95b" --argjson ea "$erra" --argjson eb "$errb" \
         --argjson ra "$reqa" --argjson rb "$reqb" '
    def ms: if . == null then "-" else (. * 1000 | round | tostring) + "ms" end;
    def pct: if . == null then "-" else (. * 100 * 10 | round / 10 | tostring) + "%" end;
    def delta($x; $y): if $x == null or $y == null or $x == 0 then "-"
                       else ((($y - $x) / $x * 100) | round) as $d | (if $d > 0 then "+" else "" end) + ($d | tostring) + "%" end;
    # A p95 over a handful of requests swings tens of percent between two
    # runs of the SAME code — flag it rather than let it read as a finding.
    def few($n): (($ra[$n] // 0) < 30 or ($rb[$n] // 0) < 30);
    ["REQUEST","A p95","B p95","Δ p95","A err","B err","A reqs","B reqs",""],
    ( ([$pa, $pb] | map(keys) | add | unique)[] as $n |
      [$n, ($pa[$n] | ms), ($pb[$n] | ms), delta($pa[$n]; $pb[$n]),
       ($ea[$n] | pct), ($eb[$n] | pct), ($ra[$n] // "-" | tostring), ($rb[$n] // "-" | tostring),
       (if few($n) then "<30 reqs: noise" else "" end)] )
    | @tsv' | column -t -s $'\t' | sed 's/^/  /'

  # What actually changed between the two runs — the reason to compare at all.
  echo
  echo "  versions that differ:"
  versions_diff "$(jq -r .versions <<<"$meta_a")" "$(jq -r .versions <<<"$meta_b")"
  if [[ "$(jq -r .env <<<"$meta_a")" != "$(jq -r .env <<<"$meta_b")" ]]; then
    echo "    (different envs: $(jq -r .env <<<"$meta_a") vs $(jq -r .env <<<"$meta_b") — previews run smaller pods)"
  fi
  echo
}
