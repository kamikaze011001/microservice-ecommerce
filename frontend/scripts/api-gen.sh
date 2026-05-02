#!/usr/bin/env bash
# Regenerates src/api/schema.d.ts from the running gateway.
#
# The gateway's root /v3/api-docs only exposes the gateway's own (empty) spec —
# springdoc does NOT physically merge downstream service docs there. So we
# fetch each per-service doc through the gateway, prefix every path with
# /<service-name> (matching how the frontend calls it), then merge paths +
# components.schemas into one document and feed it to openapi-typescript.
#
# Requires: gateway up at http://localhost:6868, jq, pnpm, the per-service
# /v3/api-docs paths permitted in the gateway api_role rules.
set -euo pipefail

GATEWAY="${API_GEN_GATEWAY:-http://localhost:6868}"
OUTPUT="${API_GEN_OUTPUT:-src/api/schema.d.ts}"

# Services whose specs should be merged. Keep in sync with gateway routes.
SERVICES=(
  authorization-server
  product-service
  inventory-service
  order-service
  payment-service
  bff-service
)

if ! command -v jq >/dev/null 2>&1; then
  echo "✗ jq is required (brew install jq)" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

specs=()
for svc in "${SERVICES[@]}"; do
  url="$GATEWAY/$svc/v3/api-docs"
  if ! curl --silent --fail --max-time 5 "$url" -o "$TMP/$svc.json"; then
    echo "  ! skip $svc (unreachable or non-2xx at $url)" >&2
    continue
  fi
  jq --arg p "/$svc" '
    .paths = (
      (.paths // {})
      | with_entries(.key = $p + .key)
    )
  ' "$TMP/$svc.json" > "$TMP/$svc-prefixed.json"
  specs+=("$TMP/$svc-prefixed.json")
  count=$(jq '.paths | length' "$TMP/$svc-prefixed.json")
  echo "  ✓ $svc ($count paths)"
done

if [ "${#specs[@]}" -eq 0 ]; then
  echo "✗ No service specs were fetched — is the gateway up at $GATEWAY?" >&2
  exit 1
fi

jq -s --arg gw "$GATEWAY" '
  reduce .[] as $doc (
    {
      openapi: "3.0.1",
      info: { title: "Microservice E-commerce (aggregated)", version: "v0" },
      servers: [{ url: $gw }],
      paths: {},
      components: { schemas: {} }
    };
    .paths += ($doc.paths // {})
    | .components.schemas += (($doc.components // {}).schemas // {})
  )
' "${specs[@]}" > "$TMP/merged.json"

paths_total=$(jq '.paths | length' "$TMP/merged.json")
schemas_total=$(jq '.components.schemas | length' "$TMP/merged.json")
echo "→ Generating $OUTPUT (paths: $paths_total, schemas: $schemas_total)"

pnpm exec openapi-typescript "$TMP/merged.json" --output "$OUTPUT"
echo "✓ Wrote $OUTPUT"
