#!/usr/bin/env python3
"""Normalise the three captures into golden/<env>.json.

Output shape, identical for every env and for the resolver:
    {"<service>": {"<dotted.key>": "<value>"}}
sorted keys, 2-space indent, trailing newline.
"""
import argparse
import json
import pathlib

# scripts/vault/import-secrets.sh:41-51 — only ecommerce-common is renamed.
COMPOSE_PATHS = {
    "ecommerce-common.json": "ecommerce",
    "core-s3.json": "core-s3",
    "authorization-server.json": "authorization-server",
    "gateway.json": "gateway",
    "product-service.json": "product-service",
    "inventory-service.json": "inventory-service",
    "order-service.json": "order-service",
    "payment-service.json": "payment-service",
    "orchestrator-service.json": "orchestrator-service",
    "bff-service.json": "bff-service",
    "mock-paypal-service.json": "mock-paypal-service",
}


def compose_map(repo_root):
    """Read the compose JSON files, dropping `_comment*` pseudo-keys.

    Two of the JSON files use `_comment`-prefixed keys as inline documentation
    (JSON has no comment syntax), and import-secrets.sh POSTs the file verbatim
    — so four inert pseudo-keys are seeded into Vault today. The canonical YAML
    files carry that documentation as real YAML comments instead, which are not
    keys at all. Dropping them here is therefore a DELIBERATE, declared
    difference from the old path, not an oversight: Spring never reads a
    `_comment*` property. It is stripped loudly rather than silently so the
    equivalence diff stays a strict byte comparison of everything that matters.
    """
    cfg = repo_root / "docker" / "vault-configs"
    out = {}
    dropped = 0
    for filename, path in COMPOSE_PATHS.items():
        data = json.loads((cfg / filename).read_text())
        keep = {k: str(v) for k, v in data.items() if not k.startswith("_comment")}
        dropped += len(data) - len(keep)
        out[path] = keep
    print(f"compose: dropped {dropped} inert _comment* pseudo-keys")
    return out


def k8s_map(capture_dir):
    out = {}
    for line in (capture_dir / "vault-puts.tsv").read_text().splitlines():
        if not line:
            continue
        path, key, value = line.split("\t", 2)
        out.setdefault(path, {})[key] = value
    return out


def aws_map(capture_dir):
    out = {}
    for line in (capture_dir / "aws-puts.tsv").read_text().splitlines():
        if not line:
            continue
        service, payload = line.split("\t", 1)
        out.setdefault(service, {}).update(
            {k: str(v) for k, v in json.loads(payload).items()}
        )
    return out


def write(out_dir, name, mapping):
    path = out_dir / f"{name}.json"
    path.write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n")
    total = sum(len(v) for v in mapping.values())
    print(f"{name}: {len(mapping)} services, {total} keys -> {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True, type=pathlib.Path)
    ap.add_argument("--capture-dir", required=True, type=pathlib.Path)
    ap.add_argument("--out-dir", required=True, type=pathlib.Path)
    args = ap.parse_args()

    write(args.out_dir, "compose", compose_map(args.repo_root))
    write(args.out_dir, "k8s", k8s_map(args.capture_dir))
    write(args.out_dir, "aws", aws_map(args.capture_dir))


if __name__ == "__main__":
    main()
