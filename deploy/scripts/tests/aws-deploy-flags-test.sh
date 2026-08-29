#!/usr/bin/env bash
# Guards the render-vs-apply split in deploy/scripts/aws-deploy.sh.
#
# WHY THIS EXISTS. `--set infra.enabled=false` was once written inline in the
# script's `--render` branch only. The real apply execs `make k8s-apps-helm`,
# whose recipe composes its own helm call from $(HELM_EXTRA) -- so the two paths
# issued DIFFERENT commands, and `make aws-diff-test` validated the one that
# never runs. Live, the umbrella tried to create objects owned by the separate
# releases scripts/aws/infra-up.sh installs, and helm refused:
#
#   Error: ServiceAccount "grafana" in namespace "monitoring" exists and cannot
#   be imported into the current release ... must equal "microecom"
#
# aws-diff-test.sh cannot catch that: it runs its OWN hand-copied `helm template`
# invocation and never executes aws-deploy.sh at all. So deleting the flag today
# leaves every existing suite green, and you find out at EKS rates.
#
# This suite closes that by driving the SCRIPT and asserting on what it emits.
# Offline: `--render` with AWS_TF_OUTPUTS_JSON needs no AWS, no cluster, no
# credentials.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

SCRIPT="deploy/scripts/aws-deploy.sh"
FIXTURE="deploy/charts/microecom/tests/fixtures/aws-tf-outputs.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# 0. Anti-vacuity: without these the rows below would pass for the wrong reason.
[ -f "$SCRIPT" ]  && ok "aws-deploy.sh present" || bad "aws-deploy.sh missing — every row below is meaningless"
[ -f "$FIXTURE" ] && ok "tf-outputs fixture present" || bad "fixture missing — the render rows cannot run"
command -v helm >/dev/null 2>&1 && ok "helm on PATH" || bad "helm not found — the render rows cannot run"
command -v jq   >/dev/null 2>&1 && ok "jq on PATH"   || bad "jq not found — the script cannot read the fixture"

# Render to a FILE, and grep the file -- never `printf "$RENDER" | grep -q`.
# `grep -q` exits on first match and closes the pipe; when the render exceeds the
# 64KB pipe buffer, printf takes SIGPIPE (141) and `pipefail` makes the pipeline
# non-zero DESPITE the match, inverting every deny row. That bites only when the
# infra subchart IS enabled (163KB) and not when it is disabled (53KB) -- i.e.
# exactly in the state this suite exists to detect. Found by mutation-testing.
RENDER_OUT="$(mktemp)"
trap 'rm -f "$RENDER_OUT"' EXIT
AWS_TF_OUTPUTS_JSON="$FIXTURE" bash "$SCRIPT" --render >"$RENDER_OUT" 2>/dev/null
render_rc=$?
if [ "$render_rc" -eq 0 ] && [ -s "$RENDER_OUT" ]; then
    ok "aws-deploy.sh --render produced output ($(wc -c <"$RENDER_OUT" | tr -d ' ') bytes)"
else
    bad "aws-deploy.sh --render failed (rc=$render_rc) — later rows are meaningless"
fi

# 1. THE REGRESSION GUARD. Assert the infra subchart is absent, keyed on the
#    exact object the live collision named.
grep -q 'name: grafana' "$RENDER_OUT" \
  && bad "render contains a grafana object — infra subchart is ENABLED (the live-collision bug is back)" \
  || ok "render contains no grafana object"

grep -q 'namespace: monitoring' "$RENDER_OUT" \
  && bad "render targets the monitoring namespace — infra subchart is ENABLED" \
  || ok "render targets no monitoring-namespaced object"

grep -qE 'name: (mongodb|kafka|schema-registry|vmsingle)' "$RENDER_OUT" \
  && bad "render contains an infra StatefulSet/Deployment — infra subchart is ENABLED" \
  || ok "render contains no infra workload"

# 2. Positive control: the apps ARE rendered. Without this, a script emitting
#    nothing at all would pass every deny row above.
grep -q 'name: gateway' "$RENDER_OUT" \
  && ok "render DOES contain the apps (gateway present)" \
  || bad "render contains no gateway — apps subchart is disabled, deny rows above prove nothing"

# 3. The flag must reach the APPLY path too, not just render. The apply branch
#    hands HELM_EXTRA to make, so assert the composition statically -- executing
#    it would deploy to a live cluster.
grep -q 'HELM_EXTRA="\${HELM_FLAGS\[\*\]}"' "$SCRIPT" \
  && ok "apply path passes HELM_FLAGS through HELM_EXTRA" \
  || bad "apply path does not pass HELM_FLAGS — render and apply have diverged again"

grep -qE '^\s*--set infra\.enabled=false' "$SCRIPT" \
  && ok "infra.enabled=false is in the shared array" \
  || bad "infra.enabled=false missing from the shared array"

# 4. It must be --set, not --set-string. helm's processDependencyEnabled
#    type-asserts a condition value to bool; on a non-bool it warns and leaves
#    Enabled at its pre-initialized true, so --set-string renders the subchart
#    anyway while the flag LOOKS present.
grep -q -- '--set-string "\?infra\.enabled' "$SCRIPT" \
  && bad "infra.enabled uses --set-string — helm ignores a non-bool condition and enables the subchart" \
  || ok "infra.enabled uses --set, not --set-string"

# 5. The flag must NOT be inline in the render branch — that is the original bug.
if awk '/^if \[ "\$MODE" = "render" \]/,/^fi$/' "$SCRIPT" | grep -q 'infra\.enabled'; then
    bad "infra.enabled is inline in the render branch — the render/apply split is back"
else
    ok "infra.enabled is not inline in the render branch"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
