"""Shared helpers for the golden-capture shims.

Every fake binary in this directory (docker, kubectl, mc, aws, mysql,
mongoimport, mongosh, terraform) imports this module. It owns:

  - append-only JSONL logging to $SEED_CAPTURE_DIR/<name>.log
  - the "is this a schema-existence read or a row-count read" classifier
    that keeps every old script on its "not yet seeded" branch
  - argv/URI redaction so a resolved DB password never lands in a log file
  - the `mc` subcommand handler shared between the `docker` shim (compose's
    `docker run --entrypoint mc ...` wrapper) and the standalone `mc` shim
    (k8s's 05-minio-bootstrap Job, which runs `mc` bare inside its pod)

See deploy/seed/tests/capture-golden.sh for the orchestration and
deploy/seed/tests/assemble-golden.py for how these logs become golden/<env>.json.
"""
import json
import os
import re
import sys


def capture_dir():
    d = os.environ.get("SEED_CAPTURE_DIR")
    if not d:
        sys.stderr.write("SEED_CAPTURE_DIR must be set\n")
        sys.exit(1)
    return d


def log_record(logname, record):
    path = os.path.join(capture_dir(), f"{logname}.log")
    with open(path, "a") as f:
        f.write(json.dumps(record) + "\n")


def redact_argv(argv):
    """Mask password-bearing tokens before they ever touch a log file."""
    out = []
    mask_next = False
    for tok in argv:
        if mask_next:
            out.append("***")
            mask_next = False
            continue
        if tok == "-p" or tok == "-u":
            out.append(tok)
            mask_next = True
            continue
        if re.match(r"^-p.+", tok):
            out.append("-p***")
            continue
        if tok.startswith("--env=MYSQL_PWD="):
            out.append("--env=MYSQL_PWD=***")
            continue
        out.append(redact_uri(tok))
    return out


def redact_uri(s):
    """Mask user:pass@ credentials embedded in a connection string."""
    return re.sub(r"//[^/@\s]+@", "//***@", s)


def classify_query(query):
    """Decide what a guarded SELECT should appear to return.

    Two shapes appear across every old seed script:
      - "does table X exist" (information_schema.tables) — must read as
        TRUE, or scripts that gate inventory seeding on it (compose's
        mysql-inventory-products.sh, k8s-inventory.sh, aws's
        seed-inventory.sh preflight) take their early-exit/"not ready"
        branch and the golden's mysql array comes back empty.
      - "how many rows are already in table X" (any other SELECT COUNT) —
        must read as EMPTY/zero, so the script takes the "not yet seeded"
        branch and performs the write, recording full intent rather than
        a partial re-run.
    """
    q = query.lower()
    if "information_schema.tables" in q:
        # "2" satisfies every existing caller: single-table existence checks
        # compare `-eq 0` (anything nonzero passes), and aws's
        # seed-inventory.sh checks BOTH tables at once with `-lt 2`.
        return "2"
    return ""


def classify_mongosh_eval(script):
    """Return {"action": ..., "collection": ..., "stdout": ...} for a
    mongosh --eval script, without ever touching a real mongod.
    """
    if ".drop()" in script:
        m = re.search(r"db\.(\w+)\.drop\(\)", script)
        return {
            "action": "drop",
            "collection": m.group(1) if m else None,
            "stdout": "",
        }
    if "isWritablePrimary" in script:
        return {"action": "none", "collection": None, "stdout": "true"}
    if "ping" in script.lower():
        return {"action": "none", "collection": None, "stdout": ""}
    if "imageUrl" in script and "forEach" in script:
        return {
            "action": "rewrite",
            "collection": "product",
            "stdout": "imageUrl host rewritten to media.microecom.local",
        }
    if "OK" in script and "FAIL" in script:
        # post-import verification: "<a> <b> <c> OK" — case *OK) in seed.sh
        return {"action": "none", "collection": None, "stdout": "1 1 1 OK"}
    if "countDocuments" in script:
        return {"action": "none", "collection": None, "stdout": ""}
    return {"action": "none", "collection": None, "stdout": ""}


def mc_object_key_from_cp(args):
    """`mc cp ... local/<bucket>/<key>` -> "<key>". Falls back to the raw
    last arg if it doesn't match the local/<bucket>/ shape."""
    last = args[-1]
    m = re.match(r"^local/[^/]+/(.*)$", last)
    return m.group(1) if m else last


def handle_mc_args(logname, mc_args):
    """Shared `mc <subcommand> ...` behaviour for the docker-wrapped and
    standalone mc shims. Returns process exit code; may append records.
    """
    if not mc_args:
        return 0
    sub = mc_args[0]
    if sub == "stat":
        # Deliberately "not found": empty stdout + exit 1 makes the
        # idempotency check in minio-product-images.sh / k8s-product-images.sh
        # treat every object as missing, so the real `mc cp` always runs and
        # the capture records every object key.
        return 1
    if sub == "cp":
        key = mc_object_key_from_cp(mc_args)
        log_record(logname, {"kind": "object", "key": key})
        return 0
    # alias/mb/anonymous/etc: no data captured, just succeed.
    return 0


def load_json_array(path):
    with open(path) as f:
        return json.load(f)
