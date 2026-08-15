#!/usr/bin/env bash
# Layer A — offline differential render: does the Helm chart's aws-with-apps
# output reproduce the composed AWS oracle, object by object?
#
#   ./deploy/charts/microecom/tests/aws-diff-test.sh
#
# render-test.sh:826-836 already renders apps with envs/aws.yaml and asserts
# individual properties (ALB annotations, IRSA, ESO). Nothing compares the
# chart's WHOLE output to the AWS overlay object-by-object — that is what
# this script closes. See docs/superpowers/specs/2026-08-12-aws-cutover-design.md
# §1 CORRECTION and §4.
#
# LEFT  = `helm template ... -f envs/aws.yaml --set apps.enabled=true
#          --set infra.enabled=false` (`--set apps.enabled=true` is
#          LOAD-BEARING — the apps subchart defaults to false, and without
#          this flag the render silently collapses to 3 objects instead of
#          ~43, which is exactly the controller's own withdrawn premise this
#          phase corrects. `--namespace infra` was an earlier, ALSO WRONG
#          explanation for that same collapse — measured to make NO
#          difference, 43 either way — see design doc §1 CORRECTION).
# RIGHT = tests/aws-oracle/oracle.yaml, captured by capture.sh from
#          `kubectl kustomize k8s/apps/overlays/aws` PLUS the out-of-band
#          s3-irsa-serviceaccounts.yaml (D1). Nothing here touches a live
#          cluster or costs money: `kubectl kustomize` is pure local build,
#          and helm template never contacts a cluster either.
#
# Comparison is by (kind, name), not raw text — Helm and kustomize order and
# label documents differently, and a raw-text diff would flag literally every
# shared object over label-scheme noise alone. A NORMALIZE step (below)
# strips only what is provably tooling noise (label scheme, list ordering);
# it never removes or reorders anything that changes runtime behaviour.
#
# Every remaining difference is either:
#   - a whole object only on one side (declared, direction-asserted), or
#   - a shared object whose content differs in an understood, declared way
#     (each with an explicit assertion of the RAW difference plus a
#     regression check — see equivalence-test.sh's DECLARED pattern, which
#     this mirrors), or
#   - FAIL, unexplained.
#
# Guard (MANDATORY, step 2 of the task brief): both sides must be non-empty
# AND the per-kind object counts must match a known-good floor before any
# diffing happens. Seven "empty result masquerading as a negative result"
# defects have landed across Phases 5 and 6, several inside guards written to
# prevent them, and the controller's own error this phase was exactly this
# shape (a 4-object render read as a real, if surprising, result). A
# collapsed side must fail loudly here, never quietly diff against 4 objects.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$HERE/.." && pwd)"
ORACLE="$HERE/aws-oracle/oracle.yaml"
FIXTURE="$HERE/fixtures/aws-tf-outputs.json"

RED='\033[31m'; RESET='\033[0m'

fail_loud() { printf "${RED}FAIL${RESET} %s\n" "$1" >&2; exit 1; }

command -v helm    >/dev/null || fail_loud "helm not found"
command -v jq      >/dev/null || fail_loud "jq not found"
command -v python3 >/dev/null || fail_loud "python3 not found"
[[ -f "$ORACLE" ]]  || fail_loud "oracle not found: $ORACLE (run tests/aws-oracle/capture.sh)"
[[ -f "$FIXTURE" ]] || fail_loud "fixture not found: $FIXTURE"

# s3_irsa_role_arn IS genuinely fixture-driven on the oracle side too: capture.sh
# substitutes it into PLACEHOLDER_S3_ROLE_ARN via the exact sed up-all.sh uses.
# Matching it here is what D1/the task brief means by "so both sides are
# comparable" for THIS input.
S3_ROLE_ARN="$(jq -r '.s3_irsa_role_arn' "$FIXTURE")"
[[ -n "$S3_ROLE_ARN" && "$S3_ROLE_ARN" != "null" ]] || fail_loud "fixture missing s3_irsa_role_arn"

# The ECR registry + image tag are NOT fixture-driven on the oracle side: the
# old kustomize overlay hardcodes them directly in each service's
# kustomization.yaml `images:` transformer (k8s/apps/overlays/aws/*/kustomization.yaml),
# not from any terraform output (the fixture's `ecr_registry` key exists but
# capture.sh never reads it — verified: `grep ecr_registry tests/aws-oracle/capture.sh`
# has no hits). Using the fixture's ecr_registry here would manufacture a
# spurious image mismatch across all 10 Deployments — exactly the kind of
# self-inflicted, uninformative "difference" the anti-vacuous-comparison
# principle warns against. Instead, extract the registry+tag mechanically FROM
# THE ORACLE ITSELF (one Deployment's image field), so this script tracks
# oracle.yaml automatically if capture.sh is ever re-run against a changed
# account/tag — never a hand-transcribed literal (see design doc §5 Risks:
# "the oracle drifts").
read -r IMAGE_REGISTRY IMAGE_TAG <<<"$(python3 - "$ORACLE" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for d in docs:
    if d.get("kind") == "Deployment" and d.get("metadata", {}).get("name") == "gateway":
        img = d["spec"]["template"]["spec"]["containers"][0]["image"]
        registry, rest = img.split("/", 1)
        _, tag = rest.rsplit(":", 1)
        print(registry, tag)
        sys.exit(0)
sys.exit("gateway Deployment not found in oracle")
PY
)"
[[ -n "$IMAGE_REGISTRY" && -n "$IMAGE_TAG" ]] || fail_loud "could not extract image registry/tag from oracle"

CHART_OUT="$(mktemp)"
trap 'rm -f "$CHART_OUT"' EXIT

# --namespace infra is LOAD-BEARING (see header). --set-string for all three:
# plain --set treats dots as path separators, so an ECR hostname like
# 583178372344.dkr.ecr... silently becomes nested keys instead of a string
# (design doc §5 Risks) — this produced two wrong renders during design.
render_out="$(helm template microecom "$CHART_DIR" --namespace infra \
  -f "$CHART_DIR/envs/aws.yaml" \
  --set apps.enabled=true --set infra.enabled=false \
  --set-string apps.irsa.s3RoleArn="$S3_ROLE_ARN" \
  --set-string global.appImage.registry="$IMAGE_REGISTRY" \
  --set-string global.appImage.tag="$IMAGE_TAG" 2>&1)"
render_status=$?

if [[ $render_status -ne 0 ]] || grep -qiE '^Error:|template:.*(error|not defined)' <<<"$render_out"; then
  fail_loud "helm template failed (exit $render_status):
$(head -20 <<<"$render_out")"
fi

printf '%s\n' "$render_out" > "$CHART_OUT"

python3 - "$ORACLE" "$CHART_OUT" <<'PY'
import copy, json, sys
import yaml

oracle_path, chart_path = sys.argv[1], sys.argv[2]

GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"


def load(path):
    return [d for d in yaml.safe_load_all(open(path)) if d]


oracle_docs = load(oracle_path)
chart_docs = load(chart_path)


def key(d):
    return (d.get("kind"), d.get("metadata", {}).get("name"))


# ── Guard (MANDATORY) — both sides non-empty AND plausible, before ANY diff. ──
# A chart render that silently collapsed to 4 objects (the controller's own
# withdrawn premise) must fail HERE, loudly and by name, never fall through
# to a diff of two near-empty streams.
FLOOR = 39  # "the oracle has 39+" (task brief step 2)
REQUIRED_KIND_COUNTS = {  # every kind except Namespace — see design doc's
    "Service": 10,        # "Measured state today" table. Namespace is the
    "Deployment": 10,     # one declared, direction-asserted exception,
    "ExternalSecret": 9,  # handled in the object-presence section below.
    "HorizontalPodAutoscaler": 5,
    "ServiceAccount": 3,
    "Role": 1,
    "RoleBinding": 1,
    "Ingress": 1,
}

guard_failures = []


def kind_counts(docs):
    c = {}
    for d in docs:
        c[d.get("kind")] = c.get(d.get("kind"), 0) + 1
    return c


oracle_kinds = kind_counts(oracle_docs)
chart_kinds = kind_counts(chart_docs)

if len(oracle_docs) < FLOOR:
    guard_failures.append(f"oracle has only {len(oracle_docs)} objects (floor {FLOOR}) -- oracle.yaml may be stale or truncated")
if len(chart_docs) < FLOOR:
    guard_failures.append(f"chart render has only {len(chart_docs)} objects (floor {FLOOR}) -- this is the Task-2-class collapse (missing --set apps.enabled=true renders 3, not ~43)")

for kind, expected in REQUIRED_KIND_COUNTS.items():
    o_n, c_n = oracle_kinds.get(kind, 0), chart_kinds.get(kind, 0)
    if o_n != expected:
        guard_failures.append(f"oracle {kind} count is {o_n}, expected {expected}")
    if c_n != expected:
        guard_failures.append(f"chart {kind} count is {c_n}, expected {expected}")

if guard_failures:
    print(f"{RED}FAIL{RESET} vacuous-comparison guard tripped -- refusing to diff:")
    for msg in guard_failures:
        print(f"  {RED}FAIL{RESET} {msg}")
    sys.exit(1)

print(f"guard: oracle {len(oracle_docs)} objects, chart {len(chart_docs)} objects, "
      f"both >= {FLOOR}; all {len(REQUIRED_KIND_COUNTS)} required kind counts match  -> {GREEN}ok{RESET}")

oracle_map = {key(d): d for d in oracle_docs}
chart_map = {key(d): d for d in chart_docs}

# ── Object presence: whole objects only on one side. ────────────────────────
# The umbrella's templates/namespaces.yaml renders all 3 non-infra namespaces
# regardless of env -- pre-existing, unrelated to AWS (design doc §1
# CORRECTION). Declared and direction-asserted: FAILS if either Namespace
# ever also appears in the oracle (the difference reverting) or ever stops
# appearing in the chart (the difference silently vanishing).
DECLARED_ONLY_IN_CHART = {
    ("Namespace", "bootstrap"): "umbrella renders all 3 non-infra namespaces (namespaces.yaml, pre-existing, unrelated to AWS)",
    ("Namespace", "monitoring"): "umbrella renders all 3 non-infra namespaces (namespaces.yaml, pre-existing, unrelated to AWS)",
}
DECLARED_ONLY_IN_ORACLE = {}

presence_results = []  # (status, detail)

for k, desc in DECLARED_ONLY_IN_CHART.items():
    in_chart, in_oracle = k in chart_map, k in oracle_map
    if in_chart and not in_oracle:
        presence_results.append(("declared", f"{k[0]}/{k[1]}  only in chart -> {desc}"))
    elif in_chart and in_oracle:
        presence_results.append(("FAIL", f"{k[0]}/{k[1]}: declared chart-only but now ALSO in oracle -- the difference may have reverted"))
    else:
        presence_results.append(("FAIL", f"{k[0]}/{k[1]}: declared chart-only but not found in chart -- the difference may have vanished"))

for k, desc in DECLARED_ONLY_IN_ORACLE.items():
    in_chart, in_oracle = k in chart_map, k in oracle_map
    if in_oracle and not in_chart:
        presence_results.append(("declared", f"{k[0]}/{k[1]}  only in oracle -> {desc}"))
    elif in_chart and in_oracle:
        presence_results.append(("FAIL", f"{k[0]}/{k[1]}: declared oracle-only but now ALSO in chart -- the difference may have reverted"))
    else:
        presence_results.append(("FAIL", f"{k[0]}/{k[1]}: declared oracle-only but not found in oracle -- the difference may have vanished"))

undeclared_only_chart = (set(chart_map) - set(oracle_map)) - set(DECLARED_ONLY_IN_CHART)
undeclared_only_oracle = (set(oracle_map) - set(chart_map)) - set(DECLARED_ONLY_IN_ORACLE)
for k in sorted(undeclared_only_chart):
    presence_results.append(("FAIL", f"{k[0]}/{k[1]}: only in chart, UNDECLARED"))
for k in sorted(undeclared_only_oracle):
    presence_results.append(("FAIL", f"{k[0]}/{k[1]}: only in oracle, UNDECLARED"))

common_keys = sorted(set(chart_map) & set(oracle_map))

# ── Content normalization — strips ONLY provable tooling noise. ─────────────
# Helm stamps app.kubernetes.io/* labels + selectors; the old kustomize base
# stamps a bare `app` label. Both schemes are internally self-consistent
# (each side's Service selector matches its own Deployment's pod-template
# labels) -- the SCHEME differs, not the wiring. Env/port/ingress-path list
# order also differs between the two renderers and carries no meaning.
# Nothing that affects runtime behaviour (image, env VALUES, replicas,
# resources, probes, ESO/IRSA/ALB annotations, ports, hosts) is touched.
def normalize(doc):
    d = copy.deepcopy(doc)
    md = d.get("metadata", {})
    md.pop("labels", None)
    ann = md.get("annotations")
    if isinstance(ann, dict):
        for a in list(ann):
            if a.startswith("meta.helm.sh/"):
                ann.pop(a)
        if not ann:
            md.pop("annotations", None)
    spec = d.get("spec")
    if isinstance(spec, dict):
        spec.pop("selector", None)  # bare Service selector OR Deployment matchLabels
        tmpl = spec.get("template")
        if isinstance(tmpl, dict) and isinstance(tmpl.get("metadata"), dict):
            tmpl["metadata"].pop("labels", None)
            cspec = tmpl.get("spec", {})
            for c in cspec.get("containers", []) or []:
                if "env" in c:
                    c["env"] = sorted(c["env"], key=lambda e: e.get("name", ""))
                if "ports" in c:
                    c["ports"] = sorted(c["ports"], key=lambda p: p.get("name", ""))
        for rule in spec.get("rules", []) or []:
            http = rule.get("http")
            if isinstance(http, dict) and "paths" in http:
                http["paths"] = sorted(http["paths"], key=lambda p: p.get("path", ""))
    return d


def main_container(doc):
    name = doc["metadata"]["name"]
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if c.get("name") == name:
            return c
    return doc["spec"]["template"]["spec"]["containers"][0]


# ── Declared content differences — shared objects that legitimately differ. ──
# Each handler takes the two NORMALIZED docs and returns
# (chart_adjusted, oracle_adjusted, description, raw_diff_matches_expected).
# `raw_diff_matches_expected` is the "matches reality" check (mirrors
# equivalence-test.sh's DECLARED pattern): if it's False the *specific*
# understood difference isn't what's actually there, so this must FAIL rather
# than silently accept some other, unexplained difference under the same label.

def vault_leftover(c, o):
    extra = {"VAULT_TOKEN", "SPRING_CLOUD_VAULT_URI"}
    c_env = main_container(c).get("env", [])
    o_env = main_container(o).get("env", [])
    c_names = {e["name"] for e in c_env}
    o_names = {e["name"] for e in o_env}
    ok = extra <= o_names and not (extra & c_names)
    o2 = copy.deepcopy(o)
    main_container(o2)["env"] = [e for e in o_env if e["name"] not in extra]
    desc = ("oracle-only env VAULT_TOKEN,SPRING_CLOUD_VAULT_URI -- leftover from the "
            "shared local-dev base manifest (k8s/apps/base/*/deployment.yaml), never "
            "stripped by the aws overlay; AWS has no in-cluster Vault (ESO backend), "
            "chart correctly omits them")
    return c, o2, desc, ok


def frontend_probe_threshold(c, o):
    cc, oc = main_container(c), main_container(o)
    c_live, c_ready = cc.get("livenessProbe", {}), cc.get("readinessProbe", {})
    o_live, o_ready = oc.get("livenessProbe", {}), oc.get("readinessProbe", {})
    ok = ("failureThreshold" in c_live and "failureThreshold" in c_ready
          and "failureThreshold" not in o_live and "failureThreshold" not in o_ready
          and c_live["failureThreshold"] == 4 and c_ready["failureThreshold"] == 6)
    c2 = copy.deepcopy(c)
    c2c = main_container(c2)
    c2c.get("livenessProbe", {}).pop("failureThreshold", None)
    c2c.get("readinessProbe", {}).pop("failureThreshold", None)
    desc = ("chart sets explicit probe failureThreshold (liveness=4, readiness=6); "
            "oracle's base manifest omits it (k8s default=3) -- deliberate inherited "
            "value, documented in charts/apps/values.yaml's frontend.probes comment")
    return c2, o, desc, ok


def alb_frontend_port_style(c, o):
    def frontend_backend_port(ing):
        for rule in ing["spec"]["rules"]:
            for p in rule["http"]["paths"]:
                if p["path"] == "/":
                    return p["backend"]["service"]["port"]
        return None

    c_port = frontend_backend_port(c)
    o_port = frontend_backend_port(o)
    ok = c_port == {"name": "http"} and o_port == {"number": 80}
    c2 = copy.deepcopy(c)
    for rule in c2["spec"]["rules"]:
        for p in rule["http"]["paths"]:
            if p["path"] == "/":
                p["backend"]["service"]["port"] = {"number": 80}
    desc = ("frontend catch-all backend: chart references the Service port by name "
            "(name: http), oracle's hand-authored ingress-gateway.yaml uses the port "
            "NUMBER (number: 80) for this one path only -- every other backend in the "
            "same oracle file already uses name: http; same Service, same port, "
            "cosmetic inconsistency in the old file")
    return c2, o, desc, ok


def hpa_no_replicas(c, o):
    """The chart omits spec.replicas on any Deployment that has an HPA; the oracle
    sets it. The chart is more correct, and this one is not cosmetic — it broke a
    real bootstrap.

    Once an HPA scales a Deployment, kube-controller-manager takes ownership of
    `.spec.replicas` via the `scale` subresource. A chart that also declares the
    field then loses a server-side-apply ownership fight and fails the WHOLE
    release:

      UPGRADE FAILED: conflict occurred while applying object apps/gateway
      Kind=Deployment: conflict with "kube-controller-manager" with subresource
      "scale" using apps/v1: .spec.replicas

    It cannot happen on a first install, only on an upgrade after the HPA has
    acted, which is why it survived every prior verification. Found 2026-08-15
    (Phase 8 Task 7) on the first from-scratch k8s bootstrap.

    The oracle (the old kustomize aws overlay) still carries the bug. If this
    check ever starts MATCHING, that means the chart has re-added `replicas` and
    the release-breaking conflict is back — so it must FAIL, not be skipped.
    """
    ok = ("replicas" not in c["spec"]) and (o["spec"].get("replicas") is not None)
    o2 = copy.deepcopy(o)
    o2["spec"].pop("replicas", None)
    desc = ("oracle sets spec.replicas on an HPA-managed Deployment; chart omits it -- "
            "declaring it loses a server-side-apply ownership fight with "
            "kube-controller-manager's `scale` subresource and fails the entire helm "
            "release on any upgrade after the HPA has scaled")
    return c, o2, desc, ok


def compose(*handlers):
    """Apply several declared-difference handlers to the same object.

    Each handler narrows the docs further; ALL must report their own difference
    as actually present, so one reverting still fails the suite rather than being
    masked by its neighbour."""
    def composed(c, o):
        descs, all_ok = [], True
        for h in handlers:
            c, o, d, ok = h(c, o)
            descs.append(d)
            all_ok = all_ok and ok
        return c, o, "; ".join(descs), all_ok
    return composed


# The 5 services carrying an `hpa:` block (charts/apps/values.yaml). They also
# carry the vault-leftover difference, so their two declared differences compose.
_HPA_SERVICES = ("authorization-server", "gateway", "inventory-service",
                 "order-service", "product-service")

CONTENT_DECLARED = {}
for _name in ("authorization-server", "bff-service", "gateway", "inventory-service",
              "orchestrator-service", "order-service", "payment-service", "product-service"):
    CONTENT_DECLARED[("Deployment", _name)] = (
        compose(vault_leftover, hpa_no_replicas) if _name in _HPA_SERVICES
        else vault_leftover)
CONTENT_DECLARED[("Deployment", "frontend")] = frontend_probe_threshold
CONTENT_DECLARED[("Ingress", "gateway-alb")] = alb_frontend_port_style


def diff_paths(a, b, prefix="", limit=5):
    """Short list of dotted paths that differ -- never a full blob (requirement 5).
    Lists of dicts carrying a `name` key (env vars, ports, containers, ...) are
    matched by name and recursed into, so e.g. a changed env var reads as
    `...env[VAULT_TOKEN]: 'root' vs <absent>`, not a bare list-length noise line."""
    out = []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            out += diff_paths(a.get(k, "<absent>"), b.get(k, "<absent>"), f"{prefix}.{k}" if prefix else str(k), limit)
    elif isinstance(a, list) and isinstance(b, list) and a != b:
        if all(isinstance(x, dict) and "name" in x for x in a + b):
            a_by_name = {x["name"]: x for x in a}
            b_by_name = {x["name"]: x for x in b}
            for name in sorted(set(a_by_name) | set(b_by_name)):
                out += diff_paths(a_by_name.get(name, "<absent>"), b_by_name.get(name, "<absent>"),
                                   f"{prefix}[{name}]", limit)
        else:
            out.append(f"{prefix} ({len(a)} vs {len(b)} items)")
    elif a != b:
        out.append(f"{prefix}: {a!r} vs {b!r}")
    return out[:limit]


content_results = []  # (status, detail)
matched = 0

for k in common_keys:
    c_norm = normalize(chart_map[k])
    o_norm = normalize(oracle_map[k])
    handler = CONTENT_DECLARED.get(k)

    if c_norm == o_norm:
        if handler is not None:
            # Regression: this object is declared to differ from the oracle in a
            # specific, understood way, but it now matches exactly -- the fix (or
            # a later edit) may have reverted the intended difference. An
            # exclusion list would let this happen silently; this must FAIL.
            content_results.append(("FAIL", f"{k[0]}/{k[1]}: regression -- declared to differ from the oracle, but chart and oracle now MATCH exactly (the declared difference may have reverted)"))
        else:
            matched += 1
        continue

    if handler is None:
        detail = ", ".join(diff_paths(o_norm, c_norm)) or "(structurally different, no field-level diff found)"
        content_results.append(("FAIL", f"{k[0]}/{k[1]}: unexplained difference -- {detail}"))
        continue

    c_adj, o_adj, desc, raw_ok = handler(c_norm, o_norm)
    if c_adj == o_adj and raw_ok:
        content_results.append(("declared", f"{k[0]}/{k[1]}  {desc}"))
    elif c_adj == o_adj and not raw_ok:
        content_results.append(("FAIL", f"{k[0]}/{k[1]}: declared entry doesn't match reality (adjustment closed the gap, but the raw difference isn't the declared shape)"))
    else:
        detail = ", ".join(diff_paths(o_adj, c_adj)) or "(no field-level diff found after declared adjustment)"
        content_results.append(("FAIL", f"{k[0]}/{k[1]}: difference beyond the declared one for this object -- {detail}"))

# ── Report ────────────────────────────────────────────────────────────────
all_results = presence_results + content_results
declared_rows = [r for _, r in [(s, d) for s, d in all_results if s == "declared"]]
fail_rows = [d for s, d in all_results if s == "FAIL"]

for d in declared_rows:
    print(f"declared-different: {d}")
for d in fail_rows:
    print(f"{RED}FAIL{RESET} {d}")

n_declared = len(declared_rows)
n_fail = len(fail_rows)
summary = (f"{matched} objects matched exactly, {n_declared} declared-different "
           f"(2 namespace + {n_declared - 2} content), {n_fail} unexplained")
status = f"{GREEN}PASS{RESET}" if n_fail == 0 else f"{RED}FAIL{RESET}"
print(f"{summary}    -> {status}")

sys.exit(0 if n_fail == 0 else 1)
PY
