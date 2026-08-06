#!/usr/bin/env python3
"""Resolve canonical secret files into a flat per-service map.

Pure function of (canonical YAML + env context + process environment). Never
touches a network, a backend, or a cluster — that separation is what lets the
AWS path be verified offline and lets validation run in CI with no credentials.

Output shape matches deploy/secrets/tests/golden/<env>.json exactly:
    {"<service>": {"<dotted.key>": "<value>"}}

Three reference syntaxes, deliberately distinct so a failure can name which
kind of input is missing:
    {{ctx.ref}}        the env context file      — canonical files only
    ${ENV_VAR}         the process environment   — canonical files only
    <file:name>        a file under the secrets dir — canonical files only
    <terraform:name>   the terraform outputs cache — CONTEXT files only
"""
import argparse
import json
import os
import pathlib
import re
import sys

import yaml

CTX_REF = re.compile(r"\{\{([^}]+)\}\}")
ENV_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
FILE_REF = re.compile(r"^<file:([^>]+)>$")
TF_REF = re.compile(r"^<terraform:([^>]+)>$")

ENVS = ("compose", "k8s", "aws")
RESERVED_CONTEXT_KEYS = {"userCredDelivery"}


class ResolveError(Exception):
    pass


def _fail(where, key, message):
    raise ResolveError(f"{where}: key '{key}': {message}")


def load_context(secrets_dir, env, tf_outputs=None):
    """Load contexts/<env>.yaml, resolving <terraform:…> refs in its values."""
    path = secrets_dir / "contexts" / f"{env}.yaml"
    if not path.exists():
        raise ResolveError(f"context file not found: {path}")
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


def load_tf_outputs(path):
    """Read a `terraform output -json` shaped file into {name: value}."""
    if path is None:
        return None
    data = json.loads(pathlib.Path(path).read_text())
    return {k: v["value"] if isinstance(v, dict) and "value" in v else v
            for k, v in data.items()}


def _entry(raw, key, where):
    """Normalise a canonical value into (value, envs_or_None, owner)."""
    if isinstance(raw, dict):
        if "value" not in raw:
            _fail(where, key, "expanded entry is missing 'value'")
        return str(raw["value"]), raw.get("envs"), raw.get("owner", "config")
    return ("" if raw is None else str(raw)), None, "config"


def _substitute(value, key, where, context, secrets_dir, stub_env=False):
    match = FILE_REF.match(value)
    if match:
        target = secrets_dir / match.group(1)
        if not target.exists():
            _fail(where, key,
                  f"file ref '{match.group(1)}' not found under {secrets_dir}")
        return target.read_text()

    def ctx(m):
        name = m.group(1)
        if name not in context:
            _fail(where, key,
                  f"unresolved context ref '{{{{{name}}}}}' — "
                  f"not defined in the env context")
        return context[name]

    def env(m):
        name = m.group(1)
        # stub_env is what lets secrets-validate.sh run with NO credentials
        # configured: it checks structure, not values, so a real PayPal secret
        # must not be a precondition for validating the tree. Seeding never
        # uses it — an unset variable there is a hard failure, as it must be.
        if stub_env:
            return f"<stub:{name}>"
        if name not in os.environ:
            _fail(where, key, f"environment variable '{name}' is not set")
        return os.environ[name]

    return ENV_REF.sub(env, CTX_REF.sub(ctx, value))


def resolve_service(secrets_dir, service, env, context, stub_env=False):
    path = secrets_dir / f"{service}.yaml"
    raw = yaml.safe_load(path.read_text()) or {}
    where = path.name
    out = {}
    for key, rawval in raw.items():
        value, envs, owner = _entry(rawval, key, where)
        if envs is not None and env not in envs:
            continue
        if owner == "user" and context.get("userCredDelivery") != "backend":
            continue
        out[key] = _substitute(value, key, where, context, secrets_dir, stub_env)
    return out


def service_names(secrets_dir):
    return sorted(p.stem for p in secrets_dir.glob("*.yaml"))


def resolve_all(secrets_dir, env, tf_outputs=None, only=None, stub_env=False):
    context = load_context(secrets_dir, env, tf_outputs)
    names = [only] if only else service_names(secrets_dir)
    return {name: resolve_service(secrets_dir, name, env, context, stub_env)
            for name in names}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True, choices=ENVS)
    ap.add_argument("--secrets-dir", default="deploy/secrets", type=pathlib.Path)
    ap.add_argument("--service")
    ap.add_argument("--tf-outputs")
    ap.add_argument("--stub-env", action="store_true",
                    help="replace ${VAR} with <stub:VAR> instead of reading the "
                         "environment; for validation, never for seeding")
    args = ap.parse_args()

    try:
        result = resolve_all(
            args.secrets_dir, args.env,
            load_tf_outputs(args.tf_outputs), args.service, args.stub_env,
        )
    except ResolveError as exc:
        # stderr only — a failed resolve must emit NOTHING on stdout, so a
        # caller redirecting stdout to a file never gets a partial map.
        print(f"secrets-resolve: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
