#!/usr/bin/env bash
# Lists open [HUMAN ✍️ <ID>] coworking markers and fails while any remain.
#
#   scripts/check-human.sh             # every open marker
#   scripts/check-human.sh KAFKA-PR0   # only markers whose ID starts with this
#
# Marker shape (// in Java, # in YAML/shell):
#   // [HUMAN ✍️ KAFKA-PR0.2] <goal>
#   //   why:  <decision behind it>
#   //   done: <test or command that proves it>
# Delete the whole marker block when the task is done.
set -euo pipefail

prefix="${1:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"

hits="$(grep -rn --exclude-dir={.git,node_modules,target,dist} \
          --exclude=check-human.sh \
          -e "\[HUMAN ✍️ ${prefix}" "$root" || true)"

if [[ -z "$hits" ]]; then
  echo "check-human: no open markers${prefix:+ for ${prefix}}"
  exit 0
fi

echo "check-human: open markers${prefix:+ for ${prefix}}:"
echo "$hits" | sed "s|^${root}/|  |"
exit 1
