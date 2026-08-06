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

# Every case below asserts BOTH on the corrupted identifier AND on the
# issuing check's own "check N" prefix. The identifier alone proves the
# fixture was read; the prefix pins the assertion to the specific check that
# must have fired, so a future message-format change that makes one check's
# output contain another's identifier can't let a case pass while the check
# it names goes untested.

# 1. an unresolvable {{ref}} in an env where the key IS active
T="$(mktemp -d)"; copy_tree "$T"
printf '\ncanary.key: "{{definitely.not.defined}}"\n' >> "$T/ecommerce.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 1 catches an unresolvable context ref" "definitely.not.defined" "$out"
assert_contains "check 1 catches an unresolvable context ref (check-1 prefix)" "check 1 (" "$out"
rm -rf "$T"

# 2. an unused context key
T="$(mktemp -d)"; copy_tree "$T"
printf '\norphaned.ref: nobody-reads-me\n' >> "$T/contexts/k8s.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 2 catches an unused context key" "orphaned.ref" "$out"
assert_contains "check 2 catches an unused context key (check-2 prefix)" "check 2 (" "$out"
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
assert_contains "check 3 catches an undocumented credential variable (check-3 prefix)" "check 3 (" "$out"
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
assert_contains "check 4 catches a per-env JWK (check-4 prefix)" "check 4:" "$out"
rm -rf "$T"

# 5. an unknown terraform output name in contexts/aws.yaml
T="$(mktemp -d)"; copy_tree "$T"
printf '\nbogus.ref: <terraform:no_such_output>\n' >> "$T/contexts/aws.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 5 catches an unknown terraform output" "no_such_output" "$out"
assert_contains "check 5 catches an unknown terraform output (check-5 prefix)" "check 5 (" "$out"
rm -rf "$T"

# 6a. a service's server.port drifts away from the route/feign literal that
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
assert_contains "check 6 catches a route/feign port drifted from server.port (check-6 prefix)" "check 6 (" "$out"
rm -rf "$T"

# 6b. a route key points at a service with no canonical file at all — the
# "target file missing" branch of check 6, otherwise untested.
T="$(mktemp -d)"; copy_tree "$T"
cat >> "$T/gateway.yaml" <<'YAML'
gateway.routes.ghost-service.uri:
  value: "http://ghost-service.local:1234"
  envs: [k8s, aws]
YAML
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 6 catches a route pointing at a missing service file" \
  "gateway.routes.ghost-service.uri" "$out"
assert_contains "check 6 catches a route pointing at a missing service file" \
  "ghost-service.yaml does not exist" "$out"
assert_contains "check 6 catches a route pointing at a missing service file (check-6 prefix)" "check 6 (" "$out"
rm -rf "$T"

# 6c. a route's resolved URL has no trailing :<port> to check at all — the
# "no parseable port" branch of check 6, otherwise untested.
T="$(mktemp -d)"; copy_tree "$T"
python3 - "$T/gateway.yaml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
needle = 'value: "http://{{svc.product-service.host}}:7777"'
assert needle in text, "fixture assumption broken: gateway.yaml's product-service route changed shape"
p.write_text(text.replace(needle, 'value: "http://{{svc.product-service.host}}"'))
PY
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 6 catches a route URL with no trailing port" \
  "gateway.routes.product-service.uri" "$out"
assert_contains "check 6 catches a route URL with no trailing port" \
  "no trailing :<port>" "$out"
assert_contains "check 6 catches a route URL with no trailing port (check-6 prefix)" "check 6 (" "$out"
# …and it reports the RAW template, never the resolved value — the branch's
# global constraint is that no resolved value reaches stdout or test output.
assert_contains "check 6 reports the raw template, not the resolved value" \
  "its template is 'http://{{svc.product-service.host}}'" "$out"
if grep -qF -- "http://product-service.apps" <<<"$out"; then
  bad "check 6 does not leak a resolved value"
  printf '       resolved host appeared in the message\n'
else
  ok "check 6 does not leak a resolved value"
fi
rm -rf "$T"

# 6d. a route points at a real service whose canonical file declares neither
# server.port nor grpc.server.port — the fallback-exhausted branch of check
# 6, otherwise untested (core-s3.yaml has neither key: it's a shared config
# file, not a listener).
T="$(mktemp -d)"; copy_tree "$T"
cat >> "$T/gateway.yaml" <<'YAML'
gateway.routes.core-s3.uri:
  value: "http://core-s3.local:5555"
  envs: [k8s, aws]
YAML
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 6 catches a target with no server.port" \
  "gateway.routes.core-s3.uri" "$out"
assert_contains "check 6 catches a target with no server.port" \
  "declares no server.port" "$out"
assert_contains "check 6 catches a target with no server.port (check-6 prefix)" "check 6 (" "$out"
rm -rf "$T"

# 6e. the gRPC literal in order-service.yaml's OUTBOUND grpc.server.port drifts
# from inventory-service.yaml's own grpc.server.port. This port matches no
# route/feign URL pattern, so before the host/port-pair rule the whole gRPC
# drift class was unguarded.
T="$(mktemp -d)"; copy_tree "$T"
python3 - "$T/order-service.yaml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
assert 'grpc.server.port: "9090"' in text, "fixture assumption broken: order-service.yaml no longer has grpc.server.port 9090"
p.write_text(text.replace('grpc.server.port: "9090"', 'grpc.server.port: "9091"'))
PY
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 6 catches an outbound grpc.server.port drifted from the listener" \
  "order-service.yaml): key 'grpc.server.port'" "$out"
assert_contains "check 6 catches an outbound grpc.server.port drifted from the listener" \
  "inventory-service.yaml's grpc.server.port is 9090" "$out"
assert_contains "check 6 catches an outbound grpc.server.port drifted (check-6 prefix)" "check 6 (" "$out"
rm -rf "$T"

# 6f. the same class from the other spelling: bff-service.yaml's
# inventory.grpc.port. Corrupting the LISTENER this time, so both callers must
# be caught at once by the one edit that would really cause this in practice.
T="$(mktemp -d)"; copy_tree "$T"
python3 - "$T/inventory-service.yaml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
assert 'grpc.server.port: "9090"' in text, "fixture assumption broken: inventory-service.yaml no longer has grpc.server.port 9090"
p.write_text(text.replace('grpc.server.port: "9090"', 'grpc.server.port: "9099"'))
PY
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 6 catches a renamed gRPC listener port (bff caller)" \
  "bff-service.yaml): key 'inventory.grpc.port'" "$out"
assert_contains "check 6 catches a renamed gRPC listener port (order caller)" \
  "order-service.yaml): key 'grpc.server.port'" "$out"
assert_contains "check 6 catches a renamed gRPC listener port (check-6 prefix)" "check 6 (" "$out"
rm -rf "$T"

echo; printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
