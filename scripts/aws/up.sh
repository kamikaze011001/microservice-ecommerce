#!/usr/bin/env bash
# Bring up the Phase 1 environment: terraform apply + wire kubectl.
# Idempotent — re-running reconciles to desired state.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../aws/main" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"

# The domain aws/main/dns.tf:28 looks up as a data source. Kept in sync by hand;
# there is no cheaper way to learn it before terraform has run.
APEX_DOMAIN="${APEX_DOMAIN:-microecom.click}"

# ── Pre-check: is the apex domain published to the public internet? ───────────
# `aws_acm_certificate_validation.shop` blocks until ACM resolves a CNAME the
# way a stranger would: from the root, down whatever nameservers the REGISTRY
# says are authoritative. A Route 53 hosted zone holding the record is NOT
# enough — if the domain is not delegated at the TLD, ACM sees nothing and the
# resource sits for its full 1h15m timeout.
#
# That resource is downstream of everything expensive, so the failure mode is:
# build ~143 resources, then bill for 75 minutes in a waiting room, then fail
# on a fact that was knowable in one second before the first resource existed.
# This happened on 2026-08-21 — the domain carried a registrar `clientHold`
# (ICANN registrant-email verification never completed), so it resolved nowhere.
#
# Checked here rather than documented in a runbook because a check the operator
# performs is advisory and a check the script performs is a guard.
if [ -z "${SKIP_DNS_PRECHECK:-}" ]; then
  if command -v dig >/dev/null 2>&1; then
    if ! dig @8.8.8.8 +short +time=5 +tries=2 NS "$APEX_DOMAIN" 2>/dev/null | grep -q .; then
      echo "✋ '$APEX_DOMAIN' does not resolve NS records on the public internet." >&2
      echo "   ACM DNS validation cannot complete, so 'terraform apply' would build" >&2
      echo "   the whole stack and then block ~1h15m before failing. Refusing to start." >&2
      echo "" >&2
      echo "   Check the registration status:" >&2
      echo "     aws route53domains get-domain-detail --region us-east-1 \\" >&2
      echo "       --domain-name $APEX_DOMAIN --query StatusList" >&2
      echo "   'clientHold' means the registry has withheld the domain — usually an" >&2
      echo "   unconfirmed ICANN registrant email. Resend it with:" >&2
      echo "     aws route53domains resend-contact-reachability-email \\" >&2
      echo "       --region us-east-1 --domain-name $APEX_DOMAIN" >&2
      echo "" >&2
      echo "   Re-run once 'dig @8.8.8.8 +short NS $APEX_DOMAIN' returns nameservers." >&2
      echo "   To proceed anyway (infra-only, expect the ACM step to fail):" >&2
      echo "     SKIP_DNS_PRECHECK=1 $0" >&2
      exit 1
    fi
    echo "✓ $APEX_DOMAIN delegates publicly — ACM validation can complete"
  else
    echo "note: dig not found; skipping the DNS pre-check" >&2
  fi
fi

terraform -chdir="$DIR" init -input=false

# `|| rc=$?` rather than a bare call: under `set -e` a failed apply would exit
# here, and the kubeconfig wiring below would never run. See
# .claude/memory/conventions/errexit-consumes-a-functions-exit-code.md.
rc=0
terraform -chdir="$DIR" apply -auto-approve || rc=$?

# ── Wire kubectl even when apply FAILED ──────────────────────────────────────
# This used to run only on success, so a partial apply — cluster created, then
# a later resource failed — left the operator owning a running, billing cluster
# they could not talk to, holding whatever stale context a previous attempt had
# written. `make aws-down`'s guard then correctly refused to tear it down,
# because it could not prove which cluster it would hit.
#
# Best-effort by design: if the outputs do not resolve, the cluster genuinely
# is not there and that is not a failure worth masking. The apply's own exit
# status is preserved and re-raised at the end either way.
if CLUSTER_NAME="$(terraform -chdir="$DIR" output -raw cluster_name 2>/dev/null)" \
   && CLUSTER_REGION="$(terraform -chdir="$DIR" output -raw region 2>/dev/null)" \
   && [ -n "$CLUSTER_NAME" ] && [ -n "$CLUSTER_REGION" ]; then
  aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$CLUSTER_REGION" \
    --alias microecom-eks
else
  echo "note: cluster_name/region outputs unavailable — kubeconfig not updated" >&2
fi

if [ "$rc" -ne 0 ]; then
  echo "✋ terraform apply failed (exit $rc)." >&2
  echo "   kubectl has been pointed at whatever cluster DOES exist, so you can" >&2
  echo "   inspect it and 'make aws-down' can tear it down cleanly." >&2
  echo "   Anything already created is BILLING — tear down if you are not" >&2
  echo "   continuing: make aws-down && make aws-leak-check" >&2
  exit "$rc"
fi

echo "✅ up. kubectl is pointed at the cluster."
echo "   Deploy the smoke target with: kubectl apply -f aws/manifests/hello-nginx.yaml"
