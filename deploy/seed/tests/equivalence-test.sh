#!/usr/bin/env bash
# Layer A — offline equivalence between the OLD per-env seed goldens
# (deploy/seed/tests/golden/<env>.json, captured from the REAL compose/k8s/
# aws seed scripts via fake PATH shims — Task 1) and the NEW pure renderer's
# output for the same env (deploy/scripts/lib/seed_render.py::render_all —
# Task 3). See docs/superpowers/specs/2026-08-08-canonical-seed-design.md
# §5 "Layer A".
#
#   ./deploy/seed/tests/equivalence-test.sh
#
# This is the ONLY verification the `aws` env ever gets: it cannot be run
# without an account and spend, so its correctness rests entirely on this
# offline comparison. aws's golden was captured with a fake `aws` on PATH
# (Task 1); here, `--tf-outputs` equivalent (load_tf_outputs against
# fixtures/terraform-outputs.json) resolves its <terraform:...> refs — no
# real `terraform` is ever invoked, same technique as render-test.sh.
#
# 3 envs x 5 artifact keys (mysql, mongo, objects, drop, reconcile) = 15
# comparisons. This phase deliberately changes behaviour in exactly two of
# them, both under compose (see DECLARED below); every other comparison
# must match the golden exactly. Gate: 13 matched, 2 declared-different,
# 0 unexplained.
#
# DECLARED entries are asserted to differ IN THE STATED DIRECTION, and the
# run FAILS if a declared entry ever matches again. That is what separates
# a declared table from an exclusion list: an exclusion list would let an
# intended improvement silently revert without anyone noticing.
#
# On mismatch this prints WHICH keys differ and how many entries — never
# the full blob (30-row dumps bury the signal). Matches the house style of
# render-test.sh and deploy/secrets/tests/equivalence-test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SEED_DIR="$ROOT/deploy/seed"
GOLDEN_DIR="$HERE/golden"
TF_FIXTURE="$HERE/fixtures/terraform-outputs.json"

python3 - "$ROOT" "$SEED_DIR" "$GOLDEN_DIR" "$TF_FIXTURE" <<'PY'
import json, sys, pathlib

root, seed_dir, golden_dir, tf_fixture = (pathlib.Path(a) for a in sys.argv[1:5])
sys.path.insert(0, str(root / "deploy/scripts/lib"))
import seed_render as sr

GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"

ENVS = sr.ENVS
KEYS = ("mysql", "mongo", "objects", "drop", "reconcile")

# The property this phase changes on purpose (approved before execution --
# see seed_render.py's RECONCILE_DEFAULT / REPLACE_COLLECTIONS comments and
# design doc §5). Keyed by (env, key) -> (old, new): `old` is what the
# golden (captured from the real old script) holds, `new` is what
# render_all() must now produce.
#
#   compose/reconcile: compose's old script never restarted inventory-
#   service after seeding, so Redis's available:{productId} counters were
#   never rebuilt from the freshly-seeded ledger -- that absence IS the
#   documented "cart shows 0 available" bug. render_all() closes it by
#   making the restart env-invariant.
#   compose/drop: the old compose path unconditionally dropped `product`/
#   `productQuantityHistory` before importing -- a seed that silently wipes
#   local product edits is a bad default, so render_all() defaults to no
#   drop and moves the old behaviour behind an explicit --replace opt-in.
#
# k8s and aws are NOT in this table: their old scripts already restarted
# inventory-service post-seed and never dropped the collections, so their
# goldens already match render_all()'s new-intent defaults exactly -- only
# compose's old behaviour differed from the new default.
DECLARED = {
    ("compose", "drop"): (["product", "productQuantityHistory"], []),
    ("compose", "reconcile"): ([], ["restart:inventory-service"]),
}


def canon(key, value):
    """Sort (and, for mysql/objects, dedupe) both sides identically so
    import-order / capture-order never masquerades as a content diff --
    mirrors assemble-golden.py's and render_all()'s own sorting."""
    if key in ("mysql", "objects"):
        return sorted(set(value))
    if key in ("drop", "reconcile"):
        return sorted(value)
    if key == "mongo":
        return {
            coll: sorted(docs, key=lambda d: json.dumps(d, sort_keys=True))
            for coll, docs in value.items()
        }
    raise ValueError(key)


def compact(value):
    """['product','productQuantityHistory'] -- no space after the comma, so
    a declared-different pair's old/new columns line up under diff."""
    if isinstance(value, list):
        return "[" + ",".join(repr(v) for v in value) + "]"
    return repr(value)


def list_diff_summary(golden, rendered, limit=3):
    only_g = sorted(set(golden) - set(rendered))
    only_r = sorted(set(rendered) - set(golden))
    parts = []
    if only_g:
        sample = ", ".join(only_g[:limit])
        more = f" (+{len(only_g) - limit} more)" if len(only_g) > limit else ""
        parts.append(f"{len(only_g)} only in golden: {sample}{more}")
    if only_r:
        sample = ", ".join(only_r[:limit])
        more = f" (+{len(only_r) - limit} more)" if len(only_r) > limit else ""
        parts.append(f"{len(only_r)} only in rendered: {sample}{more}")
    return "; ".join(parts) if parts else "(same elements, different structure?)"


def mongo_diff_summary(golden, rendered, limit=3):
    cols = sorted(set(golden) | set(rendered))
    lines = []
    for c in cols:
        g, r = golden.get(c, []), rendered.get(c, [])
        if g == r:
            continue
        gk = {json.dumps(d, sort_keys=True) for d in g}
        rk = {json.dumps(d, sort_keys=True) for d in r}
        only_g, only_r = len(gk - rk), len(rk - gk)
        lines.append(f"{c}: {len(g)} golden docs, {len(r)} rendered docs "
                     f"({only_g} only-golden, {only_r} only-rendered)")
    return "; ".join(lines) if lines else "(no per-collection diff found)"


results = []  # (env, key, status, detail)
for env in ENVS:
    golden = json.loads((golden_dir / f"{env}.json").read_text())
    tf_outputs = sr.load_tf_outputs(str(tf_fixture)) if env == "aws" else None
    try:
        rendered = sr.render_all(str(seed_dir), env, tf_outputs)
    except sr.RenderError as exc:
        for key in KEYS:
            results.append((env, key, "FAIL", f"renderer errored: {exc}"))
        continue

    for key in KEYS:
        g = canon(key, golden[key])
        r = canon(key, rendered[key])
        declared = DECLARED.get((env, key))
        equal = g == r

        if declared is None:
            if equal:
                results.append((env, key, "matched", None))
            else:
                if key == "mongo":
                    detail = mongo_diff_summary(golden[key], rendered[key])
                else:
                    detail = list_diff_summary(g, r)
                results.append((env, key, "FAIL", f"unexplained difference: {detail}"))
        else:
            old, new = declared
            if equal:
                results.append((env, key, "FAIL",
                    f"regression: declared to differ ({compact(old)} -> {compact(new)}) "
                    f"but golden and rendered now MATCH -- the fix may have reverted"))
            elif g == canon(key, old) and r == canon(key, new):
                results.append((env, key, "declared-different", (old, new)))
            else:
                results.append((env, key, "FAIL",
                    f"declared entry doesn't match reality: golden={compact(g)} "
                    f"rendered={compact(r)} (documented as {compact(old)} -> {compact(new)})"))

# --- report ---------------------------------------------------------------
matched = sum(1 for _, _, s, _ in results if s == "matched")
declared_n = sum(1 for _, _, s, _ in results if s == "declared-different")
failed = [r for r in results if r[2] == "FAIL"]

declared_rows = [r for r in results if r[2] == "declared-different"]
if declared_rows:
    key_w = max(len(f"{e}/{k}") for e, k, _, _ in declared_rows) + 2
    old_w = max(len(compact(d[0])) for _, _, _, d in declared_rows) + 1
    for env, key, _, (old, new) in declared_rows:
        label = f"{env}/{key}".ljust(key_w)
        old_s = compact(old).ljust(old_w)
        print(f"declared-different: {label}{old_s}-> {compact(new)}")

for env, key, status, detail in failed:
    print(f"{RED}FAIL{RESET} {env}/{key}: {detail}")

summary = f"{matched} matched, {declared_n} declared-different, {len(failed)} unexplained"
status = f"{GREEN}PASS{RESET}" if not failed else f"{RED}FAIL{RESET}"
print(f"{summary}    -> {status}")

sys.exit(0 if not failed else 1)
PY
