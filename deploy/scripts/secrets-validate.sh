#!/usr/bin/env bash
# Consistency checks over deploy/secrets/. No backend, no credentials, no
# network — so this can run in CI (Phase 9) with nothing configured.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$ROOT/deploy/secrets"

# env → the .env.example that documents THAT env's user-owned credentials.
# Per-env, not a union: a variable documented in only one env's file is not
# documented for the other, and check 3 must be able to say so. Overridable so
# the test suite can point at a corrupted copy.
ENV_EXAMPLES="compose=$ROOT/docker/.env.example,k8s=$ROOT/k8s/.env.example"

while [ $# -gt 0 ]; do
  case "$1" in
    --secrets-dir)  SECRETS="$2"; shift 2 ;;
    --env-examples) ENV_EXAMPLES="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PYTHONPATH="$ROOT/deploy/scripts/lib" \
SECRETS_DIR="$SECRETS" \
TF_FIXTURE="$ROOT/deploy/secrets/tests/fixtures/terraform-outputs.json" \
ENV_EXAMPLES="$ENV_EXAMPLES" \
python3 - <<'PY'
import json, os, pathlib, re, sys
import yaml
from secrets_resolve import (CTX_REF, ENV_REF, TF_REF, ENVS,
                             RESERVED_CONTEXT_KEYS, load_tf_outputs,
                             resolve_all)

secrets = pathlib.Path(os.environ["SECRETS_DIR"])
tf = load_tf_outputs(os.environ["TF_FIXTURE"])
problems = []

# Check 1 — every reference resolves in every env where its key is active.
# This is the check that would have caught the missing spring.data.mongodb.database.
for env in ENVS:
    try:
        resolve_all(secrets, env, tf, stub_env=True)
    except Exception as exc:
        problems.append(f"check 1 ({env}): {exc}")

# Check 2 — every context key is used by at least one canonical file.
used = set()
for path in secrets.glob("*.yaml"):
    text = path.read_text()
    used |= set(CTX_REF.findall(text))
for env in ENVS:
    ctx = yaml.safe_load((secrets / "contexts" / f"{env}.yaml").read_text()) or {}
    for key in ctx:
        if key in RESERVED_CONTEXT_KEYS:
            continue
        if key not in used:
            problems.append(
                f"check 2 (contexts/{env}.yaml): key '{key}' is never referenced "
                f"by any canonical file — a renamed placeholder left it behind")

# Check 3 — every owner:user variable is documented in the .env.example of each
# env that delivers credentials by env file.
#
# PER-ENV, deliberately. Unioning the two .env.example files made a variable
# documented in only ONE of them pass for both, which hid a live gap: the mail
# credentials were listed in k8s/.env.example and absent from docker/.env.example,
# so a newcomer copying the example to docker/.env got silent mail failure — the
# exact failure class this whole phase exists to eliminate.
#
# Envs whose context sets userCredDelivery other than 'envfrom' (aws, which uses
# 'backend') are exempt: the value reaches the pod through the secret backend,
# and no .env.example is involved at all.
env_examples = {}
for spec in os.environ["ENV_EXAMPLES"].split(","):
    if not spec:
        continue
    name, _, p = spec.partition("=")
    env_examples[name] = pathlib.Path(p)


def _short(path):
    # 'docker/.env.example' rather than an absolute path — readable in both the
    # real tree and a temp copy, and stable across machines.
    return f"{path.parent.name}/{path.name}"


for env in ENVS:
    ctx = yaml.safe_load((secrets / "contexts" / f"{env}.yaml").read_text()) or {}
    if ctx.get("userCredDelivery") != "envfrom":
        continue
    example = env_examples.get(env)
    if example is None:
        problems.append(
            f"check 3 (contexts/{env}.yaml): userCredDelivery is 'envfrom' but no "
            f".env.example is mapped for '{env}' — the validator cannot tell "
            f"whether its credential variables are documented anywhere")
        continue
    if not example.exists():
        problems.append(
            f"check 3 (contexts/{env}.yaml): userCredDelivery is 'envfrom' but "
            f"{example} does not exist, so nothing documents '{env}'s credentials")
        continue
    documented = set(re.findall(r"^\s*([A-Z_][A-Z0-9_]*)=", example.read_text(), re.M))
    for path in sorted(secrets.glob("*.yaml")):
        raw = yaml.safe_load(path.read_text()) or {}
        for key, val in raw.items():
            if not isinstance(val, dict) or val.get("owner") != "user":
                continue
            envs = val.get("envs")
            if envs is not None and env not in envs:
                continue
            for var in ENV_REF.findall(str(val.get("value", ""))):
                if var not in documented:
                    problems.append(
                        f"check 3 ({path.name}): key '{key}' is delivered by env "
                        f"file on '{env}' and needs '{var}', which "
                        f"{_short(example)} does not document")

# Check 4 — application.jwk is byte-identical across all three envs.
jwks = {}
for env in ENVS:
    try:
        jwks[env] = resolve_all(secrets, env, tf, stub_env=True)["authorization-server"].get("application.jwk")
    except Exception:
        jwks[env] = None
if len(set(jwks.values())) != 1:
    differing = [e for e in ENVS if jwks[e] != jwks["compose"]]
    problems.append(
        f"check 4: application.jwk is not identical across envs — differs in "
        f"{differing}. The gateway caches JWKS by kid; one differing byte "
        f"invalidates every token.")

# Check 5 — contexts/aws.yaml references no terraform output outside the known set.
aws_ctx = yaml.safe_load((secrets / "contexts" / "aws.yaml").read_text()) or {}
for key, val in aws_ctx.items():
    m = TF_REF.match(str(val))
    if m and m.group(1) not in tf:
        problems.append(
            f"check 5 (contexts/aws.yaml): key '{key}' references terraform "
            f"output '{m.group(1)}', which is not among the known outputs")

# Check 6 — a caller that embeds a peer's port as a literal must still agree
# with the peer's own listening port, or a renamed port silently strands every
# caller. Ports are literals deliberately: they are identical in every env, so
# only the host moves (see the comments in gateway.yaml and bff-service.yaml).
#
# Two shapes carry such a literal, and both are bound here:
#
#   6a  a URL:   gateway.routes.<svc>.uri, feign.client.<svc>.url
#                → trailing :<port> must equal <svc>.yaml's server.port.
#   6b  a PAIR:  any <prefix>.port whose sibling <prefix>.host resolves from a
#                {{svc.<target>.host}} ref — that sibling is what proves the
#                key is an OUTBOUND target rather than the service's own
#                listener. Covers order-service's grpc.server.port and
#                bff-service's inventory.grpc.port, the two keys carrying the
#                9090 gRPC literal, neither of which matches a URL pattern.
#                A gRPC-flavoured prefix binds to the target's
#                grpc.server.port; anything else to its server.port.
#
# inventory-service's own grpc.server.port has no sibling .host, so it is read
# only as the authority, never as a caller — which is what makes 6b directional.
#
# Resolved per env with stub_env=True, like every other check, so this never
# needs a backend or credentials.
ROUTE_KEY = re.compile(r"^gateway\.routes\.([^.]+)\.uri$")
FEIGN_KEY = re.compile(r"^feign\.client\.([^.]+)\.url$")
PORT_IN_URL = re.compile(r":(\d+)$")
SVC_HOST_REF = re.compile(r"^\{\{svc\.(.+)\.host\}\}$")

# Raw, UNRESOLVED templates, keyed by service. Two uses: finding a sibling
# .host ref without re-resolving, and reporting a key by what the canonical
# file says rather than by what it resolved to — no resolved value reaches
# stdout or a message anywhere in this script.
def _raw_value(entry):
    # Tolerates a malformed expanded entry (no 'value'): check 1 owns that
    # diagnosis, and check 6 must not crash the whole script ahead of it.
    if isinstance(entry, dict):
        entry = entry.get("value")
    return "" if entry is None else str(entry)


raw_templates = {}
for path in sorted(secrets.glob("*.yaml")):
    entries = yaml.safe_load(path.read_text()) or {}
    raw_templates[path.stem] = {k: _raw_value(v) for k, v in entries.items()}


def check_port_agrees(service_name, key, target, port_key, port, resolved):
    """<service_name>.<key> embeds <port>; assert <target>.<port_key> matches."""
    if target not in raw_templates:
        problems.append(
            f"check 6 ({service_name}.yaml): key '{key}' points at "
            f"service '{target}', but {target}.yaml does not exist")
        return
    target_port = resolved.get(target, {}).get(port_key)
    if target_port is None:
        problems.append(
            f"check 6 ({service_name}.yaml): key '{key}' points at "
            f"'{target}', but {target}.yaml declares no {port_key}")
        return
    if port != target_port:
        problems.append(
            f"check 6 ({service_name}.yaml): key '{key}' embeds port "
            f"{port}, but {target}.yaml's {port_key} is "
            f"{target_port} — {service_name}.yaml and {target}.yaml "
            f"have drifted")


checked = set()
for env in ENVS:
    try:
        resolved = resolve_all(secrets, env, tf, stub_env=True)
    except Exception:
        # Already reported by check 1 — nothing new to say here.
        continue
    for service_name, kv in resolved.items():
        for key, value in kv.items():
            ident = (service_name, key)
            if ident in checked:
                continue

            # -- 6a: a URL with a trailing :<port> ------------------------
            m = ROUTE_KEY.match(key) or FEIGN_KEY.match(key)
            if m:
                checked.add(ident)
                port_match = PORT_IN_URL.search(value)
                if not port_match:
                    problems.append(
                        f"check 6 ({service_name}.yaml): key '{key}' has no "
                        f"trailing :<port> to check — its template is "
                        f"'{raw_templates.get(service_name, {}).get(key, '')}'")
                    continue
                check_port_agrees(service_name, key, m.group(1),
                                  "server.port", port_match.group(1), resolved)
                continue

            # -- 6b: an outbound <prefix>.host / <prefix>.port pair -------
            if not key.endswith(".port"):
                continue
            prefix = key[: -len(".port")]
            host_tmpl = raw_templates.get(service_name, {}).get(prefix + ".host")
            if host_tmpl is None:
                continue  # no sibling host → a listener, not a caller
            host_match = SVC_HOST_REF.match(host_tmpl.strip())
            if not host_match:
                continue  # sibling host is infra (mysql, redis, …), not a peer
            checked.add(ident)
            port_key = ("grpc.server.port" if "grpc" in prefix.split(".")
                        else "server.port")
            check_port_agrees(service_name, key, host_match.group(1),
                              port_key, value, resolved)

for p in problems:
    print(f"FAIL: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
