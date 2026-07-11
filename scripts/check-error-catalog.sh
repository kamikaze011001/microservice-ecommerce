#!/usr/bin/env bash
# Ratchet gate: fails on any NEW non-dotted/unresolved error code (setCode literal
# in a service/core main source), or any STALE baseline line that no longer offends.
# Baseline of grandfathered offenders: scripts/error-catalog-baseline.txt.
# Usage: check-error-catalog.sh          -> gate (exit 0 OK / 1 FAIL)
#        check-error-catalog.sh --dump    -> print current offenders (to regen baseline)
set -euo pipefail
cd "$(dirname "$0")/.."

DOTTED='^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'
BASELINE="scripts/error-catalog-baseline.txt"

# 1. Codes referenced via setCode("…") in main sources (tests excluded by the path glob).
mapfile -t used < <(git ls-files '*/src/main/*.java' \
  | xargs -r grep -hoE 'setCode\("[^"]+"\)' 2>/dev/null \
  | sed -E 's/setCode\("([^"]+)"\)/\1/' | sort -u)

# 2. Keys defined across every message bundle.
keys="$(git ls-files '*messages*.properties' | xargs -r grep -hoE '^[^#=]+=' | sed 's/=$//' | tr -d ' ' | sort -u)"

# 3. Current offenders = non-dotted OR dotted-but-unresolved.
offenders=()
for code in "${used[@]:-}"; do
  [ -z "$code" ] && continue
  if ! [[ "$code" =~ $DOTTED ]]; then offenders+=("$code"); continue; fi
  grep -qxF "$code" <<< "$keys" || offenders+=("$code")
done

# --dump: emit the offender set for baseline regeneration, then exit.
if [ "${1:-}" = "--dump" ]; then
  printf '%s\n' "${offenders[@]:-}" | sed '/^$/d' | sort -u
  exit 0
fi

# 4. Load baseline (comment/blank lines ignored).
baseline=()
if [ -f "$BASELINE" ]; then
  mapfile -t baseline < <(grep -vE '^\s*(#|$)' "$BASELINE" | sort -u)
fi

off_str="$(printf '%s\n' "${offenders[@]:-}" | sed '/^$/d' | sort -u)"
base_str="$(printf '%s\n' "${baseline[@]:-}" | sed '/^$/d' | sort -u)"

fail=0
# NEW offenders = current offenders not grandfathered.
while IFS= read -r code; do
  [ -z "$code" ] && continue
  grep -qxF "$code" <<< "$base_str" || { echo "NEW offender: '$code' (must be dotted <domain>.<entity>.<reason> AND defined in a bundle)"; fail=1; }
done <<< "$off_str"
# STALE baseline entries = grandfathered codes that no longer offend → must be pruned.
while IFS= read -r code; do
  [ -z "$code" ] && continue
  grep -qxF "$code" <<< "$off_str" || { echo "STALE baseline: '$code' no longer offends — remove it from $BASELINE"; fail=1; }
done <<< "$base_str"

if [ "$fail" -ne 0 ]; then echo "check-error-catalog: FAIL"; exit 1; fi
n=$(grep -c . <<< "$off_str" || true)
echo "check-error-catalog: OK (${n} known offenders grandfathered; 0 new)"
