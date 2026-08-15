#!/usr/bin/env bash
# Diff the resolver's output against the golden capture of the OLD paths.
#
#   ./deploy/secrets/tests/equivalence-test.sh
#
# Scoped to the services that currently exist under deploy/secrets/, so it is
# meaningful while the canonical files are still being written. A service with
# no canonical file yet is reported as PENDING, never as a pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SECRETS="$ROOT/deploy/secrets"
RESOLVER="$ROOT/deploy/scripts/lib/secrets_resolve.py"
TF="$HERE/fixtures/terraform-outputs.json"

set -a; . "$HERE/fixtures/user-creds.env"; set +a

# APPLICATION_JWK used to be exported here, read out of
# docker/vault-configs/authorization-server.json. Removed when that tree was
# deleted (Phase 8 Task 8, step 1), and it was already dead: the canonical
# source declares `application.jwk: "<file:jwk.private.json>"`
# (deploy/secrets/authorization-server.yaml:11), so the resolver reads the
# committed key file and never consults this variable.
#
# Worth recording HOW it was found, because the suite did not notice. After the
# deletion `jq` failed, the assignment produced an EMPTY string, and this suite
# still reported 33 passed / 0 failed — a pass that proved nothing about the
# vanished input. Only a path-qualified grep for the deleted directory surfaced
# it. Compare capture-golden.sh, which reads the same file but GUARDS it
# (`[ -n "$APPLICATION_JWK" ] && [ "$APPLICATION_JWK" != "null" ]`) and so fails
# loudly instead. The guard is the whole difference.

pass=0; fail=0; pending=0

for env in compose k8s aws; do
  echo
  printf '\033[1m%s\033[0m\n' "$env"
  actual="$(python3 "$RESOLVER" --secrets-dir "$SECRETS" --env "$env" --tf-outputs "$TF" 2>&1)" || {
    printf '  \033[31mFAIL\033[0m resolver errored: %s\n' "$actual"; fail=$((fail + 1)); continue
  }
  # Iterate the UNION of both key sets, not the golden's alone. Iterating the
  # golden made a canonical file with no golden entry invisible: never diffed,
  # never reported, silently zero coverage. Both directions are now visible —
  # golden-only is PENDING (canonical file not written yet, never a pass),
  # canonical-only is a hard FAIL (nothing to prove it against).
  golden_svcs="$(jq -r 'keys[]' "$HERE/golden/$env.json" | sort)"
  canonical_svcs="$(cd "$SECRETS" && ls -1 ./*.yaml | sed 's#^\./##; s/\.yaml$//' | sort)"
  for svc in $(printf '%s\n%s\n' "$golden_svcs" "$canonical_svcs" | sort -u); do
    if ! grep -qxF -- "$svc" <<<"$golden_svcs"; then
      printf '  \033[31mFAIL\033[0m %s (canonical file has no golden entry — nothing to diff it against)\n' "$svc"
      fail=$((fail + 1)); continue
    fi
    if [ ! -f "$SECRETS/$svc.yaml" ]; then
      printf '  \033[33m..\033[0m   %s (no canonical file yet)\n' "$svc"; pending=$((pending + 1)); continue
    fi
    want="$(jq -S --arg s "$svc" '.[$s]' "$HERE/golden/$env.json")"
    got="$(jq -S --arg s "$svc" '.[$s]' <<<"$actual")"
    if [ "$want" = "$got" ]; then
      printf '  \033[32mok\033[0m   %s\n' "$svc"; pass=$((pass + 1))
    else
      printf '  \033[31mFAIL\033[0m %s\n' "$svc"; fail=$((fail + 1))
      # Key NAMES only — values are secrets and must never reach a log.
      diff <(jq -r 'keys[]' <<<"$want") <(jq -r 'keys[]' <<<"$got") \
        | sed 's/^/         /' || true
      changed="$(jq -r --argjson a "$want" --argjson b "$got" \
        -n '$a | to_entries | map(select(.value != ($b[.key] // null))) | map(.key)[]' 2>/dev/null)"
      [ -n "$changed" ] && printf '         value differs: %s\n' "$(tr '\n' ' ' <<<"$changed")"
    fi
  done
done

echo
printf '%d passed, %d failed, %d pending\n' "$pass" "$fail" "$pending"
[ "$fail" -eq 0 ]
