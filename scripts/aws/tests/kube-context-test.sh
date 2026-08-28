#!/usr/bin/env bash
# Decision table for scripts/aws/lib/kube-context.sh.
#
# This guard protects the TEARDOWN path. Its failure mode is silent and
# expensive: pointed at the wrong cluster, every kubectl delete succeeds as a
# no-op, terraform destroy proceeds, and the real ALB keeps billing with nothing
# in terraform state to show it. So the three outcomes are asserted as DISTINCT
# exit codes — "absent context" and "unreachable cluster" need different operator
# responses and must never collapse into one.
#
# Driven entirely by a kubectl shim on PATH. Never contacts a cluster.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
source "$ROOT/scripts/aws/lib/kube-context.sh"

# Intercept kubectl.
PATH="$HERE/shims:$PATH"
export PATH

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# Guard against a vacuous suite: if the shim is not executable, every row below
# would exercise the real kubectl (or nothing at all).
[ -x "$HERE/shims/kubectl" ] \
  && ok "kubectl shim is present and executable" \
  || bad "kubectl shim missing — every row below is meaningless"

# 1. context exists and cluster answers -> 0
SHIM_CONTEXTS=$'minikube\nmicroecom-eks' SHIM_READYZ_OK=1 \
  require_kube_context microecom-eks
[ $? -eq 0 ] \
  && ok "present context + reachable cluster -> 0" \
  || bad "present context + reachable cluster must return 0"

# 2. context absent (e.g. kubeconfig only has minikube) -> 1
SHIM_CONTEXTS=$'minikube\ndocker-desktop' SHIM_READYZ_OK=1 \
  require_kube_context microecom-eks
[ $? -eq 1 ] \
  && ok "absent context -> 1" \
  || bad "absent context must return 1, not 0 or 2"

# 3. context present but cluster unreachable (torn down, VPN off) -> 2
SHIM_CONTEXTS=$'microecom-eks' SHIM_READYZ_OK=0 \
  require_kube_context microecom-eks
[ $? -eq 2 ] \
  && ok "unreachable cluster -> 2" \
  || bad "unreachable cluster must return 2, distinct from absent-context 1"

# 4. empty kubeconfig -> 1
SHIM_CONTEXTS='' SHIM_READYZ_OK=1 \
  require_kube_context microecom-eks
[ $? -eq 1 ] \
  && ok "empty kubeconfig -> 1" \
  || bad "empty kubeconfig must return 1"

# 5. substring trap: a context whose name CONTAINS the target must not match.
SHIM_CONTEXTS=$'not-microecom-eks-either' SHIM_READYZ_OK=1 \
  require_kube_context microecom-eks
[ $? -eq 1 ] \
  && ok "substring match does not count as the context" \
  || bad "matching must be exact, not substring"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
