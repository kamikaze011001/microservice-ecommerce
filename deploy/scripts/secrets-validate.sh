#!/usr/bin/env bash
# Consistency checks over deploy/secrets/. No backend, no credentials, no
# network — so this can run in CI (Phase 9) with nothing configured.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$ROOT/deploy/secrets"

while [ $# -gt 0 ]; do
  case "$1" in
    --secrets-dir) SECRETS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PYTHONPATH="$ROOT/deploy/scripts/lib" \
SECRETS_DIR="$SECRETS" \
TF_FIXTURE="$ROOT/deploy/secrets/tests/fixtures/terraform-outputs.json" \
ENV_EXAMPLES="$ROOT/docker/.env.example:$ROOT/k8s/.env.example" \
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
# env that delivers credentials by envfrom.
documented = set()
for p in os.environ["ENV_EXAMPLES"].split(":"):
    f = pathlib.Path(p)
    if f.exists():
        documented |= set(re.findall(r"^\s*([A-Z_][A-Z0-9_]*)=", f.read_text(), re.M))
for path in secrets.glob("*.yaml"):
    raw = yaml.safe_load(path.read_text()) or {}
    for key, val in raw.items():
        if isinstance(val, dict) and val.get("owner") == "user":
            for var in ENV_REF.findall(str(val.get("value", ""))):
                if var not in documented:
                    problems.append(
                        f"check 3 ({path.name}): key '{key}' needs '{var}', which "
                        f"no .env.example documents")

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

# Check 6 — gateway.routes.<svc>.uri and feign.client.<svc>.url embed a port
# number as a literal (deliberately, since it is identical in every env — see
# the comments in gateway.yaml and bff-service.yaml). That literal must still
# equal the target service's own listening port, or a renamed server.port
# silently strands every caller. Resolved per env with stub_env=True, like
# every other check, so this never needs a backend or credentials.
ROUTE_KEY = re.compile(r"^gateway\.routes\.([^.]+)\.uri$")
FEIGN_KEY = re.compile(r"^feign\.client\.([^.]+)\.url$")
PORT_IN_URL = re.compile(r":(\d+)$")

checked = set()
for env in ENVS:
    try:
        resolved = resolve_all(secrets, env, tf, stub_env=True)
    except Exception:
        # Already reported by check 1 — nothing new to say here.
        continue
    for service_name, kv in resolved.items():
        for key, value in kv.items():
            m = ROUTE_KEY.match(key) or FEIGN_KEY.match(key)
            if not m:
                continue
            ident = (service_name, key)
            if ident in checked:
                continue
            checked.add(ident)

            target = m.group(1)
            target_path = secrets / f"{target}.yaml"
            if not target_path.exists():
                problems.append(
                    f"check 6 ({service_name}.yaml): key '{key}' points at "
                    f"service '{target}', but {target}.yaml does not exist")
                continue

            port_match = PORT_IN_URL.search(value)
            if not port_match:
                problems.append(
                    f"check 6 ({service_name}.yaml): key '{key}' resolved to "
                    f"'{value}', which has no trailing :<port> to check")
                continue
            route_port = port_match.group(1)

            target_kv = resolved.get(target, {})
            target_port = target_kv.get("server.port")
            port_key = "server.port"
            if target_port is None:
                target_port = target_kv.get("grpc.server.port")
                port_key = "grpc.server.port"
            if target_port is None:
                problems.append(
                    f"check 6 ({service_name}.yaml): key '{key}' points at "
                    f"'{target}', but {target}.yaml declares neither "
                    f"server.port nor grpc.server.port")
                continue

            if route_port != target_port:
                problems.append(
                    f"check 6 ({service_name}.yaml): key '{key}' embeds port "
                    f"{route_port}, but {target}.yaml's {port_key} is "
                    f"{target_port} — {service_name}.yaml and {target}.yaml "
                    f"have drifted")

for p in problems:
    print(f"FAIL: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
