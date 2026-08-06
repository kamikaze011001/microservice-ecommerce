#!/usr/bin/env bash
# Unit tests for deploy/scripts/lib/secrets_resolve.py.
#
#   ./deploy/secrets/tests/resolver-test.sh
#
# Each case builds a minimal secrets tree in a temp dir, so these tests never
# depend on the real deploy/secrets/ content and cannot be made vacuous by it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$(cd "$HERE/../../scripts/lib" && pwd)/secrets_resolve.py"
pass=0; fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# assert_eq <description> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1"; printf '       expected: %s\n       actual:   %s\n' "$2" "$3"
  fi
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
  if grep -qF -- "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted substring: %s\n       in: %s\n' "$2" "$3"
  fi
}

# mktree <dir> — a minimal secrets tree exercising every syntax
mktree() {
  local d="$1"
  mkdir -p "$d/contexts"
  cat > "$d/demo.yaml" <<'YAML'
plain.key: hello
templated.key: "jdbc://{{db.host}}:{{db.port}}/x"
user.key:
  value: "${DEMO_SECRET}"
  owner: user
conditional.key:
  value: "only-here"
  envs: [k8s]
file.key: "<file:blob.txt>"
YAML
  printf 'BLOBBYTES' > "$d/blob.txt"
  cat > "$d/contexts/compose.yaml" <<'YAML'
userCredDelivery: envfrom
db.host: localhost
db.port: "3306"
YAML
  cat > "$d/contexts/k8s.yaml" <<'YAML'
userCredDelivery: envfrom
db.host: mysql.infra.svc.cluster.local
db.port: "3306"
YAML
  cat > "$d/contexts/aws.yaml" <<'YAML'
userCredDelivery: backend
db.host: <terraform:rds_primary_endpoint>
db.port: "3306"
YAML
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mktree "$TMP"
TF="$TMP/tf.json"
printf '{"rds_primary_endpoint":{"value":"rds.example.com"}}' > "$TF"

run() { DEMO_SECRET="${DEMO_SECRET:-}" python3 "$RESOLVER" --secrets-dir "$TMP" "$@" 2>&1; }

echo
echo -e "\033[1mresolver\033[0m"

# 1. plain scalar passes through
out="$(DEMO_SECRET=s run --env compose --service demo)"
assert_eq "plain scalar is emitted verbatim" \
  "hello" "$(jq -r '.demo["plain.key"]' <<<"$out")"

# 2. {{ref}} resolves from the context, and differs per env
assert_eq "compose {{db.host}} resolves to localhost" \
  "jdbc://localhost:3306/x" "$(jq -r '.demo["templated.key"]' <<<"$out")"
out_k="$(DEMO_SECRET=s run --env k8s --service demo)"
assert_eq "k8s {{db.host}} resolves to cluster DNS" \
  "jdbc://mysql.infra.svc.cluster.local:3306/x" "$(jq -r '.demo["templated.key"]' <<<"$out_k")"

# 3. envs: gates the key
assert_eq "conditional key is ABSENT on compose" \
  "null" "$(jq -r '.demo["conditional.key"] // "null"' <<<"$out")"
assert_eq "conditional key is PRESENT on k8s" \
  "only-here" "$(jq -r '.demo["conditional.key"]' <<<"$out_k")"

# 4. owner:user + userCredDelivery
assert_eq "owner:user key is EXCLUDED when userCredDelivery=envfrom" \
  "null" "$(jq -r '.demo["user.key"] // "null"' <<<"$out")"
out_a="$(DEMO_SECRET=s run --env aws --service demo --tf-outputs "$TF")"
assert_eq "owner:user key is INCLUDED when userCredDelivery=backend" \
  "s" "$(jq -r '.demo["user.key"]' <<<"$out_a")"

# 5. <terraform:> resolves in the context, from the fixture
assert_eq "aws <terraform:> ref resolves from --tf-outputs" \
  "jdbc://rds.example.com:3306/x" "$(jq -r '.demo["templated.key"]' <<<"$out_a")"

# 6. <file:> reads bytes from disk
assert_eq "<file:> ref reads the file's bytes" \
  "BLOBBYTES" "$(jq -r '.demo["file.key"]' <<<"$out")"

# 7-10. every failure mode names its own kind of input
missing_ctx="$TMP/missing-ctx"; mkdir -p "$missing_ctx/contexts"
printf 'k: "{{nope.here}}"\n' > "$missing_ctx/demo.yaml"
printf 'userCredDelivery: envfrom\n' > "$missing_ctx/contexts/compose.yaml"
err="$(python3 "$RESOLVER" --secrets-dir "$missing_ctx" --env compose 2>&1)"
assert_contains "missing context ref names the ref and the context" \
  "unresolved context ref '{{nope.here}}'" "$err"

err="$(env -u DEMO_SECRET python3 "$RESOLVER" --secrets-dir "$TMP" --env aws --tf-outputs "$TF" 2>&1)"
assert_contains "missing env var names the variable" \
  "environment variable 'DEMO_SECRET' is not set" "$err"

err="$(DEMO_SECRET=s python3 "$RESOLVER" --secrets-dir "$TMP" --env aws 2>&1)"
assert_contains "missing --tf-outputs is actionable" \
  "terraform output 'rds_primary_endpoint'" "$err"

nofile="$TMP/nofile"; mkdir -p "$nofile/contexts"
printf 'k: "<file:absent.txt>"\n' > "$nofile/demo.yaml"
printf 'userCredDelivery: envfrom\n' > "$nofile/contexts/compose.yaml"
err="$(python3 "$RESOLVER" --secrets-dir "$nofile" --env compose 2>&1)"
assert_contains "missing <file:> ref names the path" \
  "file ref 'absent.txt' not found" "$err"

# 11. a failing resolve emits NOTHING on stdout (no partial output)
outonly="$(python3 "$RESOLVER" --secrets-dir "$missing_ctx" --env compose 2>/dev/null)"
assert_eq "failed resolve writes nothing to stdout" "" "$outonly"

# 12. --stub-env resolves with NO credentials in the environment. This is what
#     lets secrets-validate.sh run in CI with nothing configured; without it,
#     validating the aws tree would demand a real PayPal secret.
out_stub="$(env -u DEMO_SECRET python3 "$RESOLVER" --secrets-dir "$TMP" \
             --env aws --tf-outputs "$TF" --stub-env 2>&1)"
assert_eq "--stub-env substitutes a placeholder for an unset variable" \
  "<stub:DEMO_SECRET>" "$(jq -r '.demo["user.key"]' <<<"$out_stub")"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
