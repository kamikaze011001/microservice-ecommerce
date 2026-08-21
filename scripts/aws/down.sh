#!/usr/bin/env bash
# Tear down WITHOUT leaking. The ALB + target groups are created by the
# in-cluster Load Balancer Controller, so Terraform doesn't know about them.
# Delete the Kubernetes Ingress FIRST so the controller removes the ALB, wait
# for it to actually disappear, THEN terraform destroy — otherwise VPC deletion
# hangs on orphaned ENIs left behind by the ALB.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../aws/main" && pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"

EKS_CONTEXT="${EKS_CONTEXT:-microecom-eks}"

# shellcheck source=lib/kube-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/kube-context.sh"

# Refuse to proceed unless we can prove which cluster the deletes below will hit.
# A no-op delete against the wrong cluster looks identical to a successful one,
# and the ALB it fails to remove keeps billing after terraform destroy returns.
# `|| rc=$?` is load-bearing: down.sh runs under `set -euo pipefail`, and a BARE
# call returning non-zero would abort the script before `case` ever runs — the
# destroy would still be prevented, but the operator would see a silent exit
# instead of the diagnostics below. Failure must stay handled, not fatal, here.
rc=0
require_kube_context "$EKS_CONTEXT" || rc=$?
case $rc in
  0) echo "▶ teardown target confirmed: context '$EKS_CONTEXT'" ;;
  1) echo "ERROR: kube context '$EKS_CONTEXT' is not in your kubeconfig." >&2
     echo "  The EKS cluster may already be gone. If so, terraform destroy is" >&2
     echo "  still safe to run directly, but check 'make aws-leak-check' after:" >&2
     echo "  an ALB created by the in-cluster controller is NOT in terraform state." >&2
     # --name is the CLUSTER name (var.cluster_name, aws/main/variables.tf:16),
     # not the context alias. They differ in general and happen to coincide
     # here. up.sh:13 resolves it with `terraform output -raw cluster_name`
     # rather than hardcoding; infra-up.sh:28 and aws-deploy.sh:189 print the
     # same literal as below. An operator reaching this branch is already in a
     # failure state — a remedy that names a nonexistent cluster sends them to
     # a second, unrelated one.
     echo "  To restore the context:  aws eks update-kubeconfig --name microecom-eks \\" >&2
     echo "                             --region ap-southeast-1 --alias microecom-eks" >&2
     exit 1 ;;
  2) echo "ERROR: context '$EKS_CONTEXT' exists but the cluster is not answering." >&2
     echo "  Refusing to destroy: the Ingress deletes below would be silent no-ops" >&2
     echo "  and the ALB would be stranded. Check the cluster, then re-run." >&2
     # Terraform destroys node group -> EKS cluster -> VPC/subnets, in that
     # order. If an earlier destroy hung on orphaned ENIs at subnet/VPC
     # deletion, the cluster is ALREADY GONE by the time that happened — only
     # a stale kubeconfig entry remains, which is exactly this rc=2 state.
     # If that's what you're looking at, the Ingresses (and their ALB) went
     # with the cluster already, so the kubectl deletes below are moot. Skip
     # this script and finish the VPC teardown directly:
     echo "  If the cluster is already destroyed and this is just a stale" >&2
     echo "  kubeconfig entry, the Ingresses went with it — run the VPC" >&2
     echo "  teardown directly instead of retrying this script:" >&2
     echo "    terraform -chdir=$ROOT/aws/main destroy -auto-approve" >&2
     echo "    make aws-leak-check" >&2
     exit 1 ;;
esac

# 1. Delete every Ingress that owns an ALB so the Load Balancer Controller tears
#    it down. BOTH the Phase 2 smoke app AND the Phase 3 apps-overlay gateway ALB
#    must go — each leaves orphaned ENIs that block VPC destroy. Ignore if absent
#    (a Phase-2-only teardown won't have gateway-alb).
# --ignore-not-found handles "the resource is absent", which is fine. It does NOT
# handle "the cluster is unreachable" — that must abort, so no `|| true` here.
# The context is passed explicitly and never inherited: require_kube_context above
# has already proven this exact context resolves and answers.
kubectl --context "$EKS_CONTEXT" delete -f "$ROOT/aws/manifests/hello-nginx.yaml" \
  --ignore-not-found=true
kubectl --context "$EKS_CONTEXT" delete ingress gateway-alb -n apps \
  --ignore-not-found=true

# 2. Wait for the controller to deprovision the ALB(s) (orphaned ENIs block VPC destroy).
echo "Waiting 60s for the ALB controller to deprovision the load balancer(s)..."
sleep 60

# 3. Now Terraform can destroy the VPC/EKS cleanly.
terraform -chdir="$DIR" destroy -auto-approve

# ── App secrets leak check ───────────────────────────────────────────────────
# ExternalSecrets own their target k8s Secrets (creationPolicy: Owner) and vanish
# with the cluster. The Secrets Manager secrets are Terraform-managed
# (recovery_window_in_days=0) and destroyed above — they do NOT leak. Confirm
# nothing lingers in a soft-delete state:
echo "▶ post-destroy Secrets Manager leak check:"
aws secretsmanager list-secrets --region ap-southeast-1 \
  --include-planned-deletion \
  --query "SecretList[?starts_with(Name, 'app/')].{name:Name,deletes:DeletedDate}" \
  --output table || true

echo "✅ destroyed. Run 'make aws-leak-check' to confirm nothing is still billing."
