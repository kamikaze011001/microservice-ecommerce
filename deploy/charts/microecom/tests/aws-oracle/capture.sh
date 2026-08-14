#!/usr/bin/env bash
# Captures the AWS "oracle" — what the OLD (kustomize) apps deploy path actually
# produces today — so the Helm chart's aws-with-apps render can be diffed against
# ground truth instead of a hand-written guess (see D1,
# docs/superpowers/specs/2026-08-12-aws-cutover-design.md).
#
# THE ORACLE IS COMPOSED FROM TWO SOURCES. Both are required:
#
#   kubectl kustomize k8s/apps/overlays/aws                 (pure local build,
#     → resources listed in the overlay's kustomization.yaml   no cluster contact)
#   + k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml     (NOT in kustomization.yaml —
#     with PLACEHOLDER_S3_ROLE_ARN substituted                applied out-of-band)
#
# The second half is not a chart invention to diff away. scripts/aws/up-all.sh
# (lines ~127-137) reads `terraform output -raw s3_irsa_role_arn` and does:
#
#   sed "s|PLACEHOLDER_S3_ROLE_ARN|${S3_ROLE_ARN}|g" \
#     "$ROOT/k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml" | kubectl apply -f -
#
# This script reproduces that exact sed substitution — offline, using a fixture
# JSON in place of a real `terraform output` call. NOTHING here touches a live
# cluster or costs money: `kubectl kustomize` is a pure local build (no context
# needed) and the IRSA half is templated with a fixture value, never applied.
#
# Usage: bash deploy/charts/microecom/tests/aws-oracle/capture.sh
#
# ── FROZEN — Phase 8 Task 4 (docs/superpowers/specs/2026-08-14-cleanup-cutover-
# design.md D3). Task 5 of this same phase deletes this script's source:
# k8s/apps/overlays/aws (part of k8s/, which is deleted whole). THE SOURCE IS
# GOING AWAY AND oracle.yaml MUST NEVER BE REGENERATED AGAINST IT AGAIN. It is
# the last known-good capture of the OLD kustomize aws overlay's output and is
# committed evidence, not a cache — deploy/charts/microecom/tests/aws-diff-
# test.sh diffs the chart's aws-with-apps render against exactly these bytes.
# Regenerating destroys the only thing that suite has left to check against
# once the source is gone.
#
# This is the fourth instance in this project of an oracle that can be
# silently invalidated by regeneration (see deploy/scripts/tests/
# capture-baseline.sh's header for the other three and the incident that
# motivated this treatment). Refuses to run unless FORCE=1 is set:
#   FORCE=1 bash deploy/charts/microecom/tests/aws-oracle/capture.sh   (regenerate on purpose)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
OVERLAY="$ROOT/k8s/apps/overlays/aws"
FIXTURE="$SCRIPT_DIR/../fixtures/aws-tf-outputs.json"
OUT="$SCRIPT_DIR/oracle.yaml"

if [ -s "$OUT" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "REFUSED: $OUT already exists -- committed evidence, not a cache. The source (k8s/apps/overlays/aws) is scheduled for deletion; do not regenerate. Set FORCE=1 to override on purpose." >&2
  exit 1
fi

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v jq      >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }
[[ -f "$FIXTURE" ]] || { echo "ERROR: fixture not found: $FIXTURE" >&2; exit 1; }

# ── Half 1: kustomize build. Pure local render — no cluster, no context needed. ──
echo "▶ half 1/2: kubectl kustomize $OVERLAY (local build, no cluster contact)"
kustomize_out="$(kubectl kustomize "$OVERLAY")"

# ── Half 2: the IRSA ServiceAccounts, stamped exactly as up-all.sh:127-137 does. ─
# Real path: S3_ROLE_ARN="$(terraform -chdir="$TF" output -raw s3_irsa_role_arn)"
# Offline stand-in: same value, read from the fixture instead of live state.
echo "▶ half 2/2: s3-irsa-serviceaccounts.yaml, PLACEHOLDER_S3_ROLE_ARN substituted (fixture, no terraform call)"
S3_ROLE_ARN="$(jq -r '.s3_irsa_role_arn' "$FIXTURE")"
[[ -n "$S3_ROLE_ARN" && "$S3_ROLE_ARN" != "null" ]] || { echo "ERROR: fixture missing s3_irsa_role_arn" >&2; exit 1; }

# Exact substitution mechanism reproduced from scripts/aws/up-all.sh:136-137 —
# a plain `sed s|...|...|g`, not envsubst, not a template engine.
irsa_out="$(sed "s|PLACEHOLDER_S3_ROLE_ARN|${S3_ROLE_ARN}|g" "$OVERLAY/s3-irsa-serviceaccounts.yaml")"

echo
echo "== Assertion 1: PLACEHOLDER_S3_ROLE_ARN was actually substituted =="
if grep -q 'PLACEHOLDER_S3_ROLE_ARN' <<<"$irsa_out"; then
  bad "PLACEHOLDER_S3_ROLE_ARN is still present in the templated output -- the sed substitution is a no-op"
elif ! grep -qF -- "$S3_ROLE_ARN" <<<"$irsa_out"; then
  bad "substituted output does not contain the fixture's ARN ('$S3_ROLE_ARN') -- substitution produced the wrong value"
else
  ok "placeholder absent, fixture ARN ('$S3_ROLE_ARN') present in the templated ServiceAccounts"
fi

# ── Compose: concatenate both halves into one multi-doc YAML oracle. ────────────
# Written to a TEMP file first, NOT $OUT directly: $OUT is committed evidence
# (see deploy/scripts/tests/capture-baseline.sh's header -- this is the fourth
# silently-invalidatable oracle in this project). Promoting straight to $OUT
# before assertions run means a broken capture overwrites the last-known-good
# oracle unconditionally. TMP_OUT is only moved into place at the very end,
# after every assertion below has passed.
TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/aws-oracle-capture.XXXXXX.yaml")"
trap 'rm -f "$TMP_OUT"' EXIT
{
  printf '%s\n' "$kustomize_out"
  printf -- '---\n'
  printf '%s\n' "$irsa_out"
} > "$TMP_OUT"
echo "▶ composed to a temp file -- $OUT is left untouched until all assertions pass"

# ── Assertions, via python3+pyyaml (yq is not installed in this environment). ───
report="$(python3 - "$TMP_OUT" "$OVERLAY/kustomization.yaml" <<'PYEOF'
import sys, yaml, json
from collections import Counter

oracle_path, kustomization_path = sys.argv[1], sys.argv[2]

with open(oracle_path) as f:
    docs = [d for d in yaml.safe_load_all(f) if d]

# Split back into the two halves by provenance: the IRSA half is the two
# ServiceAccounts named product-service/authorization-server carrying the
# role-arn annotation; everything else came from kustomize build.
def is_irsa_sa(d):
    return (
        d.get("kind") == "ServiceAccount"
        and d.get("metadata", {}).get("annotations", {}).get("eks.amazonaws.com/role-arn")
    )

irsa_half = [d for d in docs if is_irsa_sa(d)]
kustomize_half = [d for d in docs if d not in irsa_half]

kinds = Counter(d.get("kind") for d in kustomize_half)
deployments = sorted(d["metadata"]["name"] for d in kustomize_half if d.get("kind") == "Deployment")
external_secrets = sorted(d["metadata"]["name"] for d in kustomize_half if d.get("kind") == "ExternalSecret")

result = {
    "total_objects": len(docs),
    "kustomize_half_count": len(kustomize_half),
    "irsa_half_count": len(irsa_half),
    "irsa_sa_names": sorted(d["metadata"]["name"] for d in irsa_half),
    "kinds": dict(kinds),
    "deployments": deployments,
    "external_secrets": external_secrets,
    "deployments_without_external_secret": sorted(set(deployments) - set(external_secrets)),
}
print(json.dumps(result))
PYEOF
)"

get() { echo "$report" | jq -r "$1"; }

total="$(get .total_objects)"
kustomize_count="$(get .kustomize_half_count)"
irsa_count="$(get .irsa_half_count)"
n_deploy="$(get '.kinds.Deployment // 0')"
n_svc="$(get '.kinds.Service // 0')"
n_es="$(get '.kinds.ExternalSecret // 0')"
n_hpa="$(get '.kinds.HorizontalPodAutoscaler // 0')"
n_sa="$(get '.kinds.ServiceAccount // 0')"
n_role="$(get '.kinds.Role // 0')"
n_rb="$(get '.kinds.RoleBinding // 0')"
n_ns="$(get '.kinds.Namespace // 0')"
n_ing="$(get '.kinds.Ingress // 0')"
missing_es="$(get '.deployments_without_external_secret | join(",")')"

echo
echo "== Assertion 2: both halves contributed (separately) =="

if [[ "$kustomize_count" -gt 0 && "$n_deploy" == "10" && "$n_svc" == "10" && "$n_es" == "9" \
      && "$n_hpa" == "5" && "$n_sa" == "1" && "$n_role" == "1" && "$n_rb" == "1" && "$n_ns" == "1" ]]; then
  ok "kustomize half produced 10 Deployment/10 Service/9 ExternalSecret/5 HPA/1 SA/1 Role/1 RoleBinding/1 Namespace (got: $kustomize_count objects)"
else
  bad "kustomize half object counts did not match expectation (Deployment=$n_deploy Service=$n_svc ExternalSecret=$n_es HPA=$n_hpa SA=$n_sa Role=$n_role RoleBinding=$n_rb Namespace=$n_ns)"
fi

if [[ "$n_ing" != "1" ]]; then
  echo "  NOTE: kustomize half also produced $n_ing Ingress object(s) (ingress-gateway.yaml)." \
       "This is real ALB ingress output but is NOT mentioned in the design doc's or the task" \
       "brief's per-kind tally — see report for the finding."
else
  echo "  NOTE: kustomize half also produced 1 Ingress object (ingress-gateway.yaml)." \
       "This is real ALB ingress output but is NOT mentioned in the design doc's or the task" \
       "brief's per-kind tally (which sums to 38, and the brief's own headline number is 37" \
       "— neither matches the measured 39-object total). Reported as a finding, not papered over."
fi

if [[ "$irsa_count" -ge 1 ]]; then
  ok "IRSA half produced $irsa_count role-arn-annotated ServiceAccount(s): $(get '.irsa_sa_names | join(",")')"
else
  bad "IRSA half contributed NOTHING — the capture is broken (this is the entire reason this task exists)"
fi

echo
echo "== Assertion 3: the 9-vs-10 asymmetry is exactly 'frontend' =="
if [[ "$missing_es" == "frontend" ]]; then
  ok "exactly one Deployment lacks an ExternalSecret, and it is 'frontend'"
else
  bad "expected the sole Deployment-without-ExternalSecret to be 'frontend', got: [$missing_es]"
fi

echo
echo "== Summary =="
echo "  total objects in temp capture: $total  (kustomize half: $kustomize_count, IRSA half: $irsa_count)"
echo "  $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
  echo "▶ assertions FAILED -- leaving $OUT untouched (oracle.yaml is committed evidence, not a cache)" >&2
  exit 1
fi

mv "$TMP_OUT" "$OUT"
echo "▶ wrote $OUT"
