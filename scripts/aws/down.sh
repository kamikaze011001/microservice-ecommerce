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

# 1. Delete the smoke app (Ingress triggers ALB teardown). Ignore if already gone.
kubectl delete -f "$ROOT/aws/manifests/hello-nginx.yaml" --ignore-not-found=true || true

# 2. Wait for the controller to deprovision the ALB (orphaned ENIs block VPC destroy).
echo "Waiting 60s for the ALB controller to deprovision the load balancer..."
sleep 60

# 3. Now Terraform can destroy the VPC/EKS cleanly.
terraform -chdir="$DIR" destroy -auto-approve

echo "✅ destroyed. Run 'make aws-leak-check' to confirm nothing is still billing."
