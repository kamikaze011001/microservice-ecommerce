#!/usr/bin/env bash
# Ratchet gate: fails on any NEW non-dotted/unresolved error code (setCode literal,
# or the first string-literal arg of a `new <BaseException-subclass>("…")` constructor
# call, in a service/core main source), or any STALE baseline line that no longer offends.
# Baseline of grandfathered offenders: scripts/error-catalog-baseline.txt.
# Usage: check-error-catalog.sh          -> gate (exit 0 OK / 1 FAIL)
#        check-error-catalog.sh --dump    -> print current offenders (to regen baseline)
set -euo pipefail
cd "$(dirname "$0")/.."

DOTTED='^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'
BASELINE="scripts/error-catalog-baseline.txt"

# 1a. Codes referenced via setCode("…") in main sources (tests excluded by the path glob).
mapfile -t used_setcode < <(git ls-files '*/src/main/*.java' \
  | xargs -r grep -hoE 'setCode\("[^"]+"\)' 2>/dev/null \
  | sed -E 's/setCode\("([^"]+)"\)/\1/' | sort -u)

# 1b. Codes referenced as the first string-literal arg of `new <Name>("…"` calls, where
# <Name> is in the transitive extends-closure of BaseException. Scoping to real
# BaseException subclasses keeps JDK exceptions (new IllegalArgumentException("some
# message")) — whose first arg is a MESSAGE, not a code — out of the offender set.
mapfile -t class_edges < <(git ls-files '*/src/main/*.java' \
  | xargs -r grep -hoE 'class[[:space:]]+[A-Za-z0-9_]+[[:space:]]+extends[[:space:]]+[A-Za-z0-9_]+' 2>/dev/null \
  | sed -E 's/class[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+extends[[:space:]]+([A-Za-z0-9_]+)/\1 \2/' | sort -u)

declare -A exc_types=([BaseException]=1)
for ((pass = 0; pass < 10; pass++)); do
  grew=0
  for edge in "${class_edges[@]:-}"; do
    [ -z "$edge" ] && continue
    child="${edge%% *}"
    parent="${edge#* }"
    if [[ -n "${exc_types[$parent]:-}" && -z "${exc_types[$child]:-}" ]]; then
      exc_types[$child]=1
      grew=1
    fi
  done
  [ "$grew" -eq 0 ] && break
done
exc_names="$(printf '%s\n' "${!exc_types[@]}" | sort -u | paste -sd'|' -)"

used_ctor=()
if [ -n "$exc_names" ]; then
  mapfile -t used_ctor < <(git ls-files '*/src/main/*.java' \
    | xargs -r grep -hoE "new (${exc_names})\(\"[^\"]+\"" 2>/dev/null \
    | sed -E "s/new (${exc_names})\(\"([^\"]+)\"/\2/" | sort -u)
fi

# 1c. used[] = union of setCode("…") literals and constructor-arg literals.
mapfile -t used < <(printf '%s\n' "${used_setcode[@]:-}" "${used_ctor[@]:-}" | sed '/^$/d' | sort -u)

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
