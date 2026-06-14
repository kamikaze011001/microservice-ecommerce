#!/usr/bin/env bash
# List resources that commonly survive a botched teardown and keep billing.
# Anything listed here (except the persistent Phase 0 state bucket + lock table,
# which live in a different stack and cost << $1/mo) is still costing money.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-microecom}"
R="${AWS_REGION:-ap-southeast-1}"

echo "── Load balancers (ALB/NLB) ──"
aws elbv2 describe-load-balancers --region "$R" \
  --query 'LoadBalancers[].LoadBalancerName' --output table 2>/dev/null || echo "(none)"

echo "── NAT gateways (available) ──"
aws ec2 describe-nat-gateways --region "$R" \
  --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayId' --output table

echo "── Elastic IPs (allocated) ──"
aws ec2 describe-addresses --region "$R" \
  --query 'Addresses[].PublicIp' --output table

echo "── Unattached EBS volumes ──"
aws ec2 describe-volumes --region "$R" \
  --filters Name=status,Values=available \
  --query 'Volumes[].VolumeId' --output table

echo "── EKS clusters ──"
aws eks list-clusters --region "$R" --output table

echo ""
echo "Empty tables above = clean teardown. The Phase 0 state bucket + lock table"
echo "are expected survivors (different stack, ~\$0/mo)."
