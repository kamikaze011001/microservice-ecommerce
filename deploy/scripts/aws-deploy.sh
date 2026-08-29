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
#     TAG env var, else "dev" — the SAME convention scripts/aws/push-images.sh
#     and deploy/images/build.sh already default to, and what
#     k8s/apps/overlays/aws/*/kustomization.yaml pins via `newTag: dev`. This
#     used to default to `git rev-parse --short HEAD` instead, which is WRONG:
#     nothing in this repo ever pushes a sha-tagged image (`rev-parse --short`
#     appeared exactly once in the repo — here), so the first real
#     `make deploy ENV=aws` after `make aws-push` would give every pod
#     ImagePullBackOff and then hang for the full 30m `--wait --timeout 30m`
#     on a billed cluster. envs/aws.yaml's own comment ("filled from the
#     build's git sha") is aspirational — nothing in this repo tags images by
#     sha today — and is corrected alongside this.
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
#       — COSTS MONEY. This is what `make deploy ENV=aws` runs. Refuses
#       unless the current kubectl context is exactly `microecom-eks` (the
#       same guard scripts/aws/up-all.sh and scripts/aws/infra-up.sh apply
#       before their own kubectl calls — reproduced here, not copied, since
#       scripts/ is frozen).
#
#   deploy/scripts/aws-deploy.sh --render [-- <extra helm template args>]
#       Offline `helm template` only — never touches a cluster, never bills
#       anything, no context guard needed. Mirrors
#       deploy/charts/microecom/tests/aws-diff-test.sh's render invocation
#       (including `--set infra.enabled=false`) rather than hand-composing
#       flags a second time.
#
#   deploy/scripts/aws-deploy.sh --help | -h
#       Print this usage and exit 0. Does NOT deploy. Any OTHER argument is
#       rejected with a usage message and a non-zero exit rather than falling
#       through to a real deploy — a script whose `--help` (or a typo like
#       `-render`) silently deploys to production is a trap.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHART_DIR="$ROOT/deploy/charts/microecom"

fail() {  # fail <what-is-missing> <where-to-get-or-set-it>
  echo "ERROR: $1 -- $2" >&2
  exit 1
}

usage() {
  cat <<'EOF' >&2
Usage: aws-deploy.sh [--render [-- <extra helm template args>]]
       aws-deploy.sh --help | -h

  (no args)    Real deploy to the live AWS EKS cluster via
               `make k8s-apps-helm ENV=aws`. Applies with --wait
               --timeout 30m. COSTS MONEY. Refuses unless the current
               kubectl context is exactly 'microecom-eks'.

  --render     Offline `helm template` only. Never touches a cluster,
               never bills anything.

  --help, -h   Print this message and exit 0. Does NOT deploy.

Any other argument is rejected (exit 1) rather than falling through to a
real deploy.
EOF
}

# ── Argument handling FIRST, before any dependency/input resolution, so
# --help and rejected arguments never risk running any of the resolution
# below. Only "--render" (optionally with trailing "-- <helm args>") and
# nothing else reaches the real-deploy path; --help/-h prints usage and
# exits 0; anything else is a hard reject.
MODE="install"
case "${1:-}" in
  --render)
    MODE="render"
    shift
    [ "${1:-}" = "--" ] && shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "ERROR: unrecognized argument: ${1}" >&2
    usage
    exit 1
    ;;
esac

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
# Default "dev", NOT a git sha: matches scripts/aws/push-images.sh, deploy/images/build.sh,
# and k8s/apps/overlays/aws/*/kustomization.yaml's `newTag: dev`. A sha default here would
# name a tag that has never once been pushed to ECR by anything in this repo (see header).
IMAGE_TAG="${TAG:-dev}"

# The load-bearing flags. Copied in shape from the reference invocation in
# aws-diff-test.sh rather than composed by hand a fourth time.
#
# `--set infra.enabled=false` MUST live in this shared array, not inline in the
# render branch. It used to be inline, so the two paths diverged: `--mode
# render` (what `make aws-diff-test` exercises) disabled the infra subchart,
# while the real apply -- which execs `make k8s-apps-helm`, and that recipe
# passes only $(HELM_EXTRA) -- did not. On AWS, infra is installed as SEPARATE
# helm releases by scripts/aws/infra-up.sh (see .claude/memory/decisions/
# 0005-aws-infra-stays-outside-the-umbrella-chart.md), so leaving the subchart
# enabled made the umbrella try to create objects another release already owns:
#
#   Error: ServiceAccount "grafana" in namespace "monitoring" exists and cannot
#   be imported into the current release: ... "meta.helm.sh/release-name" must
#   equal "microecom": current value is "grafana"
#
# The offline oracle could never catch this: it rendered a DIFFERENT command
# than the one that runs.
#
# `--set`, never `--set-string`. --set-string would make this the STRING
# "false", and Helm's processDependencyEnabled type-asserts a condition value
# to bool: on a non-bool it logs `Warning: Condition path ... returned non-bool
# value` and leaves Enabled at its pre-initialized `true`. So the subchart
# renders anyway -- the flag looks present while doing nothing.
HELM_FLAGS=(
  --set infra.enabled=false
  --set-string "apps.irsa.s3RoleArn=${S3_ROLE_ARN}"
  --set-string "global.appImage.registry=${ECR_REGISTRY}"
  --set-string "global.appImage.tag=${IMAGE_TAG}"
)

if [ "$MODE" = "render" ]; then
  echo "==> offline render (helm template) — registry=${ECR_REGISTRY} tag=${IMAGE_TAG}" >&2
  exec helm template microecom "$CHART_DIR" --namespace infra \
    -f "$CHART_DIR/envs/aws.yaml" \
    --set apps.enabled=true \
    "${HELM_FLAGS[@]}" \
    "$@"
fi

# ── Context guard (real-deploy path only) — reproduced from
# scripts/aws/up-all.sh:115-119 and scripts/aws/infra-up.sh:23-27 (frozen,
# not edited). An earlier phase ran a seeder against an unrelated live
# cluster because nothing pinned the context; both scripts this one
# replaces guard it, so this one must too.
command -v kubectl >/dev/null || fail "kubectl not found" "install kubectl and retry"
CTX="$(kubectl config current-context 2>/dev/null || true)"
if [ "$CTX" != "microecom-eks" ]; then
  echo "✋ kubectl context is '${CTX:-<none>}', not 'microecom-eks'. Aborting before apply." >&2
  echo "   Run: aws eks update-kubeconfig --name microecom-eks --region ap-southeast-1 --alias microecom-eks" >&2
  exit 1
fi

echo "==> deploying AWS apps (registry=${ECR_REGISTRY} tag=${IMAGE_TAG}) via 'make k8s-apps-helm ENV=aws' — this applies to a live cluster with --wait and COSTS MONEY" >&2
exec make --no-print-directory -C "$ROOT" k8s-apps-helm ENV=aws \
  HELM_EXTRA="${HELM_FLAGS[*]}"
