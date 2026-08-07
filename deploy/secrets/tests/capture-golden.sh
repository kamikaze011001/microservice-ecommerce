#!/usr/bin/env bash
# Capture what each OLD seeding path would write, with no live backend.
#
#   ./deploy/secrets/tests/capture-golden.sh
#
# compose needs no shim at all: import-secrets.sh POSTs each JSON file verbatim,
# so the map IS the file content under the filename->path mapping at
# scripts/vault/import-secrets.sh:41-51. k8s and aws run their real scripts with
# fake binaries first on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

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
