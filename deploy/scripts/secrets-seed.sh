#!/usr/bin/env bash
# Resolve deploy/secrets/ and push it to this env's backend.
#
#   deploy/scripts/secrets-seed.sh --env compose|k8s|aws [--dry-run]
#                                  [--service NAME] [--refresh-tf]
#
# ALWAYS OVERWRITES. The canonical file is authoritative: a value edited there
# reaches the backend on the next run, and a value hand-edited in the backend
# does not survive one. That is the point of the phase — see
# docs/superpowers/specs/2026-08-06-canonical-secrets-design.md, decision 2.
#
# Resolution happens FIRST, in full. Nothing is pushed until every reference in
# every service resolves, because a partially-seeded backend is worse than an
# unseeded one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/deploy/scripts/lib/colors.sh"

ENV_NAME=""; DRY_RUN=0; SERVICE=""; REFRESH_TF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env)        ENV_NAME="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --service)    SERVICE="$2"; shift 2 ;;
    --refresh-tf) REFRESH_TF=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$ENV_NAME" in
  compose|k8s|aws) ;;
  *) echo "usage: secrets-seed.sh --env compose|k8s|aws [--dry-run] [--service NAME] [--refresh-tf]" >&2; exit 2 ;;
esac

TF_CACHE="$ROOT/deploy/.run/terraform-outputs.json"
TF_ARGS=()
if [ "$ENV_NAME" = "aws" ]; then
  mkdir -p "$ROOT/deploy/.run"
  if [ "$REFRESH_TF" -eq 1 ] || [ ! -f "$TF_CACHE" ]; then
    log_info "generating $TF_CACHE from terraform"
    terraform -chdir="$ROOT/aws/main" output -json > "$TF_CACHE" \
      || { log_err "terraform output failed — run 'terraform apply' first"; exit 1; }
  elif [ -n "$(find "$TF_CACHE" -mmin +1440 2>/dev/null)" ]; then
    # Warn, never auto-refresh: aws/main keeps state in an S3 remote backend
    # (aws/main/versions.tf:22), so there is no local file to compare against,
    # and an implicit terraform call mid-seed is the coupling this design removes.
    log_warn "$TF_CACHE is over 24h old — pass --refresh-tf if terraform has changed"
  fi
  TF_ARGS=(--tf-outputs "$TF_CACHE")
fi

RESOLVED="$(mktemp)"; trap 'rm -f "$RESOLVED"' EXIT
SVC_ARGS=(); [ -n "$SERVICE" ] && SVC_ARGS=(--service "$SERVICE")

python3 "$ROOT/deploy/scripts/lib/secrets_resolve.py" \
  --secrets-dir "$ROOT/deploy/secrets" --env "$ENV_NAME" \
  "${TF_ARGS[@]}" "${SVC_ARGS[@]}" > "$RESOLVED" || exit 1

if [ "$DRY_RUN" -eq 1 ]; then
  out="$ROOT/deploy/.run/secrets-$ENV_NAME.json"
  mkdir -p "$ROOT/deploy/.run"; cp "$RESOLVED" "$out"; chmod 600 "$out"
  # The path, never the content — this file holds resolved secrets.
  log_ok "resolved map written to $out ($(jq -r 'keys | length' "$out") services)"
  exit 0
fi

vault_push() {  # vault_push <addr> <token>
  local addr="$1" token="$2" svc payload
  for svc in $(jq -r 'keys[]' "$RESOLVED"); do
    payload="$(jq --arg s "$svc" '{data: .[$s]}' "$RESOLVED")"
    curl -sf -X POST -H "X-Vault-Token: $token" -d "$payload" \
      "$addr/v1/secret/data/$svc" >/dev/null \
      || { log_err "vault write failed for secret/$svc"; return 1; }
    log_ok "secret/$svc"
  done
}

case "$ENV_NAME" in
  compose)
    # load_vault_token() lives in scripts/lib/env.sh (NOT a vault-token.sh) and
    # reads VAULT_TOKEN out of docker/.env, which vault-init.sh keeps in sync.
    . "$ROOT/scripts/lib/env.sh" && load_vault_token 2>/dev/null || true
    : "${VAULT_TOKEN:?VAULT_TOKEN not set — run 'make vault-login' or set it}"
    vault_push "${VAULT_ADDR:-http://localhost:8200}" "$VAULT_TOKEN" || exit 1
    ;;
  k8s)
    # Vault is a ClusterIP Service; forward it for the duration of the push.
    # The `vault` CLI is not installed on the host, so this uses the same HTTP
    # API as the compose path — one push implementation for both envs.
    # The in-cluster Vault runs in dev mode with the literal root token `root`
    # (k8s/infra/jobs/03-vault-seed/job.yaml:19), so this needs no lookup.
    : "${VAULT_TOKEN:=root}"
    kubectl -n infra port-forward svc/vault 18200:8200 >/dev/null 2>&1 &
    pf=$!; trap 'kill $pf 2>/dev/null; rm -f "$RESOLVED"' EXIT
    for _ in $(seq 1 30); do
      curl -sf "http://127.0.0.1:18200/v1/sys/health" >/dev/null 2>&1 && break
      /bin/sleep 1
    done
    vault_push "http://127.0.0.1:18200" "$VAULT_TOKEN" || exit 1
    ;;
  aws)
    region="${AWS_REGION:-ap-southeast-1}"
    for svc in $(jq -r 'keys[]' "$RESOLVED"); do
      aws secretsmanager put-secret-value --region "$region" \
        --secret-id "app/$svc" \
        --secret-string "$(jq -c --arg s "$svc" '.[$s]' "$RESOLVED")" >/dev/null \
        || { log_err "secret app/$svc not found — run 'terraform apply' first"; exit 1; }
      log_ok "app/$svc"
    done
    ;;
esac

log_ok "seeded $ENV_NAME"
