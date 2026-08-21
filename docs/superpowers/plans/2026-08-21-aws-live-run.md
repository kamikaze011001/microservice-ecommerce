# AWS live run — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement **Part A** task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Part B is NOT subagent work.** Every command in it costs money and runs against a live AWS account. It is a runbook the human operator executes. No agent may run any command in Part B.

**Goal:** Fix the blockers that prevent `ENV=aws` from running at all, audit the rest of the never-exercised path for the same defect class, then bring the stack up on real AWS and establish whether it works.

**Architecture:** Two parts with a hard boundary. Part A is offline code work — extract the two mis-scoped guards into testable functions, cover them with fixture-driven shell suites matching `scripts/lib/tests/eureka-test.sh`, and audit steps 2–9 for local-development assumptions on remote paths. Part B is a four-checkpoint operator runbook, each checkpoint ending in explicit verification, grouped so that each failure domain speaks one error vocabulary.

**Tech Stack:** Bash, Terraform (`aws/main`, `aws/bootstrap`), Helm, kubectl, AWS CLI v2, EKS 1.31, Docker/ECR.

**Spec:** `docs/superpowers/specs/2026-08-21-aws-live-run-design.md`

## Global Constraints

- **No agent runs a billed command.** Never `terraform apply`/`destroy`, never any `make aws-*` target, never `scripts/aws/up-all.sh`, `up.sh`, `down.sh`, `push-images.sh`, or `infra-up.sh`. Part A must not touch AWS at all.
- **Never open, print, or cat** `deploy/.env`, `aws/main/terraform.tfvars`, or any `*.tfvars` / `.env` file. Never print a credential value.
- Kubernetes version stays `1.31` — do not edit `cluster_version` in `aws/main/variables.tf` or `eks.tf`.
- Do not edit the local `ENV=compose` or `ENV=k8s` behaviour. `deploy/images/build.sh` must keep working unchanged for `REGISTRY=localhost:5001`.
- The EKS kube context is named exactly `microecom-eks` (set by `scripts/aws/up.sh:15` via `--alias microecom-eks`).
- The local dev registry is `localhost:5001` (host push) and `localhost:5000` (in-cluster pull).
- The ECR registry host is `583178372344.dkr.ecr.ap-southeast-1.amazonaws.com`, region `ap-southeast-1`.
- Shell suites follow the existing pattern: `set -uo pipefail`, `pass`/`fail` counters, `ok()`/`bad()` helpers, fixture- or shim-driven, never touching a live service. Reference: `scripts/lib/tests/eureka-test.sh`.
- Every new suite must be runnable standalone AND fail loudly if its own fixtures are missing — a suite that passes vacuously is worse than no suite.

---

# Part A — pre-flight (offline, no spend)

## Task 1: Scope the registry probe to local registries

**Files:**
- Create: `deploy/images/lib/registry-target.sh`
- Create: `deploy/images/tests/registry-target-test.sh`
- Modify: `deploy/images/build.sh:28-32` (the probe block)

**Interfaces:**
- Produces: `registry_is_local_http <registry>` — exit 0 when the registry is a plain-HTTP local registry that should be probed, exit 1 for any remote registry. Sourced by `build.sh` and by the test suite.

**Background for the implementer:** `deploy/images/build.sh` currently probes the registry over plain HTTP before building:

```bash
if ! curl -fsS -o /dev/null "http://${REGISTRY}/v2/" 2>/dev/null; then
  echo "ERROR: registry at ${REGISTRY} is not reachable." >&2
  echo "Run 'make k8s-cluster-up' or 'make k8s-registry-forward' first." >&2
  exit 1
fi
```

That probe exists to catch a stopped minikube registry, which is a real local failure. But `scripts/aws/push-images.sh:33` sets `REGISTRY` to the ECR host and calls the same script. ECR does not serve port 80, so the probe hangs and then fails. Measured:

```
curl: (28) Failed to connect to 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com
      port 80 after 75028 ms: Couldn't connect to server
```

The result is a 75-second stall followed by `exit 1` telling the operator to run a minikube command. On the AWS path the probe is also redundant: `push-images.sh:40` already runs `aws ecr get-login-password | docker login`, which is the real reachability-and-auth check.

- [ ] **Step 1: Write the failing test**

Create `deploy/images/tests/registry-target-test.sh`:

```bash
#!/usr/bin/env bash
# Decision table for deploy/images/lib/registry-target.sh.
#
# The probe in build.sh answers "is the local dev registry up?" — a question
# that only makes sense for a plain-HTTP registry on this machine. Applied to a
# remote registry it hangs on a closed port 80 and then reports the wrong system.
# These rows pin which registries are probe-able. Pure string classification:
# no network, no docker, no AWS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
source "$ROOT/deploy/images/lib/registry-target.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# --- local registries: MUST be probed -----------------------------------------
registry_is_local_http "localhost:5001" \
  && ok "localhost:5001 (host push port) is probe-able" \
  || bad "localhost:5001 must be probe-able"

registry_is_local_http "localhost:5000" \
  && ok "localhost:5000 (in-cluster pull port) is probe-able" \
  || bad "localhost:5000 must be probe-able"

registry_is_local_http "127.0.0.1:5001" \
  && ok "127.0.0.1:5001 is probe-able" \
  || bad "127.0.0.1:5001 must be probe-able"

# --- remote registries: MUST NOT be probed ------------------------------------
registry_is_local_http "583178372344.dkr.ecr.ap-southeast-1.amazonaws.com" \
  && bad "ECR must not be probed over http" \
  || ok "ECR is not probe-able"

registry_is_local_http "ghcr.io" \
  && bad "ghcr.io must not be probed over http" \
  || ok "ghcr.io is not probe-able"

registry_is_local_http "docker.io" \
  && bad "docker.io must not be probed over http" \
  || ok "docker.io is not probe-able"

# --- fail-safe rows -----------------------------------------------------------
# A classifier that returns 0 for everything would pass every row above except
# these. A classifier that returns 1 for everything would pass the remote rows
# but fail the local ones. Both directions are pinned.
registry_is_local_http "" \
  && bad "empty registry must not be treated as local" \
  || ok "empty registry is not probe-able"

# Substring traps: these CONTAIN 'localhost' but are not local.
registry_is_local_http "localhost.evil.example.com" \
  && bad "localhost.evil.example.com is remote, not local" \
  || ok "hostname merely starting with 'localhost' is not probe-able"

registry_is_local_http "registry.localhost.example.com:5001" \
  && bad "registry.localhost.example.com is remote, not local" \
  || ok "hostname merely containing 'localhost' is not probe-able"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

Make it executable:

```bash
chmod +x deploy/images/tests/registry-target-test.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./deploy/images/tests/registry-target-test.sh`

Expected: FAIL — `deploy/images/lib/registry-target.sh: No such file or directory`, then `registry_is_local_http: command not found` for every row.

- [ ] **Step 3: Write minimal implementation**

Create `deploy/images/lib/registry-target.sh`:

```bash
#!/usr/bin/env bash
# Classify a container registry as local-plain-HTTP or remote. Source, don't execute.
#
# build.sh probes the registry over http:// before building. That question is
# only meaningful for the local dev registry: a remote registry does not serve
# port 80, so the probe hangs until it times out and then blames minikube. Remote
# registries authenticate through `docker login` in their own caller
# (scripts/aws/push-images.sh), which is the real reachability check.
#
# Matching is anchored to the WHOLE host, not a substring: "localhost.example.com"
# is a remote host that merely starts with the word.

# registry_is_local_http <registry>
#   0 = plain-HTTP registry on this machine; build.sh should probe it
#   1 = anything else, including the empty string
registry_is_local_http() {
    case "${1:-}" in
        localhost|localhost:*|127.0.0.1|127.0.0.1:*) return 0 ;;
        *) return 1 ;;
    esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./deploy/images/tests/registry-target-test.sh`

Expected: PASS — `9 passed, 0 failed`, exit 0.

- [ ] **Step 5: Wire it into build.sh**

In `deploy/images/build.sh`, replace the probe block at lines 28–32 with:

```bash
# shellcheck source=lib/registry-target.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/registry-target.sh"

# Probe only a local plain-HTTP registry. A remote registry (ECR) does not serve
# port 80 — probing it hangs ~75s on a closed port and then tells the operator to
# start minikube. Remote callers authenticate via `docker login` themselves; see
# scripts/aws/push-images.sh. --max-time bounds the local probe too, so a wedged
# port-forward fails fast instead of stalling the build.
if registry_is_local_http "$REGISTRY"; then
  if ! curl -fsS --max-time 5 -o /dev/null "http://${REGISTRY}/v2/" 2>/dev/null; then
    echo "ERROR: local registry at ${REGISTRY} is not reachable." >&2
    echo "Run 'make k8s-cluster-up' or 'make k8s-registry-forward' first." >&2
    exit 1
  fi
fi
```

Note the `source` line must come **after** `cd "$(git rev-parse --show-toplevel)"` is fine either way, because it resolves relative to `BASH_SOURCE`, not the working directory. Keep it immediately above the probe.

- [ ] **Step 6: Verify the local path still works**

The local registry must still be probed and must still fail closed when absent. With no minikube registry running:

Run: `bash -c 'source deploy/images/lib/registry-target.sh; registry_is_local_http "localhost:5001" && echo "WOULD PROBE (correct)" || echo "would skip (WRONG for localhost)"'`

Expected: `WOULD PROBE (correct)`

Run: `bash -c 'source deploy/images/lib/registry-target.sh; registry_is_local_http "583178372344.dkr.ecr.ap-southeast-1.amazonaws.com" && echo "would probe (WRONG for ECR)" || echo "WOULD SKIP (correct)"'`

Expected: `WOULD SKIP (correct)`

- [ ] **Step 7: Verify build.sh still parses and the probe is gated**

Run: `bash -n deploy/images/build.sh && echo "syntax OK"`

Expected: `syntax OK`

Run: `grep -c 'registry_is_local_http' deploy/images/build.sh`

Expected: `1` — the `source` line and the shellcheck comment name the FILE (`registry-target.sh`), not the function, so only the `if` call site matches. If this prints 0 the wiring was not applied; if it prints more than 1, confirm exactly one call site guards exactly one `curl`.

- [ ] **Step 8: Commit**

```bash
git add deploy/images/lib/registry-target.sh deploy/images/tests/registry-target-test.sh deploy/images/build.sh
git commit -m "fix(images): probe only local registries, never ECR"
```

---

## Task 2: Make AWS teardown refuse to run against the wrong cluster

**Files:**
- Create: `scripts/aws/lib/kube-context.sh`
- Create: `scripts/aws/tests/kube-context-test.sh`
- Create: `scripts/aws/tests/shims/kubectl` (test shim, executable)
- Modify: `scripts/aws/down.sh:18-24` (the two `kubectl delete` lines and the wait)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `require_kube_context <context>` — exit 0 when the named context exists in kubeconfig and its API server answers; exit 1 when the context is absent; exit 2 when the context exists but the cluster does not respond. Sourced by `down.sh` and by the test suite.

**Background for the implementer:** `scripts/aws/down.sh` deletes the Kubernetes Ingresses first so the AWS Load Balancer Controller deprovisions the ALB, then runs `terraform destroy`. Terraform does not know the ALB exists — the in-cluster controller created it — so if the deletes do not actually reach the EKS cluster, the ALB is stranded and keeps billing, invisible to `terraform state list`.

The current deletes are:

```bash
kubectl delete -f "$ROOT/aws/manifests/hello-nginx.yaml" --ignore-not-found=true || true
kubectl delete ingress gateway-alb -n apps --ignore-not-found=true || true
```

Two problems, and they compound:

1. **No context is named.** `kubectl` uses whatever ambient context is current. Pointed at minikube, both deletes run against the wrong cluster. `scripts/aws/up-all.sh` passes `--context microecom-eks` explicitly at lines 142, 215, 228 and 253 for exactly this reason; the teardown path never got the same treatment.
2. **`|| true` swallows the distinction that matters.** `--ignore-not-found=true` already handles "that resource isn't there", which is a normal, safe outcome. The extra `|| true` additionally suppresses "I could not reach the cluster at all" — the opposite situation, and the one that must abort before `terraform destroy`.

The guard is present on the creation path and missing from the teardown path, which inverts where the risk lives.

- [ ] **Step 1: Create the kubectl test shim**

Create `scripts/aws/tests/shims/kubectl`:

```bash
#!/usr/bin/env bash
# Fake kubectl for scripts/aws/tests/kube-context-test.sh. Put this directory
# FIRST on PATH to intercept kubectl without touching any real cluster.
#
# Behaviour is driven by two env vars set by the suite:
#   SHIM_CONTEXTS   newline-separated context names that exist in "kubeconfig"
#   SHIM_READYZ_OK  "1" = API server answers; anything else = it does not
set -uo pipefail

# `kubectl config get-contexts -o name`
if [ "${1:-}" = "config" ] && [ "${2:-}" = "get-contexts" ]; then
    printf '%s\n' "${SHIM_CONTEXTS:-}"
    exit 0
fi

# `kubectl --context X --request-timeout=10s get --raw /readyz`
if [ "${1:-}" = "--context" ]; then
    [ "${SHIM_READYZ_OK:-}" = "1" ] || exit 1
    echo "ok"
    exit 0
fi

echo "shim: unexpected invocation: $*" >&2
exit 99
```

Make it executable:

```bash
chmod +x scripts/aws/tests/shims/kubectl
```

- [ ] **Step 2: Write the failing test**

Create `scripts/aws/tests/kube-context-test.sh`:

```bash
#!/usr/bin/env bash
# Decision table for scripts/aws/lib/kube-context.sh.
#
# This guard protects the TEARDOWN path. Its failure mode is silent and
# expensive: pointed at the wrong cluster, every kubectl delete succeeds as a
# no-op, terraform destroy proceeds, and the real ALB keeps billing with nothing
# in terraform state to show it. So the three outcomes are asserted as DISTINCT
# exit codes — "absent context" and "unreachable cluster" need different operator
# responses and must never collapse into one.
#
# Driven entirely by a kubectl shim on PATH. Never contacts a cluster.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
source "$ROOT/scripts/aws/lib/kube-context.sh"

# Intercept kubectl.
PATH="$HERE/shims:$PATH"
export PATH

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# Guard against a vacuous suite: if the shim is not executable, every row below
# would exercise the real kubectl (or nothing at all).
[ -x "$HERE/shims/kubectl" ] \
  && ok "kubectl shim is present and executable" \
  || bad "kubectl shim missing — every row below is meaningless"

# 1. context exists and cluster answers -> 0
SHIM_CONTEXTS=$'minikube\nmicroecom-eks' SHIM_READYZ_OK=1 \
  require_kube_context microecom-eks
[ $? -eq 0 ] \
  && ok "present context + reachable cluster -> 0" \
  || bad "present context + reachable cluster must return 0"

# 2. context absent (e.g. kubeconfig only has minikube) -> 1
SHIM_CONTEXTS=$'minikube\ndocker-desktop' SHIM_READYZ_OK=1 \
  require_kube_context microecom-eks
[ $? -eq 1 ] \
  && ok "absent context -> 1" \
  || bad "absent context must return 1, not 0 or 2"

# 3. context present but cluster unreachable (torn down, VPN off) -> 2
SHIM_CONTEXTS=$'microecom-eks' SHIM_READYZ_OK=0 \
  require_kube_context microecom-eks
[ $? -eq 2 ] \
  && ok "unreachable cluster -> 2" \
  || bad "unreachable cluster must return 2, distinct from absent-context 1"

# 4. empty kubeconfig -> 1
SHIM_CONTEXTS='' SHIM_READYZ_OK=1 \
  require_kube_context microecom-eks
[ $? -eq 1 ] \
  && ok "empty kubeconfig -> 1" \
  || bad "empty kubeconfig must return 1"

# 5. substring trap: a context whose name CONTAINS the target must not match.
SHIM_CONTEXTS=$'not-microecom-eks-either' SHIM_READYZ_OK=1 \
  require_kube_context microecom-eks
[ $? -eq 1 ] \
  && ok "substring match does not count as the context" \
  || bad "matching must be exact, not substring"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

Make it executable:

```bash
chmod +x scripts/aws/tests/kube-context-test.sh
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./scripts/aws/tests/kube-context-test.sh`

Expected: FAIL — `scripts/aws/lib/kube-context.sh: No such file or directory`, then `require_kube_context: command not found` on every row.

- [ ] **Step 4: Write minimal implementation**

Create `scripts/aws/lib/kube-context.sh`:

```bash
#!/usr/bin/env bash
# Assert which cluster a destructive kubectl call will hit. Source, don't execute.
#
# Why this exists: scripts/aws/down.sh deletes Ingresses so the in-cluster AWS
# Load Balancer Controller deprovisions the ALB, THEN runs terraform destroy.
# Terraform does not know the ALB exists. If those deletes silently hit the wrong
# cluster, the ALB survives, keeps billing, and appears in no terraform state.
#
# The three outcomes are deliberately distinct exit codes: "the context is not in
# your kubeconfig" and "the cluster is not answering" call for different operator
# responses, and collapsing them into one is how a teardown ends up half-done.

# require_kube_context <context>
#   0 = context exists in kubeconfig AND its API server answers
#   1 = context is not in kubeconfig
#   2 = context exists but the cluster did not answer
require_kube_context() {
    local ctx="${1:-}"
    [ -n "$ctx" ] || return 1

    # -qxF: exact whole-line match. A context merely CONTAINING the name is a
    # different cluster.
    kubectl config get-contexts -o name 2>/dev/null \
        | grep -qxF "$ctx" || return 1

    # /readyz over a bounded timeout. Without --request-timeout this blocks on
    # the default (no timeout) against a dead endpoint.
    kubectl --context "$ctx" --request-timeout=10s get --raw /readyz \
        >/dev/null 2>&1 || return 2

    return 0
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/aws/tests/kube-context-test.sh`

Expected: PASS — `6 passed, 0 failed`, exit 0.

- [ ] **Step 6: Wire it into down.sh**

In `scripts/aws/down.sh`, add after the `export AWS_PROFILE=...` line:

```bash
EKS_CONTEXT="${EKS_CONTEXT:-microecom-eks}"

# shellcheck source=lib/kube-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/kube-context.sh"

# Refuse to proceed unless we can prove which cluster the deletes below will hit.
# A no-op delete against the wrong cluster looks identical to a successful one,
# and the ALB it fails to remove keeps billing after terraform destroy returns.
# `|| rc=$?` is load-bearing: down.sh runs under `set -euo pipefail`, and a BARE
# call returning non-zero would abort the script before `case` ever runs — the
# destroy would still be prevented, but the operator would see a silent exit
# instead of the diagnostics below. Failure must stay handled, not fatal, here.
rc=0
require_kube_context "$EKS_CONTEXT" || rc=$?
case $rc in
  0) echo "▶ teardown target confirmed: context '$EKS_CONTEXT'" ;;
  1) echo "ERROR: kube context '$EKS_CONTEXT' is not in your kubeconfig." >&2
     echo "  The EKS cluster may already be gone. If so, terraform destroy is" >&2
     echo "  still safe to run directly, but check 'make aws-leak-check' after:" >&2
     echo "  an ALB created by the in-cluster controller is NOT in terraform state." >&2
     echo "  To restore the context:  aws eks update-kubeconfig --name microecom \\" >&2
     echo "                             --region ap-southeast-1 --alias microecom-eks" >&2
     exit 1 ;;
  2) echo "ERROR: context '$EKS_CONTEXT' exists but the cluster is not answering." >&2
     echo "  Refusing to destroy: the Ingress deletes below would be silent no-ops" >&2
     echo "  and the ALB would be stranded. Check the cluster, then re-run." >&2
     exit 1 ;;
esac
```

Then change the two delete lines to name the context explicitly and stop swallowing transport failures:

```bash
# --ignore-not-found handles "the resource is absent", which is fine. It does NOT
# handle "the cluster is unreachable" — that must abort, so no `|| true` here.
# The context is passed explicitly and never inherited: require_kube_context above
# has already proven this exact context resolves and answers.
kubectl --context "$EKS_CONTEXT" delete -f "$ROOT/aws/manifests/hello-nginx.yaml" \
  --ignore-not-found=true
kubectl --context "$EKS_CONTEXT" delete ingress gateway-alb -n apps \
  --ignore-not-found=true
```

- [ ] **Step 7: Verify down.sh parses and no longer swallows delete failures**

Run: `bash -n scripts/aws/down.sh && echo "syntax OK"`

Expected: `syntax OK`

Run: `grep -n 'kubectl' scripts/aws/down.sh`

Expected: exactly **two** `kubectl` lines, both `delete`, both carrying `--context "$EKS_CONTEXT"`, and **neither** ending in `|| true`. The `get-contexts` and `/readyz` calls live in the sourced lib, not here. If you see `|| true` on a delete, the fix is incomplete.

Run: `grep -c 'context' scripts/aws/down.sh`

Expected: at least `6`. Confirm by reading that both deletes carry `--context "$EKS_CONTEXT"`.

- [ ] **Step 8: Commit**

```bash
git add scripts/aws/lib/kube-context.sh scripts/aws/tests/kube-context-test.sh scripts/aws/tests/shims/kubectl scripts/aws/down.sh
git commit -m "fix(aws): teardown must prove which cluster it is destroying"
```

---

## Task 3: Pre-flight audit of steps 2–9

**Files:**
- Create: `docs/superpowers/plans/2026-08-21-aws-preflight-findings.md`
- Read only (do not modify in this task): `scripts/aws/up-all.sh`, `scripts/aws/infra-up.sh`, `scripts/aws/push-images.sh`, `scripts/aws/up.sh`, `scripts/aws/down.sh`, `scripts/aws/leak-check.sh`, `scripts/aws/RUNBOOK.md`, `deploy/scripts/aws-deploy.sh`, `deploy/scripts/seed.sh`, `deploy/scripts/secrets-seed.sh`, `deploy/scripts/platform.sh`, `deploy/images/build.sh`, everything under `deploy/aws-infra/`

**Interfaces:**
- Consumes: the fixes from Tasks 1 and 2 are already applied; do not re-report them.
- Produces: a findings document whose "Must fix before the run" section becomes additional tasks in this plan.

**Background for the implementer:** Steps 2–9 of the AWS bring-up have never executed. Task 1 fixed a blocker that was findable for free in about thirty seconds by reading one line of a shell script, and it survived five phases of green offline verification — because `make aws-diff-test` renders Helm templates and never executes any of these scripts. The gate and the defect live in different universes.

Assume more of the same class remains. This task is a read-only hunt, not a fix.

**This task must not run any AWS, terraform, kubectl, docker, helm, or make command.** It reads files.

- [ ] **Step 1: Sweep for local-development assumptions on remote paths**

For each file in the read-only list above, look specifically for:

1. `http://` against a host that is not localhost — the Task 1 defect class
2. Hardcoded `localhost` / `127.0.0.1` on a code path that runs against AWS
3. `kubectl` calls with no `--context` on a path that can run while another cluster is current — the Task 2 defect class
4. `|| true` or `2>/dev/null` that suppresses a transport failure rather than an expected-absent condition
5. Unbounded network calls: `curl` with no `--max-time`, `kubectl` with no `--request-timeout`, `wget` with no `--timeout`
6. Fixed `sleep N` used as a substitute for polling a real condition
7. References to files or directories Phase 8 deleted — check every path a script opens actually exists on `main` today, including `./relative` forms resolved from inside a subdirectory
8. Error messages that name the wrong system (e.g. telling an AWS operator to run a minikube command)
9. Ordering assumptions the Helm cut-over changed — comments describing `kubectl apply -k` while the body calls `aws-deploy.sh`
10. `terraform output -raw` calls whose output name may not exist in the current stack

Record every hit with file, line, the exact text, and what would actually happen at runtime.

- [ ] **Step 2: Resolve the mail/OTP open question**

The spec's acceptance tier 3 (registration and login) depends on OTP delivery. Determine from `deploy/secrets/contexts/aws.yaml`, `deploy/secrets/` and the chart's `envs/aws.yaml` whether mail is configured for `ENV=aws`, and what `authorization-server`'s readiness `include` list requires on this env.

State one of: mail is configured and tier 3 should work; mail is not configured and tier 3 will fail; or it is configured but unverifiable offline. Do not guess — cite the files.

- [ ] **Step 3: Verify every path the AWS scripts open still exists**

For each file path referenced by the read-only scripts, check it exists on `main`. Watch for two blind spots that have bitten this repo before:

- basename-only greps match same-named files elsewhere; qualify by path
- a path written as `./thing.yaml` inside a script that `cd`s first resolves relative to the new directory, not the repo root

Report any dangling reference with the file, line, and the referenced path.

- [ ] **Step 4: Write the findings document**

Create `docs/superpowers/plans/2026-08-21-aws-preflight-findings.md` with exactly these sections:

```markdown
# AWS pre-flight audit — findings

**Date:** 2026-08-21 · **Scope:** steps 2–9 of scripts/aws/up-all.sh, read-only
**Already fixed, not re-reported:** build.sh registry probe (Task 1), down.sh context guard (Task 2)

## Must fix before the run
<!-- Blocks a step outright, or can strand a billing resource. One entry each: -->
### F<n> — <one-line title>
- **Where:** `<file>:<line>`
- **Text:** `<the exact line>`
- **What happens at runtime:** <concrete failure, not "may cause issues">
- **Why offline gates missed it:** <one line>
- **Fix:** <the specific change>

## Note and proceed
<!-- Real but survivable; the operator should recognise the symptom. -->
### N<n> — <one-line title>
- **Where:** `<file>:<line>`
- **Symptom the operator will see:** <what it looks like>
- **Why it is survivable:** <one line>

## Open questions
<!-- Anything that could not be resolved by reading. State what would resolve it. -->

## Mail / OTP verdict
<!-- From Step 2: configured / not configured / unverifiable, with file citations. -->

## Coverage
<!-- Which files were read, so a later reader knows what was NOT looked at. -->
```

Every entry must name a file and line. "What happens at runtime" must describe a concrete failure — an entry that says "may cause issues" is not a finding.

- [ ] **Step 5: Sanity-check the audit is not vacuously empty**

An audit that finds nothing is possible but suspicious given Task 1's existence. Before concluding, confirm you actually read the files by recording, in the Coverage section, the line count of each file read.

Run: `wc -l scripts/aws/*.sh deploy/scripts/aws-deploy.sh deploy/scripts/seed.sh deploy/scripts/secrets-seed.sh deploy/images/build.sh`

Paste the totals into the Coverage section.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/plans/2026-08-21-aws-preflight-findings.md
git commit -m "docs(aws): pre-flight audit findings for steps 2-9"
```

---

## Gate after Task 3

**This is a control point for the human, not a task.**

The controller triages Task 3's "Must fix before the run" section with the operator and appends a concrete task to this plan for each accepted item — same structure as Tasks 1 and 2: failing test, verify red, implement, verify green, commit. Items in "Note and proceed" are carried into Part B's triage notes instead of being fixed.

Part B does not begin until every accepted must-fix item is closed.

---

# Part B — the live run (operator-executed, billed)

**No agent runs any command in this part.** Each checkpoint below lists what the operator runs, what it should print, and how to read a failure. The assistant's role is to interpret output, diagnose, and write fixes — never to execute.

**Before every session:**

```bash
export AWS_PROFILE=microecom
```

**After every session, without exception**, including sessions that fail early — see Checkpoint 4's teardown.

**Running cost while the stack is up: ~$1.00/hour.** Note the wall-clock time at each checkpoint.

## Checkpoint 1 — infra

**Runs:** step 1. `make aws-up` → `scripts/aws/up.sh` → `terraform apply` on `aws/main`. Expect **15–20 minutes**, most of it EKS control-plane provisioning.

**Verify before proceeding:**

```bash
terraform -chdir=aws/main output
kubectl --context microecom-eks get nodes
kubectl --context microecom-eks get pods -A
aws acm list-certificates --region ap-southeast-1 \
  --query 'CertificateSummaryList[].[DomainName,Status]' --output table
```

Expected: outputs include the cluster endpoint and RDS addresses; **3 nodes `Ready`**; CoreDNS and kube-proxy `Running`; the `shop.microecom.click` certificate `ISSUED`.

**A cluster can exist while nodes fail to join** — `get nodes` is the real proof, not `terraform apply` succeeding.

**Failure vocabulary here is AWS-shaped.** Two specific to this stack:

- The node group is **SPOT-only** and pinned to one availability zone (`eks.tf:82`, `subnet_ids = [private_subnets[0]]`). That pinning is deliberate — EBS volumes are AZ-locked, and an earlier run had nodes drift to another AZ and strand their storage. The cost is that if that AZ has no spot capacity for `t4g.large`, the node group simply fails to provision. Recognise it rather than assuming something is broken.
- The certificate validates via DNS. If it sits in `PENDING_VALIDATION`, check the CNAME landed in the `microecom.click` zone.

## Checkpoint 2 — images and platform

**Runs:** steps 2–3.

```bash
make aws-push svc=all
make aws-infra-up
```

`svc=all` is **mandatory** — ECR's `:dev` tags predate Phases 7–8 and PRs #59–63. `svc=all` is what `push-images.sh:36` reads (`TARGET="${1:-gateway}"`); the default target is `gateway` alone, which pushes gateway + maven-cores and leaves the other seven services, the frontend and mock-paypal on stale tags. `PUSH` is a different variable, read only by `up-all.sh:61`, and Part B deliberately never invokes `up-all.sh` — setting it here would do nothing. Reusing the stale tags would deploy images that do not match `main`, making any later failure unattributable.

**Verify before proceeding:**

```bash
kubectl --context microecom-eks get pods -n infra
kubectl --context microecom-eks get pvc -A
kubectl --context microecom-eks get sc
```

Expected: Mongo, Kafka, Schema Registry, Kafka Connect, VictoriaMetrics and Grafana all `Running`; every PVC `Bound`; `gp3` present and marked default, `gp2` **not** default.

**Failure vocabulary is credential- and storage-shaped.** The one with history: PVCs stuck `Pending` because the gp3 StorageClass did not apply first — `infra-up.sh:38` carries a "MUST precede any PVC" comment for this reason, and Kafka specifically breaks on ext4 because `lost+found` in a log dir is fatal to it.

## Checkpoint 3 — secrets and apps

**Runs:** steps 4–6.

```bash
bash deploy/scripts/seed.sh --env aws --stage pre-apps --context microecom-eks
bash deploy/scripts/secrets-seed.sh --env aws
make aws-deploy-apps
```

**The order is load-bearing.** An `ExternalSecret` is a request to fetch a value from AWS Secrets Manager and materialise it as a Kubernetes Secret. A pod mounting that Secret will not start until it exists. Deploy apps before seeding Secrets Manager and you do not get a clean error — you get pods stuck in `CreateContainerConfigError` waiting on a Secret that will never appear, three layers from the cause.

**Verify:**

```bash
kubectl --context microecom-eks get pods -n apps
kubectl --context microecom-eks get externalsecrets -A
kubectl --context microecom-eks get ingress -n apps
```

Expected: all app pods `Running`; every ExternalSecret `SecretSynced`; `gateway-alb` Ingress with an ADDRESS assigned.

Step 6 gates on `authorization-server` and `inventory-service` rolling out, because those create the RDS schema via `ddl-auto` that steps 7–8 seed into. On timeout it dumps `describe` output; the script's own comment calls these "the two hardest deps to debug".

**This is the checkpoint most likely to fail.** Failures are Kubernetes-shaped: crashloops, unresolved ExternalSecrets, IRSA trust, readiness gates.

## Checkpoint 4 — data, acceptance, teardown

**Runs:** steps 7–9.

```bash
bash deploy/scripts/seed.sh --env aws --stage post-apps --context microecom-eks
```

Then acceptance, in tiers. Record which tier is reached:

1. **Reachable** — `https://shop.microecom.click` loads, certificate valid
2. **Read path** — catalog renders, product images load from S3
3. **Auth path** — registration and login succeed *(depends on Task 3 Step 2's mail verdict)*
4. **Write path and saga** — add to cart, place an order, and the saga completes:
   Mongo CDC → Kafka Connect → orchestrator → payment → inventory over gRPC

Tiers 1–2 mean the deploy worked. **Tier 4 is the bar for this phase.**

For tier 4, watch the saga rather than trusting the UI:

```bash
kubectl --context microecom-eks logs -n apps deploy/orchestrator-service --tail=100
kubectl --context microecom-eks logs -n apps deploy/payment-service --tail=100
```

### Teardown — mandatory, every session

```bash
make aws-down
make aws-leak-check
```

`aws-down` deletes the Ingresses first so the controller deprovisions the ALB, waits 60 s, then destroys, then lists any Secrets Manager entries in soft-delete. After Task 2 it refuses outright if it cannot prove which cluster it is talking to.

`aws-leak-check` must print **empty tables** for load balancers, available NAT gateways, allocated EIPs, unattached EBS volumes and EKS clusters. Anything listed is still billing.

Known weakness, not fixed in this plan: `down.sh`'s 60 s wait is a fixed sleep, not a poll. If the ALB takes longer, `terraform destroy` can hang on orphaned ENIs. Recognise the symptom — a destroy stuck on VPC or subnet deletion — and re-run after confirming the ALB is gone.

**Expected survivors:** the `aws/bootstrap` stack only — state bucket, DynamoDB lock table, 11 ECR repos, budget alarm.

**The day after:** confirm in Cost Explorer that spend returned to approximately zero. This is the only check that catches a leak the scripted ones missed.
