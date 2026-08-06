# Canonical Secrets Consolidation Implementation Plan (Phase 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace three hand-maintained copies of per-service Spring configuration with one canonical source per service plus three env contexts, proven byte-equivalent to what the old paths produce.

**Architecture:** A Python resolver turns (canonical YAML + env context + environment) into a flat key→value map with no network access. A bash seeder pushes that map to the Vault HTTP API (compose, k8s) or AWS Secrets Manager (aws). Equivalence is proved offline by running each *old* script with fake `vault`/`aws`/`terraform` binaries on `PATH`, capturing the map it would have written, and diffing against the new resolver's output.

**Tech Stack:** bash, python3 + pyyaml (both already present; `yq` and the `vault` CLI are **not** installed), jq, curl, kubectl, Helm-style bash assertion harness modelled on `deploy/charts/microecom/tests/render-test.sh`.

**Spec:** `docs/superpowers/specs/2026-08-06-canonical-secrets-design.md`

## Global Constraints

- **Do not modify or delete** `docker/vault-configs/*.json`, `scripts/vault/import-secrets.sh`, `k8s/infra/jobs/03-vault-seed/seed.sh`, or `scripts/aws/seed-secrets.sh`. Deletion is Phase 8. `git diff main HEAD -- docker/vault-configs scripts/vault scripts/aws k8s` must be **empty** at the end of this plan.
- **Do not modify** `deploy/charts/` in any task. Plan 3's apps subchart, the `app-secrets` Secret and its `envFrom` mount stay exactly as merged.
- **Never `git push`.** A pre-push hook owns pushing and it is the human's job in this repo. Never bypass that hook.
- **Never print a resolved secret value to stdout in a test, a log line, or a commit message.** `--dry-run` output goes to a file; reports reference it by path and quote only key *names*.
- Secret-backend identifiers, exact: Vault path `secret/<service>`; AWS secret id `app/<service>`; AWS region default `ap-southeast-1`, profile default `microecom`.
- The canonical file `ecommerce.yaml` corresponds to `docker/vault-configs/ecommerce-common.json` and seeds path `ecommerce`. All ten other services map 1:1 by name.
- Env identifiers, exact, everywhere (`--env`, `envs:` lists, context filenames): `compose`, `k8s`, `aws`.
- `python3` invocations must work with **pyyaml only** — no other third-party imports.
- Resolver errors go to stderr prefixed `secrets-resolve: ` and exit 1. No partial output on failure.
- `set -uo pipefail` in every bash script; use here-strings rather than `printf | grep -q` for assertions (see the SIGPIPE note in `render-test.sh`).

## File Structure

**Created by this plan:**

```
deploy/secrets/
  contexts/compose.yaml           what {{ref}} means on docker-compose
  contexts/k8s.yaml               …on minikube
  contexts/aws.yaml               …on EKS; holds <terraform:…> refs
  jwk.private.json                the RSA signing key — ONE copy
  ecommerce.yaml                  the shared config all services read
  authorization-server.yaml       ┐
  bff-service.yaml                │
  core-s3.yaml                    │
  gateway.yaml                    │ one per service,
  inventory-service.yaml          │ same key names as today
  mock-paypal-service.yaml        │
  orchestrator-service.yaml       │
  order-service.yaml              │
  payment-service.yaml            │
  product-service.yaml            ┘

deploy/secrets/tests/
  shims/vault                     fake vault:  records `kv put`, fails `kv get`
  shims/aws                       fake aws:    records put-secret-value
  shims/terraform                 fake tf:     serves the fixture
  fixtures/terraform-outputs.json `terraform output -json` shaped; used by BOTH sides
  fixtures/user-creds.env         dummy PayPal/mail creds for capture
  capture-golden.sh               runs the three old paths under shims
  assemble-golden.py              normalises captures → golden/<env>.json
  golden/{compose,k8s,aws}.json   committed; the equivalence target
  resolver-test.sh                unit tests for the resolver
  equivalence-test.sh             diffs golden vs `--dry-run`, all three envs

deploy/scripts/
  lib/secrets_resolve.py          the resolver (python3 + pyyaml)
  secrets-seed.sh                 resolve → push
  secrets-validate.sh             four consistency checks; no network
```

**Modified:** `Makefile` (new targets), `deploy/README.md` (usage + the overwrite warning). No `.gitignore` change is needed — `.gitignore:28` already ignores all of `deploy/.run/`.

### A note on derived content

Tasks 3 and 4 do **not** list the ~90 canonical key values inline, and that is deliberate rather than an omission. Those values already exist, exactly, in `deploy/secrets/tests/golden/<env>.json` — produced mechanically by Task 1 from the three live sources. Restating them in this document would create a fourth hand-typed copy of the very data this phase exists to de-duplicate, and any transcription slip in it would be *believed* by the implementer over the golden.

So the contract for those tasks is: **the golden files are the source of the values; this plan supplies the schema, the four classification rules, and an exact acceptance test** (`equivalence-test.sh` reaching `33 passed, 0 failed, 0 pending`). Every other task in this plan carries its code in full.

**Responsibility split.** `secrets_resolve.py` never touches a network or a backend; it is a pure function of files plus the process environment. `secrets-seed.sh` never parses YAML; it consumes the resolver's JSON. That boundary is what lets the AWS path be verified without an AWS account, and lets `secrets-validate.sh` run in CI with no credentials.

---

### Task 1: Golden capture harness

Captures what each *old* path would write, with no live backend. This is the test the rest of the plan is driven by, so it comes first and is committed before any canonical file exists.

**Files:**
- Create: `deploy/secrets/tests/shims/vault`
- Create: `deploy/secrets/tests/shims/aws`
- Create: `deploy/secrets/tests/shims/terraform`
- Create: `deploy/secrets/tests/fixtures/terraform-outputs.json`
- Create: `deploy/secrets/tests/fixtures/user-creds.env`
- Create: `deploy/secrets/tests/assemble-golden.py`
- Create: `deploy/secrets/tests/capture-golden.sh`
- Create (generated, committed): `deploy/secrets/tests/golden/{compose,k8s,aws}.json`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `deploy/secrets/tests/golden/<env>.json`, a JSON object `{"<service>": {"<dotted.key>": "<value>"}}` with sorted keys, 2-space indent, trailing newline. Every later task diffs against these files. Also produces `deploy/secrets/tests/fixtures/terraform-outputs.json`, which Task 3 reuses verbatim as the `--tf-outputs` fixture.

- [ ] **Step 1: Write the three shims**

`deploy/secrets/tests/shims/vault`:

```bash
#!/usr/bin/env bash
# Fake `vault` for golden capture — never talks to a server.
#
# Two behaviours matter:
#   `kv get`  → ALWAYS exit 1. seed.sh's put_if_missing gates each path on a
#               successful `kv get` and skips when it succeeds. Failing here
#               makes every `put` execute, so the capture records the script's
#               full INTENT rather than whatever a partially-seeded Vault holds.
#   `kv put`  → append one TAB-separated line per key=value pair.
# Anything else (e.g. `secrets enable`) is a silent success.
set -u

: "${CAPTURE_DIR:?CAPTURE_DIR must be set}"

case "${1:-}/${2:-}" in
  kv/get) exit 1 ;;
  kv/put)
    shift 2
    path="${1#secret/}"; shift
    for pair in "$@"; do
      key="${pair%%=*}"
      val="${pair#*=}"
      printf '%s\t%s\t%s\n' "$path" "$key" "$val" >> "$CAPTURE_DIR/vault-puts.tsv"
    done
    ;;
esac
exit 0
```

`deploy/secrets/tests/shims/aws`:

```bash
#!/usr/bin/env bash
# Fake `aws` for golden capture. Only `secretsmanager put-secret-value` is
# recorded; every other subcommand is a silent success so the script's own
# preflight calls don't abort it.
set -u

: "${CAPTURE_DIR:?CAPTURE_DIR must be set}"

sid=""; sstr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --secret-id)     sid="$2";  shift 2 ;;
    --secret-string) sstr="$2"; shift 2 ;;
    *)                          shift   ;;
  esac
done

# The secret id is `app/<service>`; the golden is keyed by bare service name.
if [ -n "$sid" ]; then
  printf '%s\t%s\n' "${sid#app/}" "$sstr" >> "$CAPTURE_DIR/aws-puts.tsv"
fi
exit 0
```

`deploy/secrets/tests/shims/terraform`:

```bash
#!/usr/bin/env bash
# Fake `terraform`. seed-secrets.sh calls
#   terraform -chdir="$TF" output -raw <name>
# so the output name is always the LAST argument. Serve it from the fixture,
# which is shaped exactly like real `terraform output -json`.
set -u

: "${TF_FIXTURE:?TF_FIXTURE must be set}"

name=""
for a in "$@"; do name="$a"; done

jq -er --arg n "$name" '.[$n].value' "$TF_FIXTURE"
```

- [ ] **Step 2: Write the fixtures**

`deploy/secrets/tests/fixtures/terraform-outputs.json` — shaped like real `terraform output -json` so the same file serves the shim *and*, in Task 3, the resolver's `--tf-outputs`. Values are obviously-fake but structurally valid (a real RDS endpoint really does look like `<name>.<id>.<region>.rds.amazonaws.com`):

```json
{
  "rds_primary_endpoint":  { "value": "microecom-fixture.cluster-xxxx.ap-southeast-1.rds.amazonaws.com" },
  "rds_replica_endpoint":  { "value": "microecom-fixture-ro.cluster-xxxx.ap-southeast-1.rds.amazonaws.com" },
  "redis_primary_endpoint":{ "value": "microecom-fixture.xxxx.ng.0001.apse1.cache.amazonaws.com" },
  "redis_auth_token":      { "value": "fixture-redis-auth-token" },
  "db_master_password":    { "value": "fixture-db-password" },
  "s3_bucket_name":        { "value": "microecom-fixture-media" },
  "s3_public_base_url":    { "value": "https://microecom-fixture-media.s3.ap-southeast-1.amazonaws.com" },
  "shop_url":              { "value": "https://shop.fixture.example" }
}
```

`deploy/secrets/tests/fixtures/user-creds.env` — dummy values only. These are the four credentials `seed-secrets.sh` requires via `: "${VAR:?}"`. **`APPLICATION_JWK` is deliberately absent** — Step 3 sources it from the real config so both sides of the diff carry identical bytes:

```sh
PAYPAL_CLIENT_ID=fixture-paypal-client-id
PAYPAL_CLIENT_SECRET=fixture-paypal-client-secret
APPLICATION_MAIL_USERNAME=fixture-mail-user
APPLICATION_MAIL_PASSWORD=fixture-mail-password
```

- [ ] **Step 3: Write the capture driver**

`deploy/secrets/tests/capture-golden.sh`:

```bash
#!/usr/bin/env bash
# Capture what each OLD seeding path would write, with no live backend.
#
#   ./deploy/secrets/tests/capture-golden.sh
#
# compose needs no shim at all: import-secrets.sh POSTs each JSON file verbatim,
# so the map IS the file content under the filename->path mapping at
# scripts/vault/import-secrets.sh:41-51. k8s and aws run their real scripts with
# fake binaries first on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

export CAPTURE_DIR="$(mktemp -d)"
export TF_FIXTURE="$HERE/fixtures/terraform-outputs.json"
trap 'rm -rf "$CAPTURE_DIR"' EXIT

mkdir -p "$HERE/golden"
chmod +x "$HERE/shims/"*

# ── k8s ──────────────────────────────────────────────────────────────────────
# seed.sh is a plain shell script; running it with a fake `vault` on PATH is
# enough. It normally runs inside a Job, but it reads no cluster state.
PATH="$HERE/shims:$PATH" bash "$ROOT/k8s/infra/jobs/03-vault-seed/seed.sh" >/dev/null
[ -s "$CAPTURE_DIR/vault-puts.tsv" ] || { echo "FAIL: k8s capture is empty" >&2; exit 1; }

# ── aws ──────────────────────────────────────────────────────────────────────
# The JWK comes from the real compose config so both sides of the equivalence
# diff carry identical bytes. Everything else is a dummy fixture credential.
set -a; . "$HERE/fixtures/user-creds.env"; set +a
export APPLICATION_JWK
APPLICATION_JWK="$(jq -r '."application.jwk"' "$ROOT/docker/vault-configs/authorization-server.json")"
[ -n "$APPLICATION_JWK" ] && [ "$APPLICATION_JWK" != "null" ] \
  || { echo "FAIL: could not read application.jwk from docker/vault-configs" >&2; exit 1; }

PATH="$HERE/shims:$PATH" bash "$ROOT/scripts/aws/seed-secrets.sh" >/dev/null
[ -s "$CAPTURE_DIR/aws-puts.tsv" ] || { echo "FAIL: aws capture is empty" >&2; exit 1; }

# ── assemble ─────────────────────────────────────────────────────────────────
python3 "$HERE/assemble-golden.py" \
  --repo-root "$ROOT" --capture-dir "$CAPTURE_DIR" --out-dir "$HERE/golden"

echo "golden maps written to $HERE/golden"
```

- [ ] **Step 4: Write the assembler**

`deploy/secrets/tests/assemble-golden.py`:

```python
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
```

- [ ] **Step 5: Run the capture**

Run: `bash deploy/secrets/tests/capture-golden.sh`

Expected: three lines of the form `compose: 11 services, N keys -> …`, and three files under `deploy/secrets/tests/golden/`.

- [ ] **Step 6: Verify the compose golden against an independent measurement**

The counts below were measured directly from the JSON files, then reduced by the four `_comment*` pseudo-keys the assembler drops (`_comment` and `_comment_mail_creds` in `ecommerce-common.json`; `_comment_paypal_creds` and `_comment_mock_paypal` in `payment-service.json`). Raw file totals are 94 keys; real configuration is **90**.

Run:
```bash
python3 - <<'PY'
import json
g = json.load(open("deploy/secrets/tests/golden/compose.json"))
expected = {
    "authorization-server": 5, "bff-service": 5, "core-s3": 10,
    "ecommerce": 24, "gateway": 6, "inventory-service": 6,
    "mock-paypal-service": 2, "orchestrator-service": 16,
    "order-service": 7, "payment-service": 5, "product-service": 4,
}
actual = {k: len(v) for k, v in g.items()}
assert actual == expected, f"compose golden mismatch:\n  expected {expected}\n  actual   {actual}"
assert sum(actual.values()) == 90, sum(actual.values())
assert not [k for v in g.values() for k in v if k.startswith("_comment")], "comment pseudo-keys leaked into the golden"
print("compose golden OK: 11 services, 90 keys, 0 _comment* leaked")
PY
```
Expected: `compose golden OK: 11 services, 90 keys, 0 _comment* leaked`

- [ ] **Step 7: Verify the k8s and aws goldens carry their divergent keys**

These are the keys the survey identified as existing on k8s/aws but not compose. If the shims silently failed, these are absent and the assertion catches it.

Run:
```bash
python3 - <<'PY'
import json
k = json.load(open("deploy/secrets/tests/golden/k8s.json"))
a = json.load(open("deploy/secrets/tests/golden/aws.json"))
for name, g in (("k8s", k), ("aws", a)):
    assert len(g) == 11, f"{name}: expected 11 services, got {len(g)}"
    routes = [x for x in g["gateway"] if x.startswith("gateway.routes.")]
    assert len(routes) == 7, f"{name}: expected 7 gateway.routes.* keys, got {len(routes)}"
    assert g["ecommerce"].get("eureka.client.enabled") == "false", f"{name}: eureka.client.enabled missing"
    assert "eureka.client.service-url.defaultZone" not in g["bff-service"], f"{name}: unexpected eureka defaultZone"
# The JWK must be byte-identical across compose and k8s (gateway caches JWKS by kid).
c = json.load(open("deploy/secrets/tests/golden/compose.json"))
assert c["authorization-server"]["application.jwk"] == k["authorization-server"]["application.jwk"], "JWK differs compose vs k8s"
print("k8s/aws goldens OK; JWK identical compose vs k8s")
PY
```
Expected: `k8s/aws goldens OK; JWK identical compose vs k8s`

- [ ] **Step 8: Confirm no old file was modified**

Run: `git status --porcelain docker/ scripts/ k8s/`
Expected: **empty output**. The shims must not have written into the old trees.

- [ ] **Step 9: Commit**

```bash
git add deploy/secrets/tests
git commit -m "test(secrets): capture golden maps from the three old seed paths

Runs each old path with fake vault/aws/terraform binaries on PATH and
records the key->value map it WOULD have written, with no live backend.
The fake vault fails every \`kv get\` so put_if_missing never skips, making
the k8s capture the script's full intent rather than a partially-seeded
Vault's contents. compose needs no shim: import-secrets.sh POSTs each JSON
verbatim, so the map is the file content under its filename->path mapping.

These goldens are the equivalence target the canonical files must hit."
```

---

### Task 2: The resolver

A pure function from (canonical YAML + context + environment) to a flat map. No network, no backend, no cluster.

**Files:**
- Create: `deploy/scripts/lib/secrets_resolve.py`
- Create: `deploy/secrets/tests/resolver-test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (Task 1's goldens are used from Task 3 onward).
- Produces:
  ```
  python3 deploy/scripts/lib/secrets_resolve.py \
      --env {compose|k8s|aws} [--secrets-dir DIR] [--service NAME] [--tf-outputs FILE]
  ```
  stdout: `{"<service>": {"<key>": "<value>"}}`, sorted keys, 2-space indent, trailing newline — **byte-identical in shape to Task 1's goldens**. Exit 0 on success; on failure, exit 1 with a `secrets-resolve: `-prefixed message on stderr and **no stdout output**.

  Python API imported by Task 5's validator, exactly these names: `resolve_all(secrets_dir: Path, env: str, tf_outputs: dict | None = None, only: str | None = None, stub_env: bool = False) -> dict[str, dict[str, str]]`, `load_tf_outputs(path: str | None) -> dict | None`, and the module constants `CTX_REF`, `ENV_REF`, `TF_REF` (compiled `re.Pattern`), `ENVS` (tuple), `RESERVED_CONTEXT_KEYS` (set).

  `stub_env=True` (CLI: `--stub-env`) replaces every `${VAR}` with `<stub:VAR>` instead of reading the environment. Task 5's validator **must** use it: `secrets-validate.sh` is specified to need no credentials, and without stubbing, validating the aws tree would fail on an unset `PAYPAL_CLIENT_SECRET` — a false positive that would get the guard disabled. Seeding must **never** use it.

- [ ] **Step 1: Write the failing test harness**

`deploy/secrets/tests/resolver-test.sh` — mirrors the `render-test.sh` style (plain bash, `ok`/`bad` counters, here-strings not pipes). It builds tiny throwaway secret trees in a temp dir so the tests are independent of the real canonical files:

```bash
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash deploy/secrets/tests/resolver-test.sh`
Expected: FAIL — every case errors because `deploy/scripts/lib/secrets_resolve.py` does not exist yet.

- [ ] **Step 3: Write the resolver**

`deploy/scripts/lib/secrets_resolve.py`:

```python
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


def _entry(raw):
    """Normalise a canonical value into (value, envs_or_None, owner)."""
    if isinstance(raw, dict):
        if "value" not in raw:
            raise ResolveError(f"expanded entry is missing 'value': {raw!r}")
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
        value, envs, owner = _entry(rawval)
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash deploy/secrets/tests/resolver-test.sh`
Expected: `15 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add deploy/scripts/lib/secrets_resolve.py deploy/secrets/tests/resolver-test.sh
git commit -m "feat(secrets): canonical-file resolver with per-syntax failures

Pure function of (canonical YAML + env context + process environment) —
no network, no backend, no cluster. That boundary is what lets the AWS
path be verified without an AWS account and validation run in CI with no
credentials.

Four reference syntaxes are kept distinct so a failure names which kind of
input is missing: {{ctx}}, \${ENV}, <file:> in canonical files, and
<terraform:> in context files only. A failed resolve writes nothing to
stdout, so a caller redirecting to a file never captures a partial map."
```

---

### Task 3: Env contexts and `ecommerce.yaml`

The shared config every service reads, and all three context files. Nearly every placeholder in the system lands here, so this task establishes the context vocabulary the remaining ten files reuse.

**Files:**
- Create: `deploy/secrets/contexts/{compose,k8s,aws}.yaml`
- Create: `deploy/secrets/ecommerce.yaml`
- Create: `deploy/secrets/tests/equivalence-test.sh`
- Create: `deploy/secrets/jwk.private.json`

**Interfaces:**
- Consumes: `deploy/secrets/tests/golden/<env>.json` (Task 1); `secrets_resolve.py`'s CLI and output shape (Task 2).
- Produces: the context vocabulary — every `{{ref}}` name defined in all three contexts — which Task 4's ten service files consume. Also `equivalence-test.sh`, which Task 4 re-runs unchanged.

- [ ] **Step 1: Write the equivalence test**

`deploy/secrets/tests/equivalence-test.sh`. It compares only the services that exist as canonical files, so it is meaningful from the very first file rather than only once all eleven are written:

```bash
#!/usr/bin/env bash
# Diff the resolver's output against the golden capture of the OLD paths.
#
#   ./deploy/secrets/tests/equivalence-test.sh
#
# Scoped to the services that currently exist under deploy/secrets/, so it is
# meaningful while the canonical files are still being written. A service with
# no canonical file yet is reported as PENDING, never as a pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SECRETS="$ROOT/deploy/secrets"
RESOLVER="$ROOT/deploy/scripts/lib/secrets_resolve.py"
TF="$HERE/fixtures/terraform-outputs.json"

set -a; . "$HERE/fixtures/user-creds.env"; set +a
export APPLICATION_JWK
APPLICATION_JWK="$(jq -r '."application.jwk"' "$ROOT/docker/vault-configs/authorization-server.json")"

pass=0; fail=0; pending=0

for env in compose k8s aws; do
  echo
  printf '\033[1m%s\033[0m\n' "$env"
  actual="$(python3 "$RESOLVER" --secrets-dir "$SECRETS" --env "$env" --tf-outputs "$TF" 2>&1)" || {
    printf '  \033[31mFAIL\033[0m resolver errored: %s\n' "$actual"; fail=$((fail + 1)); continue
  }
  for svc in $(jq -r 'keys[]' "$HERE/golden/$env.json"); do
    if [ ! -f "$SECRETS/$svc.yaml" ]; then
      printf '  \033[33m..\033[0m   %s (no canonical file yet)\n' "$svc"; pending=$((pending + 1)); continue
    fi
    want="$(jq -S --arg s "$svc" '.[$s]' "$HERE/golden/$env.json")"
    got="$(jq -S --arg s "$svc" '.[$s]' <<<"$actual")"
    if [ "$want" = "$got" ]; then
      printf '  \033[32mok\033[0m   %s\n' "$svc"; pass=$((pass + 1))
    else
      printf '  \033[31mFAIL\033[0m %s\n' "$svc"; fail=$((fail + 1))
      # Key NAMES only — values are secrets and must never reach a log.
      diff <(jq -r 'keys[]' <<<"$want") <(jq -r 'keys[]' <<<"$got") \
        | sed 's/^/         /' || true
      changed="$(jq -r --argjson a "$want" --argjson b "$got" \
        -n '$a | to_entries | map(select(.value != ($b[.key] // null))) | map(.key)[]' 2>/dev/null)"
      [ -n "$changed" ] && printf '         value differs: %s\n' "$(tr '\n' ' ' <<<"$changed")"
    fi
  done
done

echo
printf '%d passed, %d failed, %d pending\n' "$pass" "$fail" "$pending"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to confirm everything is pending**

Run: `bash deploy/secrets/tests/equivalence-test.sh`
Expected: `0 passed, 0 failed, 33 pending` (11 services × 3 envs), because no canonical file exists yet.

- [ ] **Step 3: Write the three context files**

Derive every value from the goldens rather than from memory. For each `{{ref}}` you introduce in Step 4, the three contexts must define it. Start from this skeleton and extend it as Step 4 requires — the acceptance test is Step 6, not this list:

```yaml
# deploy/secrets/contexts/compose.yaml
# docker-compose. Services run on the host and reach infra through published
# ports, so several values are HOST port mappings, not container ports —
# e.g. docker/kafka.yml:46 maps "8091:8081" for Schema Registry.
userCredDelivery: envfrom

mysql.master.host: localhost
mysql.master.port: "3306"
mysql.slave1.host: localhost
mysql.slave1.port: "3307"
mysql.slave2.host: localhost
mysql.slave2.port: "3308"
redis.host: localhost
redis.port: "6379"
mongo.host: localhost
mongo.port: "27017"
kafka.bootstrap: localhost:9092
schemaRegistry.host: localhost
schemaRegistry.port: "8091"
s3.endpoint: http://localhost:9000
```

```yaml
# deploy/secrets/contexts/k8s.yaml
# minikube. Eureka is disabled; services address each other by cluster DNS.
userCredDelivery: envfrom

mysql.master.host: mysql.infra.svc.cluster.local
mysql.master.port: "3306"
mysql.slave1.host: mysql-replica.infra.svc.cluster.local
mysql.slave1.port: "3306"
mysql.slave2.host: mysql-replica.infra.svc.cluster.local
mysql.slave2.port: "3306"
redis.host: redis.infra.svc.cluster.local
redis.port: "6379"
mongo.host: mongodb.infra.svc.cluster.local
mongo.port: "27017"
kafka.bootstrap: kafka.infra.svc.cluster.local:9092
schemaRegistry.host: schema-registry.infra.svc.cluster.local
schemaRegistry.port: "8081"
s3.endpoint: http://minio.infra.svc.cluster.local:9000
```

```yaml
# deploy/secrets/contexts/aws.yaml
# EKS. Managed data tier comes from terraform outputs; the self-hosted infra
# (Kafka, Schema Registry, MinIO-replaced-by-S3) keeps cluster DNS.
# <terraform:…> is legal ONLY in this file, never in a canonical file.
userCredDelivery: backend

mysql.master.host: <terraform:rds_primary_endpoint>
mysql.master.port: "3306"
mysql.slave1.host: <terraform:rds_replica_endpoint>
mysql.slave1.port: "3306"
mysql.slave2.host: <terraform:rds_replica_endpoint>
mysql.slave2.port: "3306"
redis.host: <terraform:redis_primary_endpoint>
redis.port: "6379"
kafka.bootstrap: kafka.infra.svc.cluster.local:9092
schemaRegistry.host: schema-registry.infra.svc.cluster.local
schemaRegistry.port: "8081"
```

**Fill the remaining values by reading `deploy/secrets/tests/golden/<env>.json`**, not by guessing. Where the three goldens hold the same literal, the value belongs in `ecommerce.yaml` as a plain scalar and needs **no** context key at all.

Two values will look like mistakes and must be transcribed faithfully anyway — the spec records both as findings raised, not fixed:

- `redis.password` is **empty on k8s** and non-empty on compose. The in-cluster Redis accepts unauthenticated connections. Write the empty string, add a comment pointing at the spec's Findings section, and do not invent a password: changing it here would break the equivalence proof that is this phase's whole evidence base.
- `mysql.username`/`mysql.password` differ per env by design — per-role literals on compose, `root` on k8s (matching the in-cluster MySQL chart), `<terraform:db_master_password>` on aws.

- [ ] **Step 4: Write `deploy/secrets/ecommerce.yaml`**

Transcribe the 26 keys of `golden/compose.json → ecommerce`, plus the keys the k8s and aws goldens add (`eureka.client.enabled`, `spring.data.mongodb.database`, `management.metrics…`, `spring.data.redis.ssl.enabled`, and any others the goldens show). Rules:

- Value identical in all three goldens → **plain scalar**.
- Value differs only by host/port/endpoint → **`{{ref}}`**, with the ref defined in all three contexts.
- Key present in only some goldens → **`envs:` list naming exactly those envs**.
- Genuine credential the aws golden carries but compose/k8s do not → **`owner: user`** with a `${VAR}` value.

Shape, with the JDBC URL as the worked example — note the query string is part of the canonical value, not the context:

```yaml
# deploy/secrets/ecommerce.yaml → vault:secret/ecommerce | asm:app/ecommerce
# The shared config every service reads.

spring.datasource.master.driver-class-name: com.mysql.cj.jdbc.Driver
spring.datasource.master.url: "jdbc:mysql://{{mysql.master.host}}:{{mysql.master.port}}/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"
spring.datasource.master.username: "{{mysql.username}}"
spring.datasource.master.password: "{{mysql.password}}"

spring.data.redis.host: "{{redis.host}}"
spring.data.redis.port: "{{redis.port}}"
spring.data.redis.password: "{{redis.password}}"
spring.data.redis.ssl.enabled:
  value: "true"
  envs: [aws]

spring.kafka.properties.schema.registry.url: "http://{{schemaRegistry.host}}:{{schemaRegistry.port}}"

eureka.client.enabled:
  value: "false"
  envs: [k8s, aws]
```

- [ ] **Step 5: Extract the JWK to its single home**

The JWK is not in `ecommerce.yaml` (it belongs to `authorization-server`, written in Task 4), but its file is created here so Task 4 can reference it:

```bash
jq -r '."application.jwk"' docker/vault-configs/authorization-server.json \
  > deploy/secrets/jwk.private.json
# The JSON must round-trip, and must NOT gain a trailing newline — the gateway
# caches JWKS by kid and compares bytes.
printf '%s' "$(cat deploy/secrets/jwk.private.json)" > deploy/secrets/jwk.private.json
jq -e 'has("kid")' deploy/secrets/jwk.private.json >/dev/null && echo "jwk extracted OK"
```
Expected: `jwk extracted OK`

- [ ] **Step 6: Run the equivalence test and drive `ecommerce` to a clean diff**

Run: `bash deploy/secrets/tests/equivalence-test.sh`
Expected: `ecommerce` reports `ok` for **all three envs**; the other ten remain `pending`. Iterate on Steps 3–4 until it does. A `value differs` line names the offending keys without printing their values.

- [ ] **Step 7: Confirm the terraform cache is already ignored**

`.gitignore:28` already ignores the whole `deploy/.run/` directory, so no new pattern is needed — verify rather than add, and do not add a redundant narrower rule.

Run: `git check-ignore -v deploy/.run/terraform-outputs.json`
Expected: `.gitignore:28:deploy/.run/	deploy/.run/terraform-outputs.json`

- [ ] **Step 8: Commit**

```bash
git add deploy/secrets .gitignore
git commit -m "feat(secrets): env contexts, ecommerce.yaml and the equivalence test

The shared config all services read, plus the three env contexts that
define the {{ref}} vocabulary the per-service files reuse. Values were
transcribed from the golden captures rather than from the old sources by
hand, so the diff is the authority.

equivalence-test.sh is scoped to the canonical files that exist, reporting
services without one as PENDING rather than passing them vacuously. It
prints key NAMES on a mismatch and never values."
```

---

### Task 4: The ten per-service canonical files

**Files:**
- Create: `deploy/secrets/{authorization-server,bff-service,core-s3,gateway,inventory-service,mock-paypal-service,orchestrator-service,order-service,payment-service,product-service}.yaml`

**Interfaces:**
- Consumes: the context vocabulary from Task 3; `equivalence-test.sh` unchanged; `jwk.private.json` from Task 3 Step 5.
- Produces: a complete `deploy/secrets/` tree — 11 canonical files — that Tasks 5 and 6 validate and seed.

- [ ] **Step 1: Write the six mechanical files**

`product-service.yaml`, `inventory-service.yaml`, `order-service.yaml`, `orchestrator-service.yaml`, `mock-paypal-service.yaml`, `core-s3.yaml`. Same four rules as Task 3 Step 4. Transcribe from `golden/<env>.json`; introduce a `{{ref}}` only where the three goldens genuinely differ, and add the ref to all three contexts when you do.

`core-s3.yaml` needs one non-obvious comment, because the value looks like an omission and is not:

```yaml
# deploy/secrets/core-s3.yaml → vault:secret/core-s3 | asm:app/core-s3
# s3.access-key/secret-key are EMPTY on aws by design, not by oversight: a blank
# access key is the sentinel that flips core-s3's S3Config to
# DefaultCredentialsProvider (IRSA web identity) instead of static keys.
# See core/core-s3 S3Config.java.
s3.endpoint: "{{s3.endpoint}}"
s3.access-key: "{{s3.accessKey}}"
s3.secret-key: "{{s3.secretKey}}"
```

- [ ] **Step 2: Run the equivalence test**

Run: `bash deploy/secrets/tests/equivalence-test.sh`
Expected: those six report `ok` on all three envs. Iterate until clean.

- [ ] **Step 3: Write `authorization-server.yaml` with the file-ref JWK**

```yaml
# deploy/secrets/authorization-server.yaml
# application.jwk is the STABLE RSA signing key. The gateway caches JWKS by kid,
# so one differing byte invalidates every token in the system — hence a single
# file on disk referenced from here, never a pasted copy.
application.jwk: "<file:jwk.private.json>"
```
plus the remaining four keys transcribed from the goldens.

- [ ] **Step 4: Write `gateway.yaml`**

Gateway carries 6 keys on compose and 13 on k8s/aws — the 7 extra are `gateway.routes.*.uri`, which replace `application.yml`'s `lb://NAME` Eureka defaults with cluster DNS. Each gets `envs: [k8s, aws]`:

```yaml
gateway.routes.product-service.uri:
  value: "http://{{svc.product-service.host}}:{{svc.product-service.port}}"
  envs: [k8s, aws]
```
Add the seven `svc.*` host/port pairs to `contexts/k8s.yaml` and `contexts/aws.yaml`. Do **not** add them to `contexts/compose.yaml` — an `envs:`-gated key is never resolved there, and an unused context key is a `secrets-validate.sh` failure in Task 5.

- [ ] **Step 5: Write `bff-service.yaml` — the Eureka/Service-DNS split**

This is the file where the two discovery modes meet. Compose has the two `eureka.*` keys and none of the `feign.client.*`; k8s and aws have the inverse:

```yaml
eureka.client.service-url.defaultZone:
  value: "http://{{eureka.host}}:8761/eureka/"
  envs: [compose]
eureka.instance.prefer-ip-address:
  value: "true"
  envs: [compose]

feign.client.product-service.url:
  value: "http://{{svc.product-service.host}}:{{svc.product-service.port}}"
  envs: [k8s, aws]
```

- [ ] **Step 6: Write `payment-service.yaml` — the only `owner: user` keys**

Compose and k8s carry 5 keys here; aws carries 8. The three extra are the PayPal credentials and tunnel URL, which on compose/k8s arrive through `.env` → the `app-secrets` Secret → `envFrom`, and on aws are seeded into the backend. `owner: user` plus `userCredDelivery` in the context expresses exactly that, with no per-env branching in this file:

```yaml
application.paypal.client-id:
  value: "${PAYPAL_CLIENT_ID}"
  owner: user
application.paypal.client-secret:
  value: "${PAYPAL_CLIENT_SECRET}"
  owner: user
application.paypal.tunnel-url:
  value: "{{paypal.tunnelUrl}}"
  envs: [aws]

# Empty on aws pending the Phase 5b domain work — carried forward as-is rather
# than invented, because this phase claims behavioural equivalence.
application.frontend.base-url: "{{frontend.baseUrl}}"
```

- [ ] **Step 7: Run the equivalence test to completion**

Run: `bash deploy/secrets/tests/equivalence-test.sh`
Expected: **`33 passed, 0 failed, 0 pending`**.

Any remaining `FAIL` is either a defect in a canonical file or a deliberate judgment call. If you conclude it is the latter, record the key, both sides, and the justification in the task report — do not weaken the test to make it pass.

- [ ] **Step 8: Confirm the old tree is still untouched**

Run: `git status --porcelain docker/ scripts/ k8s/ deploy/charts/`
Expected: **empty output**.

- [ ] **Step 9: Commit**

```bash
git add deploy/secrets
git commit -m "feat(secrets): the ten per-service canonical files

Completes deploy/secrets/. All 33 service/env combinations now match the
golden capture of the old paths byte for byte.

Three files carry the interesting cases: bff-service holds the Eureka
(compose) vs Service-DNS (k8s/aws) split as envs:-gated keys rather than
as one superset with empty values; payment-service is the only file with
owner:user keys, whose destination is decided once per env by the
context's userCredDelivery rather than four times here; and core-s3
documents that a blank s3.access-key on aws is the IRSA sentinel, not an
omission."
```

---

### Task 5: `secrets-validate.sh`

Turns the drift lesson into a failure. Pure function over files: no backend, no credentials, no network.

**Files:**
- Create: `deploy/scripts/secrets-validate.sh`
- Create: `deploy/secrets/tests/validate-test.sh`

**Interfaces:**
- Consumes: `secrets_resolve.py`'s `resolve_all` / `load_context` / `service_names` (Task 2); the complete `deploy/secrets/` tree (Task 4).
- Produces: `bash deploy/scripts/secrets-validate.sh [--secrets-dir DIR]` → exit 0 clean, exit 1 with one `FAIL: ` line per problem on stderr.

- [ ] **Step 1: Write the failing test**

`deploy/secrets/tests/validate-test.sh` builds deliberately-broken trees in a temp dir and asserts each check fires:

```bash
#!/usr/bin/env bash
# Each case corrupts one thing in a copy of the real tree and asserts that
# exactly the matching check fires. A guard that cannot fail is not a guard.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VALIDATE="$ROOT/deploy/scripts/secrets-validate.sh"
pass=0; fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

assert_contains() {
  if grep -qF -- "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted: %s\n       got: %s\n' "$2" "$3"
  fi
}

copy_tree() { local d="$1"; mkdir -p "$d"; cp -R "$ROOT/deploy/secrets/." "$d/"; rm -rf "$d/tests"; }

echo; printf '\033[1msecrets-validate\033[0m\n'

# 0. the real tree is clean
out="$(bash "$VALIDATE" --secrets-dir "$ROOT/deploy/secrets" 2>&1)"
if [ $? -eq 0 ]; then ok "the real tree validates clean"; else
  bad "the real tree validates clean"; printf '%s\n' "$out" | sed 's/^/       /'
fi

# 1. an unresolvable {{ref}} in an env where the key IS active
T="$(mktemp -d)"; copy_tree "$T"
printf '\ncanary.key: "{{definitely.not.defined}}"\n' >> "$T/ecommerce.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 1 catches an unresolvable context ref" "definitely.not.defined" "$out"
rm -rf "$T"

# 2. an unused context key
T="$(mktemp -d)"; copy_tree "$T"
printf '\northaned.ref: nobody-reads-me\n' >> "$T/contexts/k8s.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 2 catches an unused context key" "orphaned.ref" "$out"
rm -rf "$T"

# 3. an owner:user key naming an undocumented variable
T="$(mktemp -d)"; copy_tree "$T"
cat >> "$T/payment-service.yaml" <<'YAML'
canary.cred:
  value: "${NOT_IN_ENV_EXAMPLE}"
  owner: user
YAML
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 3 catches an undocumented credential variable" "NOT_IN_ENV_EXAMPLE" "$out"
rm -rf "$T"

# 4. a JWK that differs between envs
T="$(mktemp -d)"; copy_tree "$T"
cat >> "$T/authorization-server.yaml" <<'YAML'
application.jwk:
  value: "compose-only-key"
  envs: [compose]
YAML
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 4 catches a per-env JWK" "application.jwk" "$out"
rm -rf "$T"

# 5. an unknown terraform output name in contexts/aws.yaml
T="$(mktemp -d)"; copy_tree "$T"
printf '\nbogus.ref: <terraform:no_such_output>\n' >> "$T/contexts/aws.yaml"
out="$(bash "$VALIDATE" --secrets-dir "$T" 2>&1)"
assert_contains "check 5 catches an unknown terraform output" "no_such_output" "$out"
rm -rf "$T"

echo; printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash deploy/secrets/tests/validate-test.sh`
Expected: FAIL — `deploy/scripts/secrets-validate.sh` does not exist.

- [ ] **Step 3: Write the validator**

`deploy/scripts/secrets-validate.sh` — a thin bash entry point over an embedded Python check, matching the repo's `deploy/scripts/*.sh` convention while keeping YAML parsing in Python:

```bash
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

for p in problems:
    print(f"FAIL: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash deploy/secrets/tests/validate-test.sh`
Expected: `6 passed, 0 failed`

- [ ] **Step 5: Re-run the equivalence test to confirm nothing regressed**

Run: `bash deploy/secrets/tests/equivalence-test.sh`
Expected: `33 passed, 0 failed, 0 pending`

- [ ] **Step 6: Commit**

```bash
git add deploy/scripts/secrets-validate.sh deploy/secrets/tests/validate-test.sh
git commit -m "feat(secrets): five consistency checks, no backend required

Each check corresponds to a bug class already seen in this repo: an
unresolvable reference (the missing spring.data.mongodb.database
crashloop), an orphaned context key from a rename, an undocumented
credential variable, a per-env JWK, and an unknown terraform output.

validate-test.sh corrupts a copy of the real tree once per check and
asserts that exactly that check fires — a guard nobody has watched fail
is not yet a guard."
```

---

### Task 6: `secrets-seed.sh` and the Makefile targets

**Files:**
- Create: `deploy/scripts/secrets-seed.sh`
- Modify: `Makefile`
- Modify: `deploy/README.md`

**Interfaces:**
- Consumes: `secrets_resolve.py`'s CLI (Task 2); the complete `deploy/secrets/` tree (Task 4).
- Produces: `make secrets-seed ENV=<env>`, `make secrets-validate`, `make secrets-render ENV=<env>`.

- [ ] **Step 1: Write the seeder**

`deploy/scripts/secrets-seed.sh`:

```bash
#!/usr/bin/env bash
# Resolve deploy/secrets/ and push it to this env's backend.
#
#   deploy/scripts/secrets-seed.sh --env compose|k8s|aws [--dry-run]
#                                  [--service NAME] [--refresh-tf]
#
# ALWAYS OVERWRITES. The canonical file is authoritative: a value edited there
# reaches the backend on the next run, and a value hand-edited in the backend
# does not survive one. That is the point of the phase — see
# docs/superpowers/specs/2026-08-06-canonical-secrets-design.md, decision 2.
#
# Resolution happens FIRST, in full. Nothing is pushed until every reference in
# every service resolves, because a partially-seeded backend is worse than an
# unseeded one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/deploy/scripts/lib/colors.sh"

ENV_NAME=""; DRY_RUN=0; SERVICE=""; REFRESH_TF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env)        ENV_NAME="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --service)    SERVICE="$2"; shift 2 ;;
    --refresh-tf) REFRESH_TF=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$ENV_NAME" in
  compose|k8s|aws) ;;
  *) echo "usage: secrets-seed.sh --env compose|k8s|aws [--dry-run] [--service NAME] [--refresh-tf]" >&2; exit 2 ;;
esac

TF_CACHE="$ROOT/deploy/.run/terraform-outputs.json"
TF_ARGS=()
if [ "$ENV_NAME" = "aws" ]; then
  mkdir -p "$ROOT/deploy/.run"
  if [ "$REFRESH_TF" -eq 1 ] || [ ! -f "$TF_CACHE" ]; then
    log_info "generating $TF_CACHE from terraform"
    terraform -chdir="$ROOT/aws/main" output -json > "$TF_CACHE" \
      || { log_err "terraform output failed — run 'terraform apply' first"; exit 1; }
  elif [ -n "$(find "$TF_CACHE" -mmin +1440 2>/dev/null)" ]; then
    # Warn, never auto-refresh: aws/main keeps state in an S3 remote backend
    # (aws/main/versions.tf:22), so there is no local file to compare against,
    # and an implicit terraform call mid-seed is the coupling this design removes.
    log_warn "$TF_CACHE is over 24h old — pass --refresh-tf if terraform has changed"
  fi
  TF_ARGS=(--tf-outputs "$TF_CACHE")
fi

RESOLVED="$(mktemp)"; trap 'rm -f "$RESOLVED"' EXIT
SVC_ARGS=(); [ -n "$SERVICE" ] && SVC_ARGS=(--service "$SERVICE")

python3 "$ROOT/deploy/scripts/lib/secrets_resolve.py" \
  --secrets-dir "$ROOT/deploy/secrets" --env "$ENV_NAME" \
  "${TF_ARGS[@]}" "${SVC_ARGS[@]}" > "$RESOLVED" || exit 1

if [ "$DRY_RUN" -eq 1 ]; then
  out="$ROOT/deploy/.run/secrets-$ENV_NAME.json"
  mkdir -p "$ROOT/deploy/.run"; cp "$RESOLVED" "$out"; chmod 600 "$out"
  # The path, never the content — this file holds resolved secrets.
  log_ok "resolved map written to $out ($(jq -r 'keys | length' "$out") services)"
  exit 0
fi

vault_push() {  # vault_push <addr> <token>
  local addr="$1" token="$2" svc payload
  for svc in $(jq -r 'keys[]' "$RESOLVED"); do
    payload="$(jq --arg s "$svc" '{data: .[$s]}' "$RESOLVED")"
    curl -sf -X POST -H "X-Vault-Token: $token" -d "$payload" \
      "$addr/v1/secret/data/$svc" >/dev/null \
      || { log_err "vault write failed for secret/$svc"; return 1; }
    log_ok "secret/$svc"
  done
}

case "$ENV_NAME" in
  compose)
    # load_vault_token() lives in scripts/lib/env.sh (NOT a vault-token.sh) and
    # reads VAULT_TOKEN out of docker/.env, which vault-init.sh keeps in sync.
    . "$ROOT/scripts/lib/env.sh" && load_vault_token 2>/dev/null || true
    : "${VAULT_TOKEN:?VAULT_TOKEN not set — run 'make vault-login' or set it}"
    vault_push "${VAULT_ADDR:-http://localhost:8200}" "$VAULT_TOKEN" || exit 1
    ;;
  k8s)
    # Vault is a ClusterIP Service; forward it for the duration of the push.
    # The `vault` CLI is not installed on the host, so this uses the same HTTP
    # API as the compose path — one push implementation for both envs.
    # The in-cluster Vault runs in dev mode with the literal root token `root`
    # (k8s/infra/jobs/03-vault-seed/job.yaml:19), so this needs no lookup.
    : "${VAULT_TOKEN:=root}"
    kubectl -n infra port-forward svc/vault 18200:8200 >/dev/null 2>&1 &
    pf=$!; trap 'kill $pf 2>/dev/null; rm -f "$RESOLVED"' EXIT
    for _ in $(seq 1 30); do
      curl -sf "http://127.0.0.1:18200/v1/sys/health" >/dev/null 2>&1 && break
      /bin/sleep 1
    done
    vault_push "http://127.0.0.1:18200" "$VAULT_TOKEN" || exit 1
    ;;
  aws)
    region="${AWS_REGION:-ap-southeast-1}"
    for svc in $(jq -r 'keys[]' "$RESOLVED"); do
      aws secretsmanager put-secret-value --region "$region" \
        --secret-id "app/$svc" \
        --secret-string "$(jq -c --arg s "$svc" '.[$s]' "$RESOLVED")" >/dev/null \
        || { log_err "secret app/$svc not found — run 'terraform apply' first"; exit 1; }
      log_ok "app/$svc"
    done
    ;;
esac

log_ok "seeded $ENV_NAME"
```

- [ ] **Step 2: Verify `--dry-run` reaches the backend-free path for all three envs**

Run:
```bash
set -a; . deploy/secrets/tests/fixtures/user-creds.env; set +a
export APPLICATION_JWK="$(jq -r '."application.jwk"' docker/vault-configs/authorization-server.json)"
cp deploy/secrets/tests/fixtures/terraform-outputs.json deploy/.run/terraform-outputs.json 2>/dev/null || \
  { mkdir -p deploy/.run && cp deploy/secrets/tests/fixtures/terraform-outputs.json deploy/.run/terraform-outputs.json; }
for e in compose k8s aws; do bash deploy/scripts/secrets-seed.sh --env "$e" --dry-run; done
```
Expected: three `resolved map written to …/deploy/.run/secrets-<env>.json (11 services)` lines, no network access, and no secret value printed.

- [ ] **Step 3: Confirm the dry-run output is not world-readable and is git-ignored**

Run: `ls -l deploy/.run/secrets-*.json && git status --porcelain deploy/.run/`
Expected: mode `-rw-------` on each file, and **empty** git status output (`deploy/.run/` is already ignored; if it is not, add it in this step).

- [ ] **Step 4: Add the Makefile targets**

Append to the secrets section of `Makefile`:

```make
.PHONY: secrets-seed secrets-validate secrets-render
# Canonical secrets (deploy/secrets/). ENV=compose|k8s|aws, default compose.
# ALWAYS OVERWRITES the backend — the canonical file is authoritative.
secrets-seed:
	@bash deploy/scripts/secrets-seed.sh --env $(or $(ENV),compose)

# Resolve only. Writes deploy/.run/secrets-<env>.json; touches no backend.
secrets-render:
	@bash deploy/scripts/secrets-seed.sh --env $(or $(ENV),compose) --dry-run

# Consistency checks. No backend, no credentials — safe to run anywhere.
secrets-validate:
	@bash deploy/scripts/secrets-validate.sh
```

- [ ] **Step 5: Verify the targets resolve**

Run: `make -n secrets-seed ENV=k8s && make -n secrets-validate && make -n secrets-render ENV=aws`
Expected: each prints its `bash …` command with the right `--env`, and `make` reports no missing-target error.

- [ ] **Step 6: Document in `deploy/README.md`**

Add a section covering: the three targets; that `secrets-seed` **always overwrites**, so a hand-edited backend value does not survive the next run and belongs in the canonical file; that `ENV=k8s` opens a temporary port-forward and needs `VAULT_TOKEN`; that `ENV=aws` reads `deploy/.run/terraform-outputs.json` and takes `--refresh-tf`; and that the old paths (`make vault-import`, the `03-vault-seed` Job, `scripts/aws/seed-secrets.sh`) still work and are removed in Phase 8.

- [ ] **Step 7: Commit**

```bash
git add deploy/scripts/secrets-seed.sh Makefile deploy/README.md
git commit -m "feat(secrets): secrets-seed.sh and the make targets

Resolves in full before pushing anything, so an unresolvable reference
cannot leave a half-seeded backend. Compose and k8s share one push
implementation over the Vault HTTP API — the vault CLI is not installed
on the host, and k8s gets an ephemeral kubectl port-forward for the
duration of the write.

--dry-run writes deploy/.run/secrets-<env>.json mode 600 and logs only
the path; resolved secrets never reach stdout or a log line."
```

---

### Task 7: Live transport verification

Equivalence is already proved offline. This task proves only that the writes land and the services come up.

**Files:**
- Modify: `deploy/README.md` (record the verification result)
- Create: `.superpowers/sdd/p4-task-7-report.md` (report only; not committed)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: evidence for the PR body. No code changes unless a defect is found.

- [ ] **Step 1: Verify the whole offline suite from a clean tree**

Run:
```bash
bash deploy/secrets/tests/resolver-test.sh
bash deploy/secrets/tests/validate-test.sh
bash deploy/secrets/tests/equivalence-test.sh
bash deploy/charts/microecom/tests/render-test.sh 2>&1 | tail -3
```
Expected: `15 passed, 0 failed`; `6 passed, 0 failed`; `33 passed, 0 failed, 0 pending`; and the Helm suite still `268 passed, 0 failed` — this phase must not touch the chart.

- [ ] **Step 2: Confirm the constraint that defines this phase**

Run: `git diff main HEAD --stat -- docker/ scripts/ k8s/ deploy/charts/`
Expected: **empty output**. Old paths untouched, chart untouched.

- [ ] **Step 3: Seed compose and prove the app comes up**

Run:
```bash
make infra-up && make vault-unseal
make secrets-seed ENV=compose
make up
make status
```
Expected: every service healthy. Record the `make status` table in the report.

- [ ] **Step 4: Prove compose equivalence at the backend, not just on paper**

Read each path back out of the live Vault and diff against the golden:

```bash
python3 - <<'PY'
import json, os, subprocess
addr = os.environ.get("VAULT_ADDR", "http://localhost:8200")
token = os.environ["VAULT_TOKEN"]
golden = json.load(open("deploy/secrets/tests/golden/compose.json"))
bad = []
for svc in golden:
    out = subprocess.run(
        ["curl", "-sf", "-H", f"X-Vault-Token: {token}",
         f"{addr}/v1/secret/data/{svc}"], capture_output=True, text=True).stdout
    live = json.loads(out)["data"]["data"]
    if live != golden[svc]:
        # Key names only — never values.
        bad.append((svc, sorted(set(golden[svc]) ^ set(live)),
                    sorted(k for k in golden[svc] if live.get(k) != golden[svc][k])))
print("compose backend matches golden" if not bad else f"MISMATCH: {bad}")
PY
```
Expected: `compose backend matches golden`

- [ ] **Step 5: Seed k8s and prove the services come up**

Run:
```bash
make k8s-cluster-up && make k8s-infra-helm
# The in-cluster Vault runs in dev mode; the root token is the literal string
# `root` (k8s/infra/jobs/03-vault-seed/job.yaml:19). secrets-seed.sh defaults
# to it, so no export is needed — this line is only for an override.
make secrets-seed ENV=k8s
make k8s-build-reuse && make k8s-apps-helm
kubectl -n apps get pods
```
Expected: all ten Deployments rolled out, restart counts `0`. Record the pod table.

- [ ] **Step 6: Prove the two failure modes that motivated the phase are gone**

The three documented crashloops were all silent-missing-value. Confirm the gateway resolved its route URIs and the auth server its token lifetimes:

```bash
kubectl -n apps logs deploy/gateway --tail=200 | grep -ic "could not resolve placeholder" || true
kubectl -n apps logs deploy/authorization-server --tail=200 | grep -ic "could not resolve placeholder" || true
```
Expected: `0` from both.

- [ ] **Step 7: Record what is NOT proven**

Write into the report and the PR body, verbatim:

> AWS transport is unproven. `secrets-seed.sh --env=aws` has been verified only
> against fixture terraform outputs with a shimmed `aws` CLI. No AWS Secrets
> Manager write has been executed. Live AWS seeding is Phase 7.

- [ ] **Step 8: Commit the README result note**

```bash
git add deploy/README.md
git commit -m "docs(deploy): record Phase 4 live verification results

Compose and k8s transports verified end to end: seeded backends read back
byte-identical to the golden capture, all services start, and zero
'could not resolve placeholder' lines appear in the gateway or
authorization-server logs — the exact failure the three documented
crashloops produced.

AWS transport remains unproven and is explicitly Phase 7's."
```

---

## Acceptance Criteria

- [ ] `bash deploy/secrets/tests/resolver-test.sh` → `15 passed, 0 failed`
- [ ] `bash deploy/secrets/tests/validate-test.sh` → `6 passed, 0 failed`
- [ ] `bash deploy/secrets/tests/equivalence-test.sh` → `33 passed, 0 failed, 0 pending`
- [ ] `bash deploy/charts/microecom/tests/render-test.sh` → `268 passed, 0 failed`
- [ ] `git diff main HEAD -- docker/ scripts/ k8s/ deploy/charts/` is **empty**
- [ ] `make secrets-validate` exits 0
- [ ] `make up` works after `make secrets-seed ENV=compose`
- [ ] All ten k8s Deployments roll out after `make secrets-seed ENV=k8s`, restarts `0`
- [ ] No secret value appears in any test output, log line, commit message, or committed file
- [ ] The PR body states that AWS transport is unproven and deferred to Phase 7
