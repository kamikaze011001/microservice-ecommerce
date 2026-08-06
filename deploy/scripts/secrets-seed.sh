#!/usr/bin/env bash
# Resolve deploy/secrets/ and push it to this env's backend.
#
#   deploy/scripts/secrets-seed.sh --env compose|k8s|aws [--dry-run]
#                                  [--service NAME] [--refresh-tf]
#                                  [--tf-outputs FILE] [--context NAME]
#
# --context NAME (or KUBE_CONTEXT=NAME) is REQUIRED for --env k8s and names the
# kubectl context this seed is allowed to write to. See the k8s branch below
# for why an ambient current-context is not good enough.
#
# --tf-outputs FILE overrides the deploy/.run/terraform-outputs.json cache
# for ENV=aws and skips the terraform block entirely — this is the offline/CI
# path, and it applies whether or not --dry-run is also given. Without it,
# behaviour is unchanged: generate the cache when missing, warn past 24h old,
# never auto-refresh.
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

ENV_NAME=""; DRY_RUN=0; SERVICE=""; REFRESH_TF=0; TF_OUTPUTS_OVERRIDE=""
KUBE_CONTEXT="${KUBE_CONTEXT:-}"; CONTEXT_FLAG_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env)        ENV_NAME="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --service)    SERVICE="$2"; shift 2 ;;
    --refresh-tf) REFRESH_TF=1; shift ;;
    --tf-outputs) TF_OUTPUTS_OVERRIDE="$2"; shift 2 ;;
    --context)    KUBE_CONTEXT="$2"; CONTEXT_FLAG_GIVEN=1; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$ENV_NAME" in
  compose|k8s|aws) ;;
  *) echo "usage: secrets-seed.sh --env compose|k8s|aws [--dry-run] [--service NAME] [--refresh-tf] [--tf-outputs FILE] [--context NAME]" >&2; exit 2 ;;
esac

# A kubectl context means nothing to the compose or aws backends. Accepting it
# silently would leave the user believing they had pinned a target on a seeding
# tool — a flag that appears to work but does nothing is worse than one that
# refuses. Note this rejects only the explicit --context; an ambient
# KUBE_CONTEXT in the environment is ignored for these envs, as it must be.
if [ "$CONTEXT_FLAG_GIVEN" -eq 1 ] && [ "$ENV_NAME" != "k8s" ]; then
  echo "--context applies only to --env k8s (got --env $ENV_NAME)" >&2; exit 2
fi

# ENV=k8s writes to whichever cluster kubectl happens to point at, and there is
# nothing in a `kubectl port-forward svc/vault -n infra` that says which one.
# An ambient current-context left over from unrelated work (a production-
# adjacent managed cluster, say) is a live footgun, so the target is never
# inferred: name it with --context/KUBE_CONTEXT and it is checked against
# current-context before a single byte moves. Refusing is the correct default —
# there is no context name this repo can safely assume. --dry-run touches no
# cluster, so it is exempt.
if [ "$ENV_NAME" = "k8s" ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "$KUBE_CONTEXT" ]; then
    log_err "ENV=k8s needs an explicit kubectl context: pass --context NAME or set KUBE_CONTEXT"
    log_err "current context is '$(kubectl config current-context 2>/dev/null || echo '<none>')' — seeding refuses to guess"
    exit 1
  fi
  CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  if [ "$CURRENT_CONTEXT" != "$KUBE_CONTEXT" ]; then
    log_err "refusing to seed: requested context '$KUBE_CONTEXT' but kubectl's current context is '${CURRENT_CONTEXT:-<none>}'"
    log_err "run 'kubectl config use-context $KUBE_CONTEXT' first, or correct --context/KUBE_CONTEXT"
    exit 1
  fi
fi

TF_ARGS=()
if [ "$ENV_NAME" = "aws" ]; then
  if [ -n "$TF_OUTPUTS_OVERRIDE" ]; then
    # Explicit override: the offline/CI path. Use this file verbatim and
    # never invoke terraform — this is what makes a resolve (dry-run or not)
    # unconditionally offline instead of depending on a magic cache path.
    TF_ARGS=(--tf-outputs "$TF_OUTPUTS_OVERRIDE")
  else
    TF_CACHE="$ROOT/deploy/.run/terraform-outputs.json"
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
fi

RESOLVED="$(mktemp)"; trap 'rm -f "$RESOLVED"' EXIT
SVC_ARGS=(); [ -n "$SERVICE" ] && SVC_ARGS=(--service "$SERVICE")

python3 "$ROOT/deploy/scripts/lib/secrets_resolve.py" \
  --secrets-dir "$ROOT/deploy/secrets" --env "$ENV_NAME" \
  "${TF_ARGS[@]}" "${SVC_ARGS[@]}" > "$RESOLVED" || exit 1

if [ "$DRY_RUN" -eq 1 ]; then
  out="$ROOT/deploy/.run/secrets-$ENV_NAME.json"
  mkdir -p "$ROOT/deploy/.run"
  # umask BEFORE the copy, not chmod after it: this file holds every resolved
  # secret, and a create-then-chmod leaves a window where it is world-readable.
  # The chmod still runs, to also narrow a pre-existing file cp would inherit
  # the mode of.
  (umask 077; cp "$RESOLVED" "$out") && chmod 600 "$out"
  # The path, never the content — this file holds resolved secrets.
  log_ok "resolved map written to $out ($(jq -r 'keys | length' "$out") services)"
  exit 0
fi

vault_push() {  # vault_push <addr> <token>
  # Payload goes to curl over stdin (--data @-), never as a CLI argument —
  # argv is world-readable via ps/ /proc for the life of the subprocess, and
  # this whole tool exists to handle secrets.
  local addr="$1" token="$2" svc
  for svc in $(jq -r 'keys[]' "$RESOLVED"); do
    jq --arg s "$svc" '{data: .[$s]}' "$RESOLVED" \
      | curl -sf -X POST -H "X-Vault-Token: $token" --data @- \
          "$addr/v1/secret/data/$svc" >/dev/null \
      || { log_err "vault write failed for secret/$svc"; return 1; }
    log_ok "secret/$svc"
  done
}

case "$ENV_NAME" in
  compose)
    # load_vault_token() lives in scripts/lib/env.sh (NOT a vault-token.sh) and
    # reads VAULT_TOKEN out of vault-keys.json's root_token. `make bootstrap`
    # creates that file — the function's own error message says so.
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
    # --context is passed explicitly, so the context that was checked above and
    # the context actually written to cannot diverge (a concurrent
    # `kubectl config use-context` between the check and here would otherwise
    # redirect the push).
    kubectl --context "$KUBE_CONTEXT" -n infra port-forward svc/vault 18200:8200 >/dev/null 2>&1 &
    pf=$!; trap 'kill $pf 2>/dev/null; rm -f "$RESOLVED"' EXIT
    for _ in $(seq 1 30); do
      curl -sf "http://127.0.0.1:18200/v1/sys/health" >/dev/null 2>&1 && break
      /bin/sleep 1
    done
    vault_push "http://127.0.0.1:18200" "$VAULT_TOKEN" || exit 1
    ;;
  aws)
    region="${AWS_REGION:-ap-southeast-1}"
    # Per-service payload goes to a mode-600 temp file, read via file:// —
    # never as a --secret-string CLI argument, which would put the resolved
    # value in argv for the life of the aws subprocess. Created (mktemp, then
    # chmod) before anything is written to it; this trap supersedes the one
    # installed right after $RESOLVED was created, so it now removes both on
    # every exit path.
    SVC_FILE="$(mktemp)"; chmod 600 "$SVC_FILE"
    trap 'rm -f "$RESOLVED" "$SVC_FILE"' EXIT
    for svc in $(jq -r 'keys[]' "$RESOLVED"); do
      jq -c --arg s "$svc" '.[$s]' "$RESOLVED" > "$SVC_FILE"
      # Capture stderr and report it. ResourceNotFound is only ONE way this
      # fails — AccessDenied, expired credentials, a wrong region and
      # throttling all land here too, and "run terraform apply first" sends
      # you the wrong way at exactly the moment of an AWS cutover. The payload
      # is passed as file://, so nothing aws echoes back carries a value.
      aws_err="$(aws secretsmanager put-secret-value --region "$region" \
        --secret-id "app/$svc" \
        --secret-string "file://$SVC_FILE" 2>&1 >/dev/null)" \
        || { log_err "put-secret-value failed for app/$svc in $region: ${aws_err:-<no stderr>}"
             log_err "if the secret does not exist yet, run 'terraform apply' first"
             exit 1; }
      log_ok "app/$svc"
    done
    ;;
esac

log_ok "seeded $ENV_NAME"
