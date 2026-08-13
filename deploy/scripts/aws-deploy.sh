#!/usr/bin/env bash
# Resolves the three AWS deploy-time inputs an operator previously had to
# assemble by hand:
#
#   make k8s-apps-helm ENV=aws \
#     HELM_EXTRA='--set apps.irsa.s3RoleArn=$(terraform output -raw s3_irsa_role_arn)'
#
# (and separately supply the ECR registry + image tag, which envs/aws.yaml
# deliberately leaves empty) — and invokes the chart. Wired to
# `make deploy ENV=aws` via VERB_deploy_aws in the Makefile.
#
# A NEW helper under deploy/, deliberately NOT scripts/aws/up-all.sh (frozen
# by the Global Constraints). See
# .superpowers/sdd/2026-08-12-aws-cutover/task-4-brief.md's PRE-FLIGHT
# RESOLUTION and docs/superpowers/specs/2026-08-12-aws-cutover-design.md D3:
# up-all.sh keeps working untouched, rollback stays "don't call the new
# verb", and Phase 8 deletes the old path as one atomic step.
#
# Inputs, resolved in this order:
#
#   s3_irsa_role_arn, ecr_registry:
#     1. AWS_TF_OUTPUTS_JSON=<path> — read from a JSON file shaped like
#        `terraform output -json` (offline test double; see
#        deploy/charts/microecom/tests/fixtures/aws-tf-outputs.json).
#        NEVER point this at real state — read real values straight from
#        terraform (below). This exists so this script — and `make deploy
#        ENV=aws` through it — can be verified offline.
#     2. otherwise: `terraform -chdir=aws/main output -raw s3_irsa_role_arn`
#        and `terraform -chdir=aws/bootstrap output -raw ecr_registry` — the
#        same two stacks scripts/aws/up-all.sh (S3 IRSA role) and
#        scripts/aws/push-images.sh (ECR registry) already read today.
#
#   image tag:
#     TAG env var (same convention as scripts/aws/push-images.sh), else the
#     current commit's short SHA (envs/aws.yaml's own comment: "filled from
#     the build's git sha").
#
# `--set-string` for all three, never `--set`: a plain `--set` treats dots as
# path separators, so an ECR hostname like
# 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com silently becomes nested
# keys instead of a string — this produced wrong renders twice during this
# phase (design doc §5 Risks). `--set apps.enabled=true` is load-bearing: the
# apps subchart defaults to false, and omitting it renders 3 objects that
# look like a successful deploy.
#
# A missing input fails loud and names which one and where it comes from —
# see the `fail()` calls below and charts/apps/templates/_helpers.tpl's
# matching `required` guards on global.appImage.registry/.tag (a missing
# apps.irsa.s3RoleArn already failed this way; this script + the chart now
# make the registry/tag path just as legible instead of an opaque
# "YAML parse error … mapping values are not allowed in this context").
#
# Usage:
#   deploy/scripts/aws-deploy.sh
#       Real deploy. Delegates to `make k8s-apps-helm ENV=aws` (single
#       source of truth for the actual helm invocation) with the three
#       inputs wired into HELM_EXTRA. Applies to a live cluster with --wait
#       — COSTS MONEY. This is what `make deploy ENV=aws` runs.
#
#   deploy/scripts/aws-deploy.sh --render [-- <extra helm template args>]
#       Offline `helm template` only — never touches a cluster, never bills
#       anything. Used for verification/CI (see
#       deploy/charts/microecom/tests/aws-diff-test.sh, which this mirrors
#       rather than hand-composes flags against).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHART_DIR="$ROOT/deploy/charts/microecom"

fail() {  # fail <what-is-missing> <where-to-get-or-set-it>
  echo "ERROR: $1 -- $2" >&2
  exit 1
}

command -v helm >/dev/null || fail "helm not found" "install helm and retry"

# ── Resolve s3_irsa_role_arn + ecr_registry ─────────────────────────────────
if [ -n "${AWS_TF_OUTPUTS_JSON:-}" ]; then
  command -v jq >/dev/null || fail "jq not found" "install jq to read AWS_TF_OUTPUTS_JSON, or unset it and resolve via terraform directly"
  [ -f "$AWS_TF_OUTPUTS_JSON" ] || fail "AWS_TF_OUTPUTS_JSON='$AWS_TF_OUTPUTS_JSON' not found" "point it at a real file, e.g. deploy/charts/microecom/tests/fixtures/aws-tf-outputs.json"
  S3_ROLE_ARN="$(jq -r '.s3_irsa_role_arn // empty' "$AWS_TF_OUTPUTS_JSON")"
  ECR_REGISTRY="$(jq -r '.ecr_registry // empty' "$AWS_TF_OUTPUTS_JSON")"
else
  command -v terraform >/dev/null || fail "terraform not found" "install terraform, or set AWS_TF_OUTPUTS_JSON to a fixture for offline testing"
  S3_ROLE_ARN="$(terraform -chdir="$ROOT/aws/main" output -raw s3_irsa_role_arn 2>/dev/null || true)"
  ECR_REGISTRY="$(terraform -chdir="$ROOT/aws/bootstrap" output -raw ecr_registry 2>/dev/null || true)"
fi

[ -n "$S3_ROLE_ARN" ] || fail "s3_irsa_role_arn is empty" "run terraform apply in aws/main first (see scripts/aws/up-all.sh step 6), or set AWS_TF_OUTPUTS_JSON to a fixture for offline testing"
[ -n "$ECR_REGISTRY" ] || fail "ecr_registry is empty" "run terraform apply in aws/bootstrap first (see scripts/aws/push-images.sh), or set AWS_TF_OUTPUTS_JSON to a fixture for offline testing"

# ── Resolve image tag ────────────────────────────────────────────────────────
IMAGE_TAG="${TAG:-}"
if [ -z "$IMAGE_TAG" ]; then
  IMAGE_TAG="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)"
fi
[ -n "$IMAGE_TAG" ] || fail "image tag is empty" "set TAG=<tag> (same convention as scripts/aws/push-images.sh), or run this from inside the git repo so a commit sha can be derived"

# The load-bearing --set-string flags. Copied in shape from the reference
# invocation in aws-diff-test.sh rather than composed by hand a fourth time.
HELM_SET_STRING_FLAGS=(
  --set-string "apps.irsa.s3RoleArn=${S3_ROLE_ARN}"
  --set-string "global.appImage.registry=${ECR_REGISTRY}"
  --set-string "global.appImage.tag=${IMAGE_TAG}"
)

MODE="install"
if [ "${1:-}" = "--render" ]; then
  MODE="render"
  shift
  [ "${1:-}" = "--" ] && shift
fi

if [ "$MODE" = "render" ]; then
  echo "==> offline render (helm template) — registry=${ECR_REGISTRY} tag=${IMAGE_TAG}" >&2
  exec helm template microecom "$CHART_DIR" --namespace infra \
    -f "$CHART_DIR/envs/aws.yaml" \
    --set apps.enabled=true \
    "${HELM_SET_STRING_FLAGS[@]}" \
    "$@"
fi

echo "==> deploying AWS apps (registry=${ECR_REGISTRY} tag=${IMAGE_TAG}) via 'make k8s-apps-helm ENV=aws' — this applies to a live cluster with --wait and COSTS MONEY" >&2
exec make --no-print-directory -C "$ROOT" k8s-apps-helm ENV=aws \
  HELM_EXTRA="${HELM_SET_STRING_FLAGS[*]}"
