#!/usr/bin/env bash
# One-time: create the persistent Terraform state backend + budget alarm.
# Idempotent — safe to re-run; terraform reconciles to desired state.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../aws/bootstrap" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"

if [[ ! -f "$DIR/terraform.tfvars" ]]; then
  echo "ERROR: $DIR/terraform.tfvars missing." >&2
  echo "  cp aws/bootstrap/terraform.tfvars.example aws/bootstrap/terraform.tfvars" >&2
  echo "  then set budget_email." >&2
  exit 1
fi

# Full init (providers + local backend). -reconfigure clears any prior
# validate-time `-backend=false` state so apply can write state.
terraform -chdir="$DIR" init -reconfigure
terraform -chdir="$DIR" apply
