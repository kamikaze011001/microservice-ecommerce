#!/usr/bin/env bash
# Decision-table suite for scripts/lib/eureka.sh. Fixture-driven: never touches
# a live Eureka, so it runs with the stack down.
#
# The two fail-safe rows matter most. A correct "selects nothing" and a broken
# check are indistinguishable from outside, so they are asserted as explicit
# non-stale verdicts, never inferred from "no restart happened".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
source "$ROOT/scripts/lib/eureka.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# The fixture registers everything at 192.168.0.103. gateway is port 6868 and
# appears in Eureka as CLOUD-GATEWAY — the case a name-based join would miss.
export EUREKA_APPS_FIXTURE="$HERE/fixtures/eureka-apps.json"

# 1. registered + IP differs -> stale
HOST_IP_OVERRIDE=10.0.0.7 eureka_staleness 6868 \
  && ok "drifted gateway (CLOUD-GATEWAY, port join) is stale" \
  || bad "drifted gateway should be stale"

# 2. registered + IP matches -> not stale
HOST_IP_OVERRIDE=192.168.0.103 eureka_staleness 6868 \
  && bad "matching IP must not be stale" \
  || ok "matching IP is not stale"

# 2b. registered IP is a local address that is NOT the default-route one ->
# not stale. This is the case that loops forever under equality: Spring picks
# its address by InetUtils enumeration order, we picked ours from the default
# route, and a disagreement is a WRONG answer rather than an empty one — so no
# fail-safe catches it and every service restarts on every `make up`, forever.
HOST_IP_OVERRIDE=$'10.9.9.9\n192.168.0.103' eureka_staleness 6868 >/dev/null \
  && bad "a local (non-default-route) address must not be stale" \
  || ok "registered IP present in the local set is not stale"

# 3. not registered (orchestrator 9999 never registers) -> not stale
HOST_IP_OVERRIDE=10.0.0.7 eureka_staleness 9999 \
  && bad "unregistered service must not be stale" \
  || ok "unregistered service is not stale"

# 4. FAIL-SAFE: Eureka unreachable -> not stale, even with a drifted IP
EUREKA_APPS_FIXTURE=/nonexistent HOST_IP_OVERRIDE=10.0.0.7 eureka_staleness 6868 \
  && bad "unreachable Eureka must NOT report stale" \
  || ok "unreachable Eureka reports not-stale (fail-safe)"

# 5. FAIL-SAFE: host IP undeterminable -> not stale
HOST_IP_OVERRIDE= FORCE_NO_HOST_IP=1 eureka_staleness 6868 \
  && bad "undeterminable host IP must NOT report stale" \
  || ok "undeterminable host IP reports not-stale (fail-safe)"

# 6. the fixture itself is not empty (guards a vacuous suite)
[ -s "$HERE/fixtures/eureka-apps.json" ] \
  && ok "fixture is non-empty" || bad "fixture is empty — suite would be vacuous"

# 7. STALE prints "<reg_ip> <host_ip>" so the caller can log the values that
# drove the decision without a second Eureka round-trip. This is what lets one
# function serve both start.sh and this suite — the duplication it replaces
# meant a green run here proved nothing about the shipped path.
_out=$(HOST_IP_OVERRIDE=10.0.0.7 eureka_staleness 6868) && _rc=0 || _rc=1
if [ "$_rc" -eq 0 ] && [ "${_out%% *}" = "192.168.0.103" ] && [ "${_out#* }" = "10.0.0.7" ]; then
    ok "stale verdict carries reg_ip and host_ip on stdout"
else
    bad "expected '192.168.0.103 10.0.0.7', got '$_out' (rc=$_rc)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
