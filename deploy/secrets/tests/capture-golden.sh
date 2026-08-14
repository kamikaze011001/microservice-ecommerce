#!/usr/bin/env bash
# Capture what each OLD seeding path would write, with no live backend.
#
#   ./deploy/secrets/tests/capture-golden.sh
#
# compose needs no shim at all: import-secrets.sh POSTs each JSON file verbatim,
# so the map IS the file content under the filename->path mapping at
# scripts/vault/import-secrets.sh:41-51. k8s and aws run their real scripts with
# fake binaries first on PATH.
#
# ── FROZEN — Phase 8 Task 4 (docs/superpowers/specs/2026-08-14-cleanup-cutover-
# design.md D3). Task 5 of this same phase deletes this script's source:
# docker/vault-configs/, scripts/vault/import-secrets.sh, k8s/infra/jobs/
# 03-vault-seed/seed.sh (part of k8s/), and scripts/aws/seed-secrets.sh. THE
# SOURCE IS GOING AWAY AND golden/{compose,k8s,aws}.json MUST NEVER BE
# REGENERATED AGAINST IT AGAIN. These three files are the last known-good
# capture of the OLD per-env seeding paths' vault writes and are committed
# evidence, not a cache — deploy/secrets/tests/equivalence-test.sh diffs the
# new canonical resolver against exactly these bytes. Regenerating destroys
# the only thing that suite has left to check against once the source is gone.
#
# This is the fourth instance in this project of an oracle that can be
# silently invalidated by regeneration (see deploy/scripts/tests/
# capture-baseline.sh's header for the other three and the incident that
# motivated this treatment). Refuses to run unless FORCE=1 is set:
#   FORCE=1 ./deploy/secrets/tests/capture-golden.sh   (regenerate on purpose)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

GOLDEN_ENVS=(compose k8s aws)
existing=0
for e in "${GOLDEN_ENVS[@]}"; do
  [ -s "$HERE/golden/$e.json" ] && existing=$((existing + 1))
done
if [ "$existing" -eq "${#GOLDEN_ENVS[@]}" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "REFUSED: all ${#GOLDEN_ENVS[@]} golden files already exist under deploy/secrets/tests/golden/ -- committed evidence, not a cache. The source (docker/vault-configs/, scripts/vault/import-secrets.sh, k8s/infra/jobs/03-vault-seed/seed.sh, scripts/aws/seed-secrets.sh) is scheduled for deletion; do not regenerate. Set FORCE=1 to override on purpose." >&2
  exit 1
fi

export CAPTURE_DIR="$(mktemp -d)"
export TF_FIXTURE="$HERE/fixtures/terraform-outputs.json"
trap 'rm -rf "$CAPTURE_DIR"' EXIT

mkdir -p "$HERE/golden"
chmod +x "$HERE/shims/"*

# ── k8s ──────────────────────────────────────────────────────────────────────
# seed.sh is a plain shell script; running it with a fake `vault` on PATH is
# enough. It normally runs inside a Job, but it reads no cluster state.
PATH="$HERE/shims:$PATH" bash "$ROOT/k8s/infra/jobs/03-vault-seed/seed.sh" >/dev/null
[ -s "$CAPTURE_DIR/vault-puts.tsv" ] || { echo "FAIL: k8s capture is empty" >&2; exit 1; }

# ── aws ──────────────────────────────────────────────────────────────────────
# The JWK comes from the real compose config so both sides of the equivalence
# diff carry identical bytes. Everything else is a dummy fixture credential.
set -a; . "$HERE/fixtures/user-creds.env"; set +a
export APPLICATION_JWK
APPLICATION_JWK="$(jq -r '."application.jwk"' "$ROOT/docker/vault-configs/authorization-server.json")"
[ -n "$APPLICATION_JWK" ] && [ "$APPLICATION_JWK" != "null" ] \
  || { echo "FAIL: could not read application.jwk from docker/vault-configs" >&2; exit 1; }

PATH="$HERE/shims:$PATH" bash "$ROOT/scripts/aws/seed-secrets.sh" >/dev/null
[ -s "$CAPTURE_DIR/aws-puts.tsv" ] || { echo "FAIL: aws capture is empty" >&2; exit 1; }

# ── assemble ─────────────────────────────────────────────────────────────────
python3 "$HERE/assemble-golden.py" \
  --repo-root "$ROOT" --capture-dir "$CAPTURE_DIR" --out-dir "$HERE/golden"

echo "golden maps written to $HERE/golden"
