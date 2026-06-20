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

# 1. Delete every Ingress that owns an ALB so the Load Balancer Controller tears
#    it down. BOTH the Phase 2 smoke app AND the Phase 3 apps-overlay gateway ALB
#    must go — each leaves orphaned ENIs that block VPC destroy. Ignore if absent
#    (a Phase-2-only teardown won't have gateway-alb).
kubectl delete -f "$ROOT/aws/manifests/hello-nginx.yaml" --ignore-not-found=true || true
kubectl delete ingress gateway-alb -n apps --ignore-not-found=true || true

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
