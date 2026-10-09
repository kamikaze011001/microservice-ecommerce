#!/usr/bin/env bash
# Tag rules for deploy/devbox/lib/version.sh, against a throwaway git repo.
# No cluster, no registry.   bash deploy/devbox/tests/version-test.sh
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/version.sh"
# shellcheck source=../lib/version.sh
. "$LIB"

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q -b main
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mkdir -p order-service inventory-service core/common-dto deploy/images frontend
echo a > order-service/A.java; echo a > inventory-service/A.java
echo a > core/common-dto/D.java; echo a > deploy/images/Dockerfile.jvm
echo a > deploy/images/Dockerfile.cores; echo a > frontend/index.html
g add -A; g commit -qm base
base=$(git rev-parse --short=7 HEAD)

eq "clean tree: tag = last commit touching the inputs" "$(version_of order-service)" "$base"

echo b > order-service/A.java; g commit -qam "order only"
order_c=$(git rev-parse --short=7 HEAD)
eq "a commit to order-service retags order-service"   "$(version_of order-service)" "$order_c"
eq "...and leaves inventory-service on its old tag"   "$(version_of inventory-service)" "$base"

echo b > core/common-dto/D.java; g commit -qam "core"
core_c=$(git rev-parse --short=7 HEAD)
eq "a core/ change retags every JVM service"          "$(version_of inventory-service)" "$core_c"
eq "...but not the frontend (no core/ in its image)"  "$(version_of frontend)" "$base"

echo c > order-service/A.java
eq "uncommitted edit → <sha>-dirty-<now>"             "$(version_of order-service 1009-1432)" "$core_c-dirty-1009-1432"
eq "...only for the service that has it"              "$(version_of inventory-service 1009-1432)" "$core_c"
git checkout -q -- order-service

echo new > order-service/New.java
eq "an untracked file in the inputs is dirty too"     "$(version_of order-service 1009-1432)" "$core_c-dirty-1009-1432"
rm order-service/New.java

echo x > README.md
eq "changes outside the inputs don't dirty a service" "$(version_of order-service)" "$core_c"

if is_dirty_tag "abc1234-dirty-1009-1432" && ! is_dirty_tag "abc1234"; then ok "is_dirty_tag"; else bad "is_dirty_tag"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
