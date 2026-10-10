#!/usr/bin/env bash
# Offline checks for deploy/devbox/lib/perf.sh. No cluster, no VictoriaMetrics.
#   bash deploy/devbox/tests/perf-test.sh
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd)/colors.sh"
# shellcheck source=../lib/perf.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/perf.sh"

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
has() { if grep -qE -- "$2" <<<"$3"; then ok "$1"; else bad "$1 — got: $3"; fi; }

A="authorization-server=dev,order-service=ac48ad8,payment-service=dev"
has "same versions → says so, and calls the delta noise" 'none — same code' "$(versions_diff "$A" "$A")"
out="$(versions_diff "$A" "authorization-server=dev,order-service=9f8e7d6,payment-service=dev")"
has "a changed service is listed old → new" 'order-service  ac48ad8 → 9f8e7d6' "$out"
has "...and only that one" '^1$' "$(grep -c '→' <<<"$out")"
has "a service only in B shows as added" 'redis  - → x' \
  "$(versions_diff "$A" "$A,redis=x")"

has "payment smoke is a small CLI override" '^--vus 3 --duration 30s$' "$(perf_profile_args payment smoke)"
has "payment load runs the script's own stages" '^$' "$(perf_profile_args payment load)"
has "storefront profiles pass through as PROFILE" '^-e PROFILE=soak$' "$(perf_profile_args storefront soak)"
has "an undefined profile is refused" "isn't defined" "$(perf_profile_args payment soak 2>&1)"
has "an unknown scenario is refused" 'unknown scenario' "$(perf_script checkout 2>&1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
