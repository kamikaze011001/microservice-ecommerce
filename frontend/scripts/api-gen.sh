#!/usr/bin/env bash
# Regenerates src/api/schema.d.ts from the running gateway's OpenAPI spec.
# Requires: `make up` running so http://localhost:8080/v3/api-docs is reachable.
set -euo pipefail

SOURCE="${API_GEN_SOURCE:-http://localhost:8080/v3/api-docs}"
OUTPUT="${API_GEN_OUTPUT:-src/api/schema.d.ts}"

if ! curl --silent --fail --max-time 5 "$SOURCE" >/dev/null; then
  echo "✗ Cannot reach $SOURCE — is the gateway up? Run 'make up' from repo root." >&2
  exit 1
fi

echo "→ Generating $OUTPUT from $SOURCE"
pnpm exec openapi-typescript "$SOURCE" --output "$OUTPUT"
echo "✓ Wrote $OUTPUT"
