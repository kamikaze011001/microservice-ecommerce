#!/usr/bin/env bash
# Capture what each of the three OLD seed paths actually writes, with no live
# backend — the oracle deploy/seed/tests/golden/<env>.json that every later
# consolidation task is measured against. See task-1-report.md for the full
# design writeup (why /seed-parameterised fixture copies exist, why mongosh
# and terraform needed shims the brief's list omitted, and per-env counts).
#
#   bash deploy/seed/tests/capture-golden.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

chmod +x "$HERE/shims/"* "$HERE/fixtures/"*.sh
mkdir -p "$HERE/golden"

# ── Fidelity guard ───────────────────────────────────────────────────────────
# The two k8s Job seed.sh files hardcode `/seed/...` — a path this sandboxed
# macOS host cannot create (root fs is read-only; see task-1-report.md). The
# fixture copies below are byte-identical to the tracked k8s/ originals except
# for that one substitution. Fail loudly, not silently, if the tracked files
# ever drift out from under these copies.
check_fixture() {
  local orig="$1" fixture="$2"
  if ! diff -q \
      <(sed 's#\${SEED_ROOT:-/seed}/#/seed/#g' "$fixture") \
      "$orig" >/dev/null; then
    echo "FAIL: $fixture has drifted from $orig (more than the /seed/ substitution differs)" >&2
    exit 1
  fi
}
check_fixture "$ROOT/k8s/infra/jobs/01-mysql-seed/seed.sh" "$HERE/fixtures/01-mysql-seed.sh"
check_fixture "$ROOT/k8s/infra/jobs/02-mongo-seed/seed.sh" "$HERE/fixtures/02-mongo-seed.sh"

export TF_FIXTURE="$HERE/fixtures/terraform-outputs.json"
export REPO_ROOT="$ROOT"
export PATH="$HERE/shims:$PATH"

run_compose() {
  bash "$ROOT/scripts/seed/all.sh" >/dev/null
}

run_k8s() {
  local seed_root="$1"
  mkdir -p "$seed_root"
  cp "$ROOT/docker/ecommerce.sql" "$seed_root/"
  cp "$ROOT/docker/api_role.json" "$seed_root/"
  cp "$ROOT/docker/product.json" "$seed_root/"
  cp "$ROOT/docker/product-quantity-history.json" "$seed_root/"

  SEED_ROOT="$seed_root" MYSQL_ROOT_PASSWORD=fixture \
    sh "$HERE/fixtures/01-mysql-seed.sh" >/dev/null

  SEED_ROOT="$seed_root" MONGO_URI="mongodb://fixture:fixture@mongo.infra.svc.cluster.local:27017/ecommerce_inventory" \
    sh "$HERE/fixtures/02-mongo-seed.sh" >/dev/null

  # Runs unmodified — no /seed dependency (bucket + policy only, no uploads).
  sh "$ROOT/k8s/infra/jobs/05-minio-bootstrap/seed.sh" >/dev/null

  bash "$ROOT/scripts/seed/k8s-product-images.sh" >/dev/null
  bash "$ROOT/scripts/seed/k8s-inventory.sh" >/dev/null
}

run_aws() {
  export AWS_PROFILE=microecom
  bash "$ROOT/scripts/aws/seed-rds.sh" >/dev/null
  bash "$ROOT/scripts/aws/seed-inventory.sh" >/dev/null
  bash "$ROOT/scripts/aws/seed-mongo.sh" >/dev/null
  bash "$ROOT/scripts/aws/seed-images.sh" >/dev/null
  # scripts/aws/up-all.sh step 8's reconcile (lines ~178-180) — replayed
  # verbatim rather than running the ~700-line orchestrator that produces it
  # (VPC/EKS/ALB/DNS work well outside this task's offline-capture scope).
  kubectl -n apps rollout restart deploy/inventory-service >/dev/null
  kubectl -n apps rollout status deploy/inventory-service --timeout=300s >/dev/null
}

capture_env() {
  local env="$1"
  local capture_dir
  capture_dir="$(mktemp -d)"
  export SEED_CAPTURE_DIR="$capture_dir"

  case "$env" in
    compose) run_compose ;;
    k8s)     run_k8s "$capture_dir/seed-root" ;;
    aws)     run_aws ;;
  esac

  python3 "$HERE/assemble-golden.py" --env "$env" --capture-dir "$capture_dir" \
    --out "$HERE/golden/$env.json"

  rm -rf "$capture_dir"
  unset SEED_CAPTURE_DIR
}

for env in compose k8s aws; do
  echo "==> capturing $env"
  capture_env "$env"
done

echo "golden artifacts written to $HERE/golden"

# ── Self-check (mirrors task-1-brief.md Steps 3-4) ──────────────────────────
python3 - "$HERE/golden" <<'PY'
import json, re, sys
golden_dir = sys.argv[1]

for env in ("compose", "k8s", "aws"):
    g = json.load(open(f"{golden_dir}/{env}.json"))
    n = len([s for s in g["mysql"] if "inventory_product" in s])
    assert n == 30, f"{env}: {n} inventory_product INSERTs, expected 30"
print("golden counts OK")

hosts = {}
for env in ("compose", "k8s", "aws"):
    g = json.load(open(f"{golden_dir}/{env}.json"))
    blob = " ".join(g["mysql"])
    # https? — aws's media host is https://, so an http-only pattern silently
    # matched NOTHING for aws and left 1 of 3 envs unchecked by this assertion.
    hosts[env] = sorted(set(re.findall(r'https?://([^/"]+)/', blob)))
print(hosts)
for env in ("compose", "k8s", "aws"):
    assert hosts[env], f"{env}: no media host found — the capture or this pattern is wrong"
# Three-way disagreement is the premise of this whole phase: one value, three
# implementations. Asserting only one pair would pass while two envs agreed.
assert len({tuple(v) for v in hosts.values()}) == 3, f"all three media hosts must differ: {hosts}"
print("three-way media-host disagreement confirmed")
PY
