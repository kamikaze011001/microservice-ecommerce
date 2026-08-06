#!/usr/bin/env bash
# Each case corrupts one thing in a copy of the real tree and asserts that
# exactly the matching check fires. A guard that cannot fail is not a guard.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VALIDATE="$ROOT/deploy/scripts/secrets-validate.sh"
pass=0; fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

assert_contains() {
  if grep -qF -- "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted: %s\n       got: %s\n' "$2" "$3"
  fi
}

copy_tree() { local d="$1"; mkdir -p "$d"; cp -R "$ROOT/deploy/secrets/." "$d/"; rm -rf "$d/tests"; }

echo; printf '\033[1msecrets-validate\033[0m\n'

# 0. the real tree is clean
out="$(bash "$VALIDATE" --secrets-dir "$ROOT/deploy/secrets" 2>&1)"
if [ $? -eq 0 ]; then ok "the real tree validates clean"; else
  bad "the real tree validates clean"; printf '%s\n' "$out" | sed 's/^/       /'
fi

# 1. an unresolvable {{ref}} in an env where the key IS active
T="$(mktemp -d)"; copy_tree "$T"
printf '\ncanary.key: "{{definitely.not.defined}}"\n' >> "$T/ecommerce.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 1 catches an unresolvable context ref" "definitely.not.defined" "$out"
rm -rf "$T"

# 2. an unused context key
T="$(mktemp -d)"; copy_tree "$T"
printf '\norphaned.ref: nobody-reads-me\n' >> "$T/contexts/k8s.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 2 catches an unused context key" "orphaned.ref" "$out"
rm -rf "$T"

# 3. an owner:user key naming an undocumented variable
T="$(mktemp -d)"; copy_tree "$T"
cat >> "$T/payment-service.yaml" <<'YAML'
canary.cred:
  value: "${NOT_IN_ENV_EXAMPLE}"
  owner: user
YAML
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 3 catches an undocumented credential variable" "NOT_IN_ENV_EXAMPLE" "$out"
rm -rf "$T"

# 4. a JWK that differs between envs
T="$(mktemp -d)"; copy_tree "$T"
cat >> "$T/authorization-server.yaml" <<'YAML'
application.jwk:
  value: "compose-only-key"
  envs: [compose]
YAML
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 4 catches a per-env JWK" "application.jwk" "$out"
rm -rf "$T"

# 5. an unknown terraform output name in contexts/aws.yaml
T="$(mktemp -d)"; copy_tree "$T"
printf '\nbogus.ref: <terraform:no_such_output>\n' >> "$T/contexts/aws.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 5 catches an unknown terraform output" "no_such_output" "$out"
rm -rf "$T"

# 6. a service's server.port drifts away from the route/feign literal that
# points at it — gateway.routes.product-service.uri and
# feign.client.product-service.url both hardcode :7777 for product-service;
# bump product-service's own server.port and neither caller agrees anymore.
T="$(mktemp -d)"; copy_tree "$T"
python3 - "$T/product-service.yaml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
assert 'server.port: "7777"' in text, "fixture assumption broken: product-service.yaml no longer has server.port 7777"
p.write_text(text.replace('server.port: "7777"', 'server.port: "7778"'))
PY
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 6 catches a route/feign port drifted from server.port" "gateway.routes.product-service.uri" "$out"
rm -rf "$T"

echo; printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
