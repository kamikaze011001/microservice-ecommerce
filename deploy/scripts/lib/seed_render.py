#!/usr/bin/env python3
"""Render canonical seed data (deploy/seed/*) + an env context into the
concrete artifacts the OLD per-env seed scripts used to hand-write.

Pure function of (canonical files + env context + an optional terraform
outputs file). No network, no subprocess to a backend, no cluster access —
see docs/superpowers/specs/2026-08-08-canonical-seed-design.md §4. The
transport step (docker exec / kubectl / aws s3 / ...) is deliberately NOT
here; that is deploy/scripts/seed.sh's job (Phase 5 Task 5/6).

Deliberately mirrors deploy/scripts/lib/secrets_resolve.py:
    {{ctx.ref}}        the env context file (deploy/seed/contexts/<env>.yaml)
    <terraform:name>   the terraform outputs cache — CONTEXT files only
A failed render prints NOTHING to stdout — same rule, same reason: a caller
redirecting stdout to a file must never get a partial artifact set.

Output shape (deploy/seed/tests/golden/<env>.json, five keys — the render_all
docstring in task-3-brief.md only lists four; a `drop` key was added to the
captured shape after the plan was written and every golden carries it):

    {"mysql": [...], "mongo": {...}, "objects": [...],
     "drop": [...], "reconcile": [...]}

"mysql" and "objects" are sorted+deduped arrays (mirrors
deploy/seed/tests/assemble-golden.py's `sorted(set(...))` — the golden is a
SET of statements, not the literal mysqldump byte stream, which is why a
mysqldump's DISABLE/ENABLE KEYS pairs land sorted next to each other rather
than interleaved per-table). "mongo" is collection -> list of docs sorted by
the doc's own canonical JSON, same reasoning as the array sort: import order
must not masquerade as a content difference.

"mysql"/"mongo"/"objects" reproduce the OLD per-env goldens exactly — that's
the equivalence Task 4 checks. "drop"/"reconcile" deliberately do NOT: they
encode this phase's approved new intent instead (see RECONCILE_DEFAULT /
REPLACE_COLLECTIONS below), so Task 4's diff against golden/<env>.json is
expected to show exactly those two differences and no others.
"""
import argparse
import json
import pathlib
import re
import sys

import yaml

CTX_REF = re.compile(r"\{\{ctx\.([A-Za-z_][A-Za-z0-9_]*)\}\}")
TF_REF = re.compile(r"^<terraform:([^>]+)>$")
ENVS = ("compose", "k8s", "aws")

# The four canonical source files under deploy/seed/. `--only <name>` renders
# exactly one of these and prints its raw (ctx-substituted) text — no JSON
# wrapper — which is also what the standing byte-for-byte compose/
# docker/product.json invariant needs (see render-test.sh).
RAW_FILES = (
    "product.json",
    "product-quantity-history.json",
    "ecommerce.sql",
    "api_role.json",
)

# --- Intentional divergence from the OLD-path goldens (approved before this
# task's execution began; see task-3-report.md's "post-review change" note).
# `drop`/`reconcile` are NEW INTENT, not a reproduction of old per-env
# behaviour — the opposite of how mysql/mongo/objects work in this file.
#
# reconcile: scripts/seed/k8s-inventory.sh and scripts/aws/up-all.sh step 8
# restart inventory-service after seeding so AvailableStockSeeder rebuilds
# the Redis available:{productId} counters from the freshly-seeded ledger
# (design doc §D3). The OLD compose path never did this — that absence IS
# the documented "cart shows 0 available" bug (every order fails
# "Insufficient available stock" because the counters are never rebuilt).
# The new renderer closes that gap by making the restart env-INVARIANT: the
# same token for every env, no `if env == ...` branch. seed.sh (Task 5/6)
# maps the token to the env-appropriate restart mechanism.
RECONCILE_DEFAULT = ["restart:inventory-service"]

# drop: scripts/seed/mongo-products.sh and mongo-product-quantity.sh
# unconditionally `db.<collection>.drop()` before importing — compose ONLY,
# old behaviour. A seed that silently wipes local product edits is a bad
# default (design doc §7 Risks), so the new renderer defaults `drop` to []
# for every env and moves the old compose behaviour behind an explicit
# `replace` opt-in (--replace) — flag-driven, not env-driven, so there is no
# per-env branch here either.
REPLACE_COLLECTIONS = ["product", "productQuantityHistory"]


class RenderError(Exception):
    pass


def _fail(where, key, message):
    raise RenderError(f"{where}: key '{key}': {message}")


def load_tf_outputs(path):
    """Read a `terraform output -json` shaped file into {name: value}."""
    if path is None:
        return None
    data = json.loads(pathlib.Path(path).read_text())
    return {k: v["value"] if isinstance(v, dict) and "value" in v else v
            for k, v in data.items()}


def load_context(seed_dir, env, tf_outputs=None):
    """Load contexts/<env>.yaml, resolving <terraform:…> refs in its values."""
    path = seed_dir / "contexts" / f"{env}.yaml"
    if not path.exists():
        raise RenderError(f"context file not found: {path}")
    raw = yaml.safe_load(path.read_text()) or {}
    where = f"contexts/{env}.yaml"
    out = {}
    for key, value in raw.items():
        value = "" if value is None else str(value)
        match = TF_REF.match(value)
        if match:
            name = match.group(1)
            if tf_outputs is None or name not in tf_outputs:
                _fail(
                    where,
                    key,
                    f"terraform output '{name}' is not available — "
                    f"run 'terraform apply' or pass --tf-outputs",
                )
            out[key] = str(tf_outputs[name])
        else:
            out[key] = value
    return out


def _substitute(text, where, context):
    def ctx(m):
        name = m.group(1)
        if name not in context:
            _fail(where, name,
                  f"unresolved context ref '{{{{ctx.{name}}}}}' — "
                  f"not defined in the env context")
        return context[name]

    return CTX_REF.sub(ctx, text)


def render_raw_file(seed_dir, filename, context):
    """Render one canonical file's raw text ({{ctx.…}} substituted). Used
    both for --only and as the source for the derived artifacts below."""
    if filename not in RAW_FILES:
        raise RenderError(
            f"unknown canonical file '{filename}' — expected one of {RAW_FILES}")
    path = seed_dir / filename
    if not path.exists():
        raise RenderError(f"canonical file not found: {path}")
    return _substitute(path.read_text(), filename, context)


def _escape_sql(value):
    # Mirrors the old generators' jq: gsub("\""; "\\\"") — backslash-escape a
    # literal double quote, nothing else. See scripts/aws/seed-inventory.sh
    # and scripts/seed/mysql-inventory-products.sh.
    return value.replace('"', '\\"')


def _statements_from_blob(blob):
    """One entry per *mutating* statement — mirrors assemble-golden.py's
    statements_from_blob(): comment-only lines and bare SELECTs are dropped."""
    out = []
    for line in blob.splitlines():
        line = line.strip()
        if not line or line.startswith("--"):
            continue
        if line.upper().startswith("SELECT"):
            continue
        out.append(line)
    return out


def _generated_statements(products, qty_rows, context):
    """The two derived-inventory tables (inventory_product,
    product_quantity_history), synthesised from product.json /
    product-quantity-history.json — NOT part of the ecommerce.sql dump.
    generatedInsertMode governs ONLY these two tables (contexts/*.yaml)."""
    verb = context.get("generatedInsertMode")
    if verb not in ("INSERT", "INSERT IGNORE"):
        _fail("contexts/<env>.yaml", "generatedInsertMode",
              f"must be 'INSERT' or 'INSERT IGNORE', got {verb!r}")

    stmts = []
    for product in products:
        pid = product["_id"]["$oid"]
        name = _escape_sql(product["name"])
        price = product["price"]
        # Matches scripts/seed/mysql-inventory-products.sh's `if .imageUrl
        # then ... else NULL end` — jq falsy is only null/false, so this is a
        # missing/null check, not an empty-string check. But an empty-string
        # imageUrl is exactly where compose's jq and scripts/aws/
        # seed-inventory.sh's stricter `(.imageUrl // "" | length) > 0`
        # disagree (compose: quoted "", aws: NULL). None of the 30 canonical
        # products hit this, so — same precedent as the mediaBaseUrl boundary
        # check in _objects() below — fail loudly instead of silently picking
        # one env's semantics for all three. Normalising here would be an
        # undeclared third behavioural change beyond this phase's approved
        # compose/drop + compose/reconcile pair (see the module docstring),
        # for an input no current data produces.
        image_url = product.get("imageUrl")
        if image_url == "":
            _fail("product.json", product.get("_id", {}).get("$oid", "<unknown>"),
                  "imageUrl is an empty string — compose's old jq quotes it "
                  "as \"\", aws's old jq treats it as NULL; the renderer "
                  "refuses to guess which semantics wins across all three "
                  "envs. Give the product a real imageUrl or make it null "
                  "and re-render.")
        image_expr = "NULL" if image_url is None else f'"{_escape_sql(image_url)}"'
        stmts.append(
            f"{verb} INTO inventory_product (id, name, price, image_url) VALUES "
            f'("{pid}", "{name}", {price}, {image_expr});'
        )

    for row in qty_rows:
        # "2026-05-03T00:00:00Z" -> "2026-05-03 00:00:00", mirroring jq's
        # `sub("Z$"; "") | sub("T"; " ")` — strip a trailing Z, then replace
        # only the FIRST "T" (Python .replace(..., 1) matches jq sub()'s
        # single-match semantics).
        created = row["createdAt"]["$date"]
        created_sql = re.sub(r"Z$", "", created).replace("T", " ", 1)
        stmts.append(
            f"{verb} INTO product_quantity_history "
            f"(id, product_id, quantity, created_at) VALUES "
            f'("{row["_id"]}", "{row["productId"]}", {row["quantity"]}, '
            f'"{created_sql}");'
        )
    return stmts


def _sorted_docs(docs):
    return sorted(docs, key=lambda d: json.dumps(d, sort_keys=True))


def _objects(products, context):
    base = context.get("mediaBaseUrl", "")
    keys = set()
    for product in products:
        url = product.get("imageUrl")
        if not url:
            continue
        if not base or not url.startswith(base):
            _fail("product.json", "imageUrl",
                  f"rendered imageUrl '{url}' does not start with "
                  f"mediaBaseUrl '{base}' — the {{{{ctx.mediaBaseUrl}}}} "
                  f"boundary assumption (design doc §D2) does not hold")
        keys.add(url[len(base):].lstrip("/"))
    return sorted(keys)


def render_all(seed_dir, env, tf_outputs=None, only=None, replace=False):
    """Canonical data + context -> the five-key artifact dict, OR — when
    `only` names one of RAW_FILES — {"file": only, "text": <rendered text>}
    (the CLI prints `text` verbatim, no wrapper: see --only below). Pure: no
    network, no backend.

    `replace=True` opts into the old compose behaviour of dropping the
    `product`/`productQuantityHistory` Mongo collections before import
    (REPLACE_COLLECTIONS); default is `drop: []` for every env. `reconcile`
    is RECONCILE_DEFAULT for every env regardless of `replace` — see the
    module docstring block above RECONCILE_DEFAULT for why."""
    seed_dir = pathlib.Path(seed_dir)
    if env not in ENVS:
        raise RenderError(f"unknown env '{env}' — expected one of {ENVS}")
    context = load_context(seed_dir, env, tf_outputs)

    if only is not None:
        return {"file": only, "text": render_raw_file(seed_dir, only, context)}

    products = json.loads(render_raw_file(seed_dir, "product.json", context))
    qty_rows = json.loads(render_raw_file(seed_dir, "product-quantity-history.json", context))
    api_roles = json.loads(render_raw_file(seed_dir, "api_role.json", context))

    dump_statements = _statements_from_blob(
        render_raw_file(seed_dir, "ecommerce.sql", context))
    generated_statements = _generated_statements(products, qty_rows, context)
    mysql = sorted(set(dump_statements + generated_statements))

    mongo = {
        "api_role": _sorted_docs(api_roles),
        "product": _sorted_docs(products),
        "productQuantityHistory": _sorted_docs(qty_rows),
    }

    return {
        "mysql": mysql,
        "mongo": mongo,
        "objects": _objects(products, context),
        "drop": list(REPLACE_COLLECTIONS) if replace else [],
        "reconcile": list(RECONCILE_DEFAULT),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True, choices=ENVS)
    ap.add_argument("--seed-dir", default="deploy/seed", type=pathlib.Path)
    ap.add_argument("--tf-outputs")
    ap.add_argument("--only",
                     help="render exactly one canonical file "
                          f"({', '.join(RAW_FILES)}) and print it verbatim")
    ap.add_argument("--replace", action="store_true",
                     help="opt into dropping product/productQuantityHistory "
                          "before import (old compose behaviour); default is "
                          "no drop for every env")
    args = ap.parse_args()

    try:
        result = render_all(
            args.seed_dir, args.env, load_tf_outputs(args.tf_outputs), args.only,
            args.replace,
        )
    except RenderError as exc:
        # stderr only — a failed render must emit NOTHING on stdout, so a
        # caller redirecting stdout to a file never gets a partial artifact.
        print(f"seed-render: {exc}", file=sys.stderr)
        return 1

    if args.only is not None:
        sys.stdout.write(result["text"])
    else:
        print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
