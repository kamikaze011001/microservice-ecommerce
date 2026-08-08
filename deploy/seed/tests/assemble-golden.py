#!/usr/bin/env python3
"""Turn one env's raw shim logs into golden/<env>.json.

Reads every $capture_dir/*.log (one JSONL record per shim invocation that
mattered — see shims/_lib.py for the record "kind"s) and folds them into the
five-key shape from task-1-brief.md:

    {"mysql": [...], "mongo": {...}, "objects": [...], "drop": [...], "reconcile": [...]}

`drop`/`reconcile` are operations (captured deliberately, per the brief);
`mysql`/`objects` are sorted+deduped arrays; `mongo` is collection -> sorted
list of documents (sorted by their own JSON so import-order differences don't
masquerade as content differences, same reasoning as the array sort).
"""
import argparse
import glob
import json
import pathlib


def statements_from_blob(blob):
    """One golden entry per *mutating* statement in a captured mysql stdin
    stream. Comment-only lines are dropped, and so are bare SELECTs — aws's
    seed-inventory.sh pipes a `SELECT CONCAT("inventory_product=", ...)`
    verification query into the same mysql session as its INSERTs (proof-of-
    write row counts, not data), and that line contains the substring
    "inventory_product" — counting it would inflate the INSERT count task-1-
    brief.md Step 3 checks. "mysql" here is "what got written"; a read isn't
    a write regardless of which table it names.
    """
    out = []
    for line in blob.splitlines():
        line = line.strip()
        if not line or line.startswith("--"):
            continue
        if line.upper().startswith("SELECT"):
            continue
        out.append(line)
    return out


def load_records(capture_dir):
    records = []
    for path in sorted(glob.glob(str(pathlib.Path(capture_dir) / "*.log"))):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                records.append(json.loads(line))
    return records


def assemble(capture_dir):
    mysql = []
    mongo = {}
    objects = set()
    drop = set()
    reconcile = set()
    rewrites = []  # [(collection, pattern, replacement), ...]

    for rec in load_records(capture_dir):
        kind = rec.get("kind")
        if kind == "mysql_write":
            mysql.extend(statements_from_blob(rec["sql"]))
        elif kind == "mongo_import":
            mongo.setdefault(rec["collection"], []).extend(rec["docs"])
        elif kind == "object":
            objects.add(rec["key"])
        elif kind == "drop":
            if rec.get("collection"):
                drop.add(rec["collection"])
        elif kind == "reconcile":
            reconcile.add(rec["action"])
        elif kind == "rewrite":
            rewrites.append((rec["collection"], rec["pattern"], rec["replacement"]))
        elif kind == "raw":
            pass  # traceability only
        else:
            raise ValueError(f"unknown capture record kind: {kind!r}")

    # Apply post-hoc host rewrites (k8s's mongosh imageUrl UPDATE loop) to the
    # docs already captured from mongoimport, so the golden reflects the
    # state actually left in Mongo — not the pre-rewrite import payload.
    for collection, pattern, replacement in rewrites:
        for doc in mongo.get(collection, []):
            url = doc.get("imageUrl")
            if isinstance(url, str) and url.startswith(pattern):
                doc["imageUrl"] = replacement + url[len(pattern):]

    for collection in mongo:
        mongo[collection].sort(key=lambda d: json.dumps(d, sort_keys=True))

    return {
        "mysql": sorted(set(mysql)),
        "mongo": mongo,
        "objects": sorted(objects),
        "drop": sorted(drop),
        "reconcile": sorted(reconcile),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--capture-dir", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    result = assemble(args.capture_dir)
    out_path = pathlib.Path(args.out)
    out_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")

    print(
        f"{args.env}: mysql={len(result['mysql'])} "
        f"mongo={ {k: len(v) for k, v in result['mongo'].items()} } "
        f"objects={len(result['objects'])} drop={result['drop']} "
        f"reconcile={result['reconcile']} -> {out_path}"
    )


if __name__ == "__main__":
    main()
