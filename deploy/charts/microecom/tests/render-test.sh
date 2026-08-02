#!/usr/bin/env bash
# Assertion harness over `helm template`. No cluster required.
#
#   ./deploy/charts/microecom/tests/render-test.sh
#
# Each task appends a section. A section renders the chart with some values and
# asserts on the YAML text. `helm template` never evaluates `lookup`, so tests
# that depend on live cluster state belong in the E2E task, not here.
set -uo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0

render() {
  helm template microecom "$CHART_DIR" --namespace infra "$@" 2>&1
}

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# assert_has <description> <extended-regex> <text>
assert_has() {
  if printf '%s\n' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1"; fi
}

# assert_lacks <description> <extended-regex> <text>
assert_lacks() {
  if printf '%s\n' "$3" | grep -qE -- "$2"; then bad "$1"; else ok "$1"; fi
}

# assert_ok <description> <text>  — text is a render result; fail if it looks like an error
assert_ok() {
  if printf '%s\n' "$2" | grep -qiE '^Error:|template:.*(error|not defined)'; then
    bad "$1"
    printf '%s\n' "$2" | head -20 | sed 's/^/       /'
  else
    ok "$1"
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── Task 1: scaffold and gating ─────────────────────────────────────────────
section "scaffold and dependency gating"

out="$(render)"
assert_ok    "default values render"                            "$out"
assert_has   "apps namespace is created"                        'kind: Namespace' "$out"
assert_has   "apps namespace name"                              'name: apps' "$out"
assert_has   "monitoring namespace name"                        'name: monitoring' "$out"
assert_has   "bootstrap namespace name"                         'name: bootstrap' "$out"
assert_lacks "infra namespace is NOT templated (--create-namespace owns it)" \
                                                                '^  name: infra$' "$out"
assert_has   "vault Service keeps its name (apps hardcode vault.infra.svc)" '^  name: vault$' "$out"
assert_lacks "no release-name prefix leaked onto vault"         'name: microecom-vault' "$out"
assert_has   "grafana keeps its name"                           '^  name: grafana$' "$out"
assert_has   "vmsingle keeps its name (grafana datasource)"     'name: vmsingle' "$out"
assert_has   "kube-state-metrics keeps its scrape label"        'app\.kubernetes\.io/name: kube-state-metrics' "$out"
assert_lacks "alias did not leak into the KSM name label"       'kubeStateMetrics' "$out"

out="$(render --set infra.vault.enabled=false)"
assert_ok    "vault disabled renders"                           "$out"
assert_lacks "infra.vault.enabled=false gates the vault dependency" \
                                                                'app.kubernetes.io/name: vault' "$out"

out="$(render --set infra.grafana.enabled=false --set infra.victoriaMetrics.enabled=false --set infra.kubeStateMetrics.enabled=false)"
assert_ok    "monitoring charts disabled renders"               "$out"
# Assert on images, not names: VM's scrape config contains the literal strings
# `kube-state-metrics` (job_name and relabel regex), so a name-based assertion
# would fail whenever VM is enabled.
assert_lacks "grafana gated off"                                'image: .*grafana/grafana' "$out"
assert_lacks "kube-state-metrics gated off"                     'kube-state-metrics/kube-state-metrics' "$out"

out="$(render)"
assert_has   "grafana lands in the monitoring namespace"        'namespace: monitoring' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
