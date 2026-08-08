#!/usr/bin/env bash
# Tests for deploy/scripts/lib/seed_render.py (Phase 5 Task 3 — the pure
# renderer). See docs/superpowers/specs/2026-08-08-canonical-seed-design.md
# §4/§5.
#
#   ./deploy/seed/tests/render-test.sh
#
# Test 0 is the standing invariant from §5/§D4: rendering deploy/seed/
# product.json for `compose` must reproduce docker/product.json
# byte-for-byte. It is the only thing that keeps deploy/seed/* (the
# canonical copy) and docker/* (kept byte-identical for its 20 existing
# consumers) from drifting apart silently.
#
# Tests 1-4 are the renderer's own unit tests (Task 3 brief, Step 1), one per
# hazard: row counts across all three envs, a missing {{ctx.…}} failing
# loudly with nothing on stdout, SQL-quote/NULL escaping matching the old
# jq generators, and `--only <file>` printing the file with no wrapper.
#
# Test 5 covers the one deliberate departure from golden equivalence: `drop`
# and `reconcile` encode this phase's NEW intent (approved before execution),
# not a reproduction of the old per-env scripts — see seed_render.py's
# RECONCILE_DEFAULT / REPLACE_COLLECTIONS comments.
#
# Test 6 covers a review finding: an empty-string imageUrl is the one case
# where compose's and aws's old jq disagree (quoted "" vs NULL). No current
# product hits it, so the renderer fails loudly rather than silently picking
# a winner for all three envs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RENDERER="$ROOT/deploy/scripts/lib/seed_render.py"
SEED_DIR="$ROOT/deploy/seed"
TF_FIXTURE="$ROOT/deploy/seed/tests/fixtures/terraform-outputs.json"
pass=0; fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# ── Test 0: compose/product.json byte-for-byte invariant ───────────────────
echo
echo -e "\033[1mseed render — compose/product.json byte-for-byte invariant\033[0m"

t0_out="$(mktemp)"
(cd "$ROOT" && python3 "$RENDERER" --env compose --only product.json) >"$t0_out" 2>&1
# NOTE: comparing via a temp file, not a `$(...)` variable — command
# substitution unconditionally strips trailing newlines, which would make
# this diff report a spurious "no newline at end of file" difference against
# docker/product.json (which does end in one) even when the renderer's raw
# stdout bytes are identical to the file. A `$()`-captured comparison here
# can never pass regardless of renderer correctness; that was a bug in this
# test, not the renderer — see task-3-report.md.
if diff "$t0_out" "$ROOT/docker/product.json" >/dev/null 2>&1; then
  ok "compose render reproduces docker/product.json byte-for-byte"
else
  bad "compose render differs from docker/product.json"
  printf '       renderer output (first 3 lines):\n'
  head -3 "$t0_out" | sed 's/^/         /'
fi
rm -f "$t0_out"

# ── Test 1: every env renders 30 inventory_product rows ────────────────────
echo
echo -e "\033[1mrender_all — every env renders 30 inventory_product rows\033[0m"

t1_out="$(cd "$ROOT" && python3 - <<PY
import json, sys
sys.path.insert(0, "deploy/scripts/lib")
import seed_render as sr

counts = {}
for env in sr.ENVS:
    tf_outputs = sr.load_tf_outputs("$TF_FIXTURE") if env == "aws" else None
    result = sr.render_all("$SEED_DIR", env, tf_outputs)
    counts[env] = sum(
        1 for s in result["mysql"]
        if s.startswith("INSERT") and "INTO inventory_product " in s
    )
print(json.dumps(counts))
sys.exit(0 if all(n == 30 for n in counts.values()) else 1)
PY
)"
t1_rc=$?
if [ "$t1_rc" -eq 0 ]; then
  ok "compose/k8s/aws each render 30 inventory_product rows ($t1_out)"
else
  bad "inventory_product row count mismatch: $t1_out"
fi

# ── Test 2: unresolved {{ctx.…}} fails loudly, nothing on stdout ───────────
echo
echo -e "\033[1mrender_all — unresolved {{ctx.X}} fails loudly with empty stdout\033[0m"

t2_dir="$(mktemp -d)"
cp -R "$SEED_DIR" "$t2_dir/seed"
python3 - "$t2_dir/seed/product.json" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
broken = text.replace("{{ctx.mediaBaseUrl}}", "{{ctx.missingKey}}", 1)
assert broken != text, "fixture setup: no {{ctx.mediaBaseUrl}} found to break"
p.write_text(broken)
PY
t2_stdout="$(mktemp)"; t2_stderr="$(mktemp)"
python3 "$RENDERER" --seed-dir "$t2_dir/seed" --env compose >"$t2_stdout" 2>"$t2_stderr"
t2_rc=$?
t2_stdout_bytes=$(wc -c < "$t2_stdout" | tr -d '[:space:]')
if [ "$t2_rc" -ne 0 ] && [ "$t2_stdout_bytes" -eq 0 ] \
   && grep -q "missingKey" "$t2_stderr" && grep -q "product.json" "$t2_stderr"; then
  ok "missing context key: nonzero exit, empty stdout, stderr names key + file"
else
  bad "missing context key: rc=$t2_rc stdout_bytes=$t2_stdout_bytes stderr=$(cat "$t2_stderr")"
fi
rm -rf "$t2_dir" "$t2_stdout" "$t2_stderr"

# ── Test 3: SQL quote-escaping and the NULL-imageUrl branch ────────────────
echo
echo -e "\033[1mrender_all — quote-escaping and NULL-imageUrl match the old jq generators\033[0m"

t3_dir="$(mktemp -d)"
cp -R "$SEED_DIR" "$t3_dir/seed"
t3_result="$(python3 - "$t3_dir/seed" <<'PY'
import json, pathlib, sys
sys.path.insert(0, "deploy/scripts/lib")
import seed_render as sr

seed_dir = pathlib.Path(sys.argv[1])
products = [
    {
        "_id": {"$oid": "aaaaaaaaaaaaaaaaaaaaaaaa"},
        "name": 'Say "Hi" Shirt',
        "price": 10,
        "imageUrl": "{{ctx.mediaBaseUrl}}/products/aaaa/say-hi-shirt.jpg",
    },
    {
        "_id": {"$oid": "bbbbbbbbbbbbbbbbbbbbbbbb"},
        "name": "No Image Product",
        "price": 20,
        # imageUrl deliberately absent.
    },
]
(seed_dir / "product.json").write_text(json.dumps(products, indent=2))
(seed_dir / "product-quantity-history.json").write_text("[]")

result = sr.render_all(seed_dir, "compose")
stmts = result["mysql"]

# gsub("\""; "\\\"") in the old jq generators: a literal `"` becomes `\"`,
# nothing else escaped. NULL branch: imageUrl missing/null -> NULL literal.
expect_quoted = (
    'INSERT INTO inventory_product (id, name, price, image_url) VALUES '
    '("aaaaaaaaaaaaaaaaaaaaaaaa", "Say \\"Hi\\" Shirt", 10, '
    '"http://localhost:9000/ecommerce-media/products/aaaa/say-hi-shirt.jpg");'
)
expect_null = (
    'INSERT INTO inventory_product (id, name, price, image_url) VALUES '
    '("bbbbbbbbbbbbbbbbbbbbbbbb", "No Image Product", 20, NULL);'
)

ok = expect_quoted in stmts and expect_null in stmts
if not ok:
    print("MISSING expected statement(s):", file=sys.stderr)
    if expect_quoted not in stmts:
        print("  quoted-name case not found. want:", file=sys.stderr)
        print("   ", expect_quoted, file=sys.stderr)
    if expect_null not in stmts:
        print("  NULL-imageUrl case not found. want:", file=sys.stderr)
        print("   ", expect_null, file=sys.stderr)
    print("  rendered inventory_product statements:", file=sys.stderr)
    for s in stmts:
        if "inventory_product" in s:
            print("   ", s, file=sys.stderr)
print("OK" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
)"
t3_rc=$?
if [ "$t3_rc" -eq 0 ]; then
  ok "embedded-quote name escapes to \\\" and missing imageUrl renders NULL"
else
  bad "escaping/NULL-branch mismatch: $t3_result"
fi
rm -rf "$t3_dir"

# ── Test 4: --only <file> emits exactly the file, no wrapper ───────────────
echo
echo -e "\033[1mrender_all — --only product.json emits the raw array, no wrapper\033[0m"

t4_out="$(cd "$ROOT" && python3 "$RENDERER" --env k8s --only product.json)"
t4_rc=$?
t4_check="$(printf '%s' "$t4_out" | python3 -c '
import json, sys
text = sys.stdin.read()
data = json.loads(text)
# "no wrapper" = the top-level value is the array itself (30 products), not
# an object like {"file": "product.json", "text": "..."}.
print("array" if isinstance(data, list) and len(data) == 30 else "not-array")
' 2>/dev/null)"
if [ "$t4_rc" -eq 0 ] && [ "$t4_check" = "array" ]; then
  ok "--only product.json prints the bare 30-element array, no wrapper object"
else
  bad "--only product.json: rc=$t4_rc parsed-as=$t4_check"
fi

# ── Test 5: drop/reconcile carry NEW intent, not the old goldens ───────────
# Approved before execution began: reconcile is env-invariant (the compose
# "0 available" bug — no post-seed reconcile — gets fixed here, not just
# documented), and drop defaults to [] everywhere (no silent collection wipe)
# with the old compose drop behaviour moved behind --replace. mysql/mongo/
# objects must still match the goldens exactly; only these two keys diverge.
echo
echo -e "\033[1mrender_all — reconcile is env-invariant, drop defaults empty, --replace opts in\033[0m"

t5_out="$(cd "$ROOT" && python3 - <<PY
import json, sys
sys.path.insert(0, "deploy/scripts/lib")
import seed_render as sr

problems = []
for env in sr.ENVS:
    tf_outputs = sr.load_tf_outputs("$TF_FIXTURE") if env == "aws" else None
    default = sr.render_all("$SEED_DIR", env, tf_outputs)
    replaced = sr.render_all("$SEED_DIR", env, tf_outputs, replace=True)

    if default["reconcile"] != ["restart:inventory-service"]:
        problems.append(f"{env}: default reconcile={default['reconcile']!r}")
    if default["drop"] != []:
        problems.append(f"{env}: default drop={default['drop']!r}, want []")
    if replaced["drop"] != ["product", "productQuantityHistory"]:
        problems.append(f"{env}: --replace drop={replaced['drop']!r}")
    if replaced["reconcile"] != ["restart:inventory-service"]:
        problems.append(f"{env}: --replace reconcile={replaced['reconcile']!r} (must be unaffected by replace)")
    # mysql/mongo/objects must be untouched by replace=True.
    for key in ("mysql", "mongo", "objects"):
        if default[key] != replaced[key]:
            problems.append(f"{env}: replace=True changed '{key}', it must not")

if problems:
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)
print("reconcile=['restart:inventory-service'] and drop=[] for all envs by default; --replace adds the two collections")
PY
)"
t5_rc=$?
if [ "$t5_rc" -eq 0 ]; then
  ok "$t5_out"
else
  bad "drop/reconcile new-intent check failed: $t5_out"
fi

# ── Test 6: empty-string imageUrl fails loudly, names the product id ───────
# compose's old jq (`if .imageUrl then …`) quotes an empty string as "";
# aws's old jq (`(.imageUrl // "" | length) > 0`) treats it as NULL. No
# canonical product hits this, so the renderer must refuse to silently pick
# one env's semantics for all three — same precedent as the mediaBaseUrl
# boundary check in _objects().
echo
echo -e "\033[1mrender_all — empty-string imageUrl fails loudly, names the product id\033[0m"

t6_dir="$(mktemp -d)"
cp -R "$SEED_DIR" "$t6_dir/seed"
t6_pid="cccccccccccccccccccccccc"
python3 - "$t6_dir/seed/product.json" "$t6_pid" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
pid = sys.argv[2]
products = json.loads(p.read_text())
products.append({"_id": {"$oid": pid}, "name": "Empty Image Product", "price": 1, "imageUrl": ""})
p.write_text(json.dumps(products, indent=2))
PY
t6_stdout="$(mktemp)"; t6_stderr="$(mktemp)"
python3 "$RENDERER" --seed-dir "$t6_dir/seed" --env compose >"$t6_stdout" 2>"$t6_stderr"
t6_rc=$?
t6_stdout_bytes=$(wc -c < "$t6_stdout" | tr -d '[:space:]')
if [ "$t6_rc" -ne 0 ] && [ "$t6_stdout_bytes" -eq 0 ] \
   && grep -q "$t6_pid" "$t6_stderr" && grep -q "product.json" "$t6_stderr"; then
  ok "empty-string imageUrl: nonzero exit, empty stdout, stderr names product id + file"
else
  bad "empty-string imageUrl: rc=$t6_rc stdout_bytes=$t6_stdout_bytes stderr=$(cat "$t6_stderr")"
fi
rm -rf "$t6_dir" "$t6_stdout" "$t6_stderr"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
