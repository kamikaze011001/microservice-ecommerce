#!/usr/bin/env bash
# Bring up the Phase 1 environment: terraform apply + wire kubectl.
# Idempotent — re-running reconciles to desired state.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../aws/main" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"

terraform -chdir="$DIR" init -input=false
terraform -chdir="$DIR" apply -auto-approve

aws eks update-kubeconfig \
  --name "$(terraform -chdir="$DIR" output -raw cluster_name)" \
  --region "$(terraform -chdir="$DIR" output -raw region)"

echo "✅ up. kubectl is pointed at the cluster."
echo "   Deploy the smoke target with: kubectl apply -f aws/manifests/hello-nginx.yaml"
