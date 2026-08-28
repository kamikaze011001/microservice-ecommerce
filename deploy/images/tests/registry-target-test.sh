#!/usr/bin/env bash
# Decision table for deploy/images/lib/registry-target.sh.
#
# The probe in build.sh answers "is the local dev registry up?" — a question
# that only makes sense for a plain-HTTP registry on this machine. Applied to a
# remote registry it hangs on a closed port 80 and then reports the wrong system.
# These rows pin which registries are probe-able. Pure string classification:
# no network, no docker, no AWS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
source "$ROOT/deploy/images/lib/registry-target.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# --- local registries: MUST be probed -----------------------------------------
registry_is_local_http "localhost:5001" \
  && ok "localhost:5001 (host push port) is probe-able" \
  || bad "localhost:5001 must be probe-able"

registry_is_local_http "localhost:5000" \
  && ok "localhost:5000 (in-cluster pull port) is probe-able" \
  || bad "localhost:5000 must be probe-able"

registry_is_local_http "127.0.0.1:5001" \
  && ok "127.0.0.1:5001 is probe-able" \
  || bad "127.0.0.1:5001 must be probe-able"

# --- remote registries: MUST NOT be probed ------------------------------------
registry_is_local_http "583178372344.dkr.ecr.ap-southeast-1.amazonaws.com" \
  && bad "ECR must not be probed over http" \
  || ok "ECR is not probe-able"

registry_is_local_http "ghcr.io" \
  && bad "ghcr.io must not be probed over http" \
  || ok "ghcr.io is not probe-able"

registry_is_local_http "docker.io" \
  && bad "docker.io must not be probed over http" \
  || ok "docker.io is not probe-able"

# --- fail-safe rows -----------------------------------------------------------
# A classifier that returns 0 for everything would pass every row above except
# these. A classifier that returns 1 for everything would pass the remote rows
# but fail the local ones. Both directions are pinned.
registry_is_local_http "" \
  && bad "empty registry must not be treated as local" \
  || ok "empty registry is not probe-able"

# Substring traps: these CONTAIN 'localhost' but are not local.
registry_is_local_http "localhost.evil.example.com" \
  && bad "localhost.evil.example.com is remote, not local" \
  || ok "hostname merely starting with 'localhost' is not probe-able"

registry_is_local_http "registry.localhost.example.com:5001" \
  && bad "registry.localhost.example.com is remote, not local" \
  || ok "hostname merely containing 'localhost' is not probe-able"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
