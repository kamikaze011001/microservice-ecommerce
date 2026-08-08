#!/usr/bin/env bash
# The standing invariant from docs/superpowers/specs/2026-08-08-canonical-
# seed-design.md §5 / §D4: rendering deploy/seed/product.json for `compose`
# must reproduce docker/product.json byte-for-byte. It is the only thing
# that keeps deploy/seed/* (the canonical copy) and docker/* (kept
# byte-identical for its 20 existing consumers) from drifting apart silently.
#
#   ./deploy/seed/tests/render-test.sh
#
# ONLY this test lives here at this stage (Task 2 of Phase 5). The renderer
# itself (deploy/scripts/lib/seed_render.py) does not exist yet — it is
# Task 3 — so this MUST FAIL until Task 3 lands. Renderer unit tests land
# alongside seed_render.py in Task 3, not here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RENDERER="$ROOT/deploy/scripts/lib/seed_render.py"
pass=0; fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo
echo -e "\033[1mseed render — compose/product.json byte-for-byte invariant\033[0m"

rendered="$(cd "$ROOT" && python3 "$RENDERER" --env compose --only product.json 2>&1)"
if diff <(printf '%s' "$rendered") "$ROOT/docker/product.json" >/dev/null 2>&1; then
  ok "compose render reproduces docker/product.json byte-for-byte"
else
  bad "compose render differs from docker/product.json"
  printf '       renderer output (first 3 lines):\n'
  printf '%s\n' "$rendered" | head -3 | sed 's/^/         /'
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
