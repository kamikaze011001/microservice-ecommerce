# Phase 8 Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** close the four local gaps Phase 8 recorded — `make down` leaving MinIO up, `up-all.sh` spending money with no confirmation, two teaching pages describing a deleted tree, and `make up` skipping services whose Eureka registration has gone stale.

**Architecture:** four independent fixes, each landable and revertible alone. F2 lands first because it is what makes a genuine cold start possible, which in turn is what finally exercises a readiness poll Phase 8 shipped untested. F5 folds a freshness check into the single place that already decides "this service is already running, skip it".

**Tech Stack:** bash (the repo's `scripts/lib/*.sh` convention), `python3` for JSON parsing (already a dependency of the deploy suites), `curl`, macOS `route`/`ipconfig`.

**Design spec:** `docs/superpowers/specs/2026-08-16-phase8-followups-design.md`. Read §5 before Task 2.

## Global Constraints

- **Never `git push`.** A pre-push hook owns pushing; it is the human's job.
- **NOTHING THAT COSTS MONEY.** Never run `scripts/aws/up-all.sh`, any `aws-*` target, or `terraform`. Task 4 edits `up-all.sh` and must never execute it past the guard.
- **`git rm` and `rm` are sandbox-blocked** for the assistant, as are writes to `deploy/.env*`. Ask the human; never work around them.
- **Never print a credential value.**
- Environment: macOS, GNU Make **3.81**, no `/usr/bin/timeout`, use `/bin/ls`. `python3` and `jq` present; `yq`/`vault` NOT installed. Docker is OrbStack.
- `rtk` silently truncates large stdout even through a shell redirect — use `rtk proxy <cmd>` for anything counted, parsed, or redirected.
- **Assert non-empty before concluding "clean".** An empty result reading as a negative result has landed nine times in this repo, several times inside guards written to prevent it.
- Test scripts print `N passed, M failed` and exit non-zero on failure, matching `deploy/seed/tests/*.sh`.
- Every task ends with a commit, after running the tests it names.

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/infra/down.sh` | stop the compose stack — must cover every file `up.sh` starts |
| `scripts/lib/eureka.sh` | **new.** Resolve the host IP and Eureka's registered IP; decide staleness. Pure query + comparison, no restarting. |
| `scripts/lib/tests/eureka-test.sh` | **new.** Suite for the staleness decision table, driven by fixtures. |
| `scripts/lib/tests/fixtures/eureka-apps.json` | **new.** Captured Eureka response used by the suite. |
| `scripts/services/start.sh` | consumes `eureka.sh` inside its existing skip branch |
| `scripts/aws/up-all.sh` | gains a confirmation guard as its first executable statement |
| `docs/k8s-architecture.html`, `docs/k8s-eli5.html` | teaching pages, rewritten to the Helm reality |
| `Makefile` | a target for the new suite |
| `CLAUDE.md` | `make down` description corrected |

---

## Task 1: F2 — `make down` must stop MinIO

**Files:**
- Modify: `scripts/infra/down.sh:32`
- Modify: `CLAUDE.md:29`

**Interfaces:**
- Produces: a working `make down && make up` cold start, which Task 3's live verification and this task's own MinIO check both depend on.

**Why first:** until this lands the repo cannot produce a genuine cold start. Phase 8 added a MinIO readiness poll to `deploy/scripts/seed.sh` and never exercised it, precisely because `make down` left MinIO running so nothing ever raced it.

- [ ] **Step 1: Confirm the asymmetry before changing anything**

```bash
grep -o 'start_compose "[a-z]*\.yml"' scripts/infra/up.sh
sed -n '32p' scripts/infra/down.sh
```

Expected: `up.sh` names six files — `mysql.yml redis.yml mongodb.yml kafka.yml vault.yml minio.yml`; `down.sh` names five, omitting `minio.yml`. **If down.sh already lists six, stop — the gap is closed and this task is void.**

- [ ] **Step 2: Add `minio.yml` to the down list**

`scripts/infra/down.sh:32`, change:

```bash
for f in vault.yml kafka.yml mongodb.yml redis.yml mysql.yml; do
```

to:

```bash
# Order mirrors up.sh reversed. minio.yml was omitted until 2026-08-16, which
# meant `make down` left MinIO running and the repo could not produce a genuine
# cold start — every `make up` was warmer than a real one. That is why the MinIO
# readiness poll in deploy/scripts/seed.sh shipped unexercised.
for f in vault.yml kafka.yml mongodb.yml redis.yml mysql.yml minio.yml; do
```

- [ ] **Step 3: Correct the docs**

`CLAUDE.md:29` currently reads `make down    # stops services + infra (preserves data)`. That is now true; verify it and leave it. Then check `deploy/README.md` for any claim that `make down` omits MinIO — Phase 8 documented the gap as a known issue, and that text is now stale:

```bash
grep -n 'minio.yml' CLAUDE.md deploy/README.md
```

Every hit that describes the omission as current must become past tense, naming 2026-08-16 as when it was fixed.

- [ ] **Step 4: Verify the cold start actually stops MinIO**

```bash
make down
docker ps --format '{{.Names}}' | grep -c minio
```

Expected: `0`. **Assert this explicitly** — `grep -c` returning 0 with a broken `docker ps` looks identical, so also confirm `docker ps --format '{{.Names}}' | wc -l` is a plausible number (the human's other project runs ~6 containers that must stay up: `fineract-development`, `tempo`, `grafana`, `prometheus`, `loki`). **If any of those stopped, revert immediately and report** — `make down` must not reach beyond this project.

- [ ] **Step 5: Bring it back and confirm the MinIO readiness poll finally runs**

```bash
make up 2>&1 | tee /tmp/f2-coldstart.log
```

Expected: exit 0. Then confirm MinIO came back and the seed reached it:

```bash
docker ps --format '{{.Names}}' | grep minio
grep -c 'objects seeded' /tmp/f2-coldstart.log
```

Expected: a minio container present, and at least one `objects seeded` line. This is the first genuine cold-start exercise of the poll at `deploy/scripts/seed.sh` — if it times out, that is a real finding about the poll, not about this task; report it rather than working around it.

- [ ] **Step 6: Commit**

```bash
git add scripts/infra/down.sh CLAUDE.md deploy/README.md
git commit -m "fix(infra): make down stops MinIO, so a real cold start is possible

up.sh started six compose files and down.sh stopped five. The stray MinIO
container made every subsequent make up warmer than a real one, which is why
Phase 8's MinIO readiness poll shipped unexercised."
```

---

## Task 2: F5a — the staleness decision, as a testable unit

**Files:**
- Create: `scripts/lib/eureka.sh`
- Create: `scripts/lib/tests/eureka-test.sh`
- Create: `scripts/lib/tests/fixtures/eureka-apps.json`
- Modify: `Makefile` (add `svc-test-staleness`)

**Interfaces:**
- Produces, for Task 3:
  - `current_host_ip()` → prints the IP a host-run JVM would register; **exit 1 and print nothing** if it cannot be determined. Honours `HOST_IP_OVERRIDE`.
  - `eureka_registered_ip <http_port>` → prints the `ipAddr` Eureka holds for the instance on that port; **exit 1 and print nothing** if Eureka is unreachable or no instance uses that port.
  - `registration_is_stale <http_port>` → **exit 0 = stale (caller should restart)**, **exit 1 = not stale, or unknown**. Never exits 0 on missing information.

**Read the spec's §5 decision table before starting.** The join key is the **HTTP port, not the name**: `gateway` registers with Eureka as `CLOUD-GATEWAY`, so a name-based match would silently never heal the gateway — the entry point, and the service where stale registration hurts most.

- [ ] **Step 1: Capture the fixture from the live registry**

```bash
mkdir -p scripts/lib/tests/fixtures
curl -s -H 'Accept: application/json' http://localhost:8761/eureka/apps \
  > scripts/lib/tests/fixtures/eureka-apps.json
python3 -c "
import json;d=json.load(open('scripts/lib/tests/fixtures/eureka-apps.json'))
a=d['applications']['application']; a=[a] if isinstance(a,dict) else a
print('apps:',len(a));assert len(a)>0,'VACUOUS: empty fixture'
for x in a:
  i=x['instance']; i=i[0] if isinstance(i,list) else i
  print(' ',x['name'],i['ipAddr'],i['port']['\$'])
"
```

Expected: 7 apps, each with an `ipAddr` and a port. **If the compose stack is down, start it (`make up`) — a fixture captured from an empty registry is worthless.**

- [ ] **Step 2: Write the failing test**

Create `scripts/lib/tests/eureka-test.sh`:

```bash
#!/usr/bin/env bash
# Decision-table suite for scripts/lib/eureka.sh. Fixture-driven: never touches
# a live Eureka, so it runs with the stack down.
#
# The two fail-safe rows matter most. A correct "selects nothing" and a broken
# check are indistinguishable from outside, so they are asserted as explicit
# non-stale verdicts, never inferred from "no restart happened".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
source "$ROOT/scripts/lib/eureka.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# The fixture registers everything at 192.168.0.103. gateway is port 6868 and
# appears in Eureka as CLOUD-GATEWAY — the case a name-based join would miss.
export EUREKA_APPS_FIXTURE="$HERE/fixtures/eureka-apps.json"

# 1. registered + IP differs -> stale
HOST_IP_OVERRIDE=10.0.0.7 registration_is_stale 6868 \
  && ok "drifted gateway (CLOUD-GATEWAY, port join) is stale" \
  || bad "drifted gateway should be stale"

# 2. registered + IP matches -> not stale
HOST_IP_OVERRIDE=192.168.0.103 registration_is_stale 6868 \
  && bad "matching IP must not be stale" \
  || ok "matching IP is not stale"

# 3. not registered (orchestrator 9999 never registers) -> not stale
HOST_IP_OVERRIDE=10.0.0.7 registration_is_stale 9999 \
  && bad "unregistered service must not be stale" \
  || ok "unregistered service is not stale"

# 4. FAIL-SAFE: Eureka unreachable -> not stale, even with a drifted IP
EUREKA_APPS_FIXTURE=/nonexistent HOST_IP_OVERRIDE=10.0.0.7 registration_is_stale 6868 \
  && bad "unreachable Eureka must NOT report stale" \
  || ok "unreachable Eureka reports not-stale (fail-safe)"

# 5. FAIL-SAFE: host IP undeterminable -> not stale
HOST_IP_OVERRIDE= FORCE_NO_HOST_IP=1 registration_is_stale 6868 \
  && bad "undeterminable host IP must NOT report stale" \
  || ok "undeterminable host IP reports not-stale (fail-safe)"

# 6. the fixture itself is not empty (guards a vacuous suite)
[ -s "$HERE/fixtures/eureka-apps.json" ] \
  && ok "fixture is non-empty" || bad "fixture is empty — suite would be vacuous"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

```bash
chmod +x scripts/lib/tests/eureka-test.sh
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash scripts/lib/tests/eureka-test.sh`
Expected: FAIL — `scripts/lib/eureka.sh: No such file or directory`.

- [ ] **Step 4: Write the implementation**

Create `scripts/lib/eureka.sh`:

```bash
#!/usr/bin/env bash
# Eureka registration freshness. Pure query + comparison — never restarts
# anything; the caller decides what to do with the verdict.
#
# WHY THIS EXISTS: under compose the JVMs run on the HOST and register the
# host's IP with Eureka. After a network/IP change the processes are still
# alive, so scripts/services/start.sh skips them, and they keep serving stale
# registrations. Everything looks up and requests fail.
#
# JOIN KEY IS THE HTTP PORT, NOT THE NAME. `gateway` appears in Eureka as
# CLOUD-GATEWAY, so a name-based match would silently never heal the gateway.
# services.list already carries the port as the single source of truth.

EUREKA_URL="${EUREKA_URL:-http://localhost:8761}"

# current_host_ip — the IP a host-run JVM would register.
# Prints it; exits 1 and prints NOTHING if it cannot be determined.
current_host_ip() {
    [ -n "${FORCE_NO_HOST_IP:-}" ] && return 1          # test seam
    if [ -n "${HOST_IP_OVERRIDE:-}" ]; then
        printf '%s' "$HOST_IP_OVERRIDE"; return 0
    fi
    # Derive the interface from the DEFAULT ROUTE, never a hardcoded one:
    # on this project's own machine the IP is on en1 and `ipconfig getifaddr
    # en0` returns empty, which would make every service look drifted.
    local iface ip
    iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    [ -n "$iface" ] || return 1
    ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
    [ -n "$ip" ] || return 1
    printf '%s' "$ip"
}

# eureka_registered_ip <http_port> — the ipAddr Eureka holds for the instance
# serving that port. Prints it; exits 1 and prints NOTHING when Eureka is
# unreachable or no instance matches.
eureka_registered_ip() {
    local port=$1 json
    if [ -n "${EUREKA_APPS_FIXTURE:-}" ]; then
        json=$(cat "$EUREKA_APPS_FIXTURE" 2>/dev/null) || return 1
    else
        json=$(curl -sf --max-time 3 -H 'Accept: application/json' \
                    "$EUREKA_URL/eureka/apps" 2>/dev/null) || return 1
    fi
    [ -n "$json" ] || return 1
    printf '%s' "$json" | EUREKA_PORT="$port" python3 -c '
import sys, os, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
apps = d.get("applications", {}).get("application", [])
if isinstance(apps, dict):
    apps = [apps]
want = os.environ["EUREKA_PORT"]
for a in apps:
    insts = a.get("instance", [])
    if isinstance(insts, dict):
        insts = [insts]
    for i in insts:
        if str(i.get("port", {}).get("$")) == want and i.get("ipAddr"):
            print(i["ipAddr"])
            sys.exit(0)
sys.exit(1)
'
}

# registration_is_stale <http_port>
#   exit 0 = STALE, the caller should restart this service
#   exit 1 = not stale, OR unknown
# Missing information NEVER yields 0. An empty Eureka response and a genuinely
# fresh stack must not be confusable.
registration_is_stale() {
    local port=$1 host_ip reg_ip
    host_ip=$(current_host_ip) || return 1
    [ -n "$host_ip" ] || return 1
    reg_ip=$(eureka_registered_ip "$port") || return 1
    [ -n "$reg_ip" ] || return 1
    [ "$reg_ip" != "$host_ip" ]
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash scripts/lib/tests/eureka-test.sh`
Expected: `6 passed, 0 failed`, exit 0.

- [ ] **Step 6: Add a Make target**

In the test-suite section of the `Makefile`, alongside `seed-test-render`:

```make
.PHONY: svc-test-staleness
## svc-test-staleness: decision table for the Eureka freshness check.
## Fixture-driven — no live Eureka, runs with the stack down.
svc-test-staleness:
	@bash scripts/lib/tests/eureka-test.sh
```

Verify: `make svc-test-staleness` prints `6 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/eureka.sh scripts/lib/tests Makefile
git commit -m "feat(services): Eureka registration freshness check

Joins on the HTTP port, not the name: gateway registers as CLOUD-GATEWAY, so a
name-based match would never heal the entry point. Missing information never
reports stale — an unreachable Eureka and a fresh stack must not be confusable."
```

---

## Task 3: F5b — wire the check into the skip branch

**Files:**
- Modify: `scripts/services/start.sh` (sources block near line 18; `start_one()` at line 110)

**Interfaces:**
- Consumes from Task 2: `registration_is_stale <http_port>` (exit 0 = stale), sourced from `scripts/lib/eureka.sh`.
- Consumes existing, from `scripts/lib/registry.sh` — **already sourced by `start.sh` at line 18**, so no new source line is needed for these:
  - `svc_get <name>` → the `services.list` line for that service
  - `svc_field <line> <n>` → the nth whitespace-separated field. **Field 2 is the HTTP port** (`services.list` format is `name http_port grpc_port tier`).
- `stop_one <name>` lives in `scripts/services/stop.sh` and is **not** available here — this task kills the PID directly.

- [ ] **Step 1: Source the new lib**

`scripts/services/start.sh`, after the existing `source .../wait.sh` line (~line 16):

```bash
source "$REPO_ROOT/scripts/lib/eureka.sh"
```

- [ ] **Step 2: Confirm the registry helpers resolve a port**

`svc_get` / `svc_field` are defined in `scripts/lib/registry.sh`, which `start.sh` already sources. Verify the port lookup gives what you expect before wiring it in:

```bash
bash -c 'source scripts/lib/registry.sh; line=$(svc_get gateway); echo "port=$(svc_field "$line" 2)"'
```

Expected: `port=6868`. **If it prints empty, stop** — the whole check depends on this join and an empty port would make `registration_is_stale` receive garbage.

- [ ] **Step 3: Replace the skip branch**

`scripts/services/start.sh`, in `start_one()`, replace:

```bash
    if [ -f "$PID_DIR/$name.pid" ] && kill -0 "$(cat "$PID_DIR/$name.pid")" 2>/dev/null; then
        log_warn "$name already running (PID $(cat "$PID_DIR/$name.pid"))"
        return 0
    fi
```

with:

```bash
    if [ -f "$PID_DIR/$name.pid" ] && kill -0 "$(cat "$PID_DIR/$name.pid")" 2>/dev/null; then
        # "Already running" is not the same as "correct". Under compose these are
        # HOST JVMs that registered the host IP with Eureka; after a network
        # change they are alive, so we skip them, and they keep serving a stale
        # registration. Everything looks up and requests fail, with nothing
        # pointing at the cause.
        #
        # registration_is_stale returns 0 ONLY when Eureka holds a registration
        # for this port whose IP differs. Unreachable Eureka, unregistered
        # service, or an undeterminable host IP all return 1 — so the failure
        # mode here is "does nothing", never "restarts everything".
        local _line _port
        _line=$(svc_get "$name" 2>/dev/null) || _line=""
        _port=$([ -n "$_line" ] && svc_field "$_line" 2 || echo "")
        if [ -n "$_port" ] && registration_is_stale "$_port"; then
            log_warn "$name: Eureka registration is stale (registered $(eureka_registered_ip "$_port"), host is $(current_host_ip)) — restarting"
            kill "$(cat "$PID_DIR/$name.pid")" 2>/dev/null || true
            rm -f "$PID_DIR/$name.pid"
            # fall through to the normal start path below
        else
            log_warn "$name already running (PID $(cat "$PID_DIR/$name.pid"))"
            return 0
        fi
    fi
```

**Note:** `rm -f` here runs inside the script at runtime, not as an assistant tool call — it is not sandbox-blocked. If it is refused during authoring, leave the line and say so.

- [ ] **Step 4: Verify the fast path is unchanged**

With the stack up and the network unchanged:

```bash
make up 2>&1 | tee /tmp/f5-nodrift.log
grep -c 'already running' /tmp/f5-nodrift.log
grep -c 'registration is stale' /tmp/f5-nodrift.log
```

Expected: several `already running` lines and **exactly 0** `registration is stale`. Assert the first count is non-zero — if nothing was already running the test proved nothing about the skip branch.

- [ ] **Step 5: Verify the stale path with the override**

```bash
HOST_IP_OVERRIDE=10.0.0.7 make up 2>&1 | tee /tmp/f5-drift.log
grep -c 'registration is stale' /tmp/f5-drift.log
```

Expected: one line per **registered** service (7 in the current fixture: authorization-server, bff-service, gateway, inventory-service, order-service, payment-service, product-service) and **none** for `eureka-server`, `orchestrator-service`, `mock-paypal-service` or `frontend`, which never register.

Then confirm the stack recovers: `make status` shows services up, and the catalog serves:

```bash
curl -s 'http://localhost:6868/product-service/v1/products?page=1&size=1' | head -c 80
```

Expected: HTTP 200 JSON with `"total":30`. **The response shape is `data.data` with `data.total` — not `data.products`.**

- [ ] **Step 6: Run the suites**

```bash
bash scripts/lib/tests/eureka-test.sh
```

Expected: `6 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/services/start.sh
git commit -m "fix(services): heal stale Eureka registrations instead of skipping them

start_one skipped any service with a live PID. Under compose those are host
JVMs holding the host IP in Eureka, so after a network change they stayed up
and stayed wrong. The check now runs at that same decision, and only there."
```

---

## Task 4: F3 — `up-all.sh` must confirm before spending

**Files:**
- Modify: `scripts/aws/up-all.sh`

**NEVER RUN THIS SCRIPT PAST THE GUARD.** It performs a real, billed EKS bring-up. The refusal path is safe to exercise; nothing else is.

- [ ] **Step 1: Find the first executable statement**

```bash
grep -nE '^[^#]' scripts/aws/up-all.sh | head -8
```

Note the line number of the first non-comment, non-blank line (expect `set -euo pipefail` or similar). The guard goes **immediately after the `set` line and the `ROOT=` assignment, before anything else executes.** Read enough of the file to be certain nothing above it contacts AWS.

- [ ] **Step 2: Add the guard**

Matching `make nuke`'s house style (`Makefile:111`):

```bash
# ── Cost guard ───────────────────────────────────────────────────────────────
# This script creates real, billed AWS infrastructure (EKS, VPC, NAT, RDS, ALB).
# It had NO confirmation until 2026-08-16 — `make aws-all` went straight to spend.
#
# A non-TTY REFUSES rather than proceeds: the absence of a human is not consent.
# Use --yes for deliberate non-interactive runs.
ASSUME_YES=0
for _arg in "$@"; do
    [ "$_arg" = "--yes" ] && ASSUME_YES=1
done

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        echo "REFUSED: up-all.sh creates billed AWS infrastructure and stdin is not a TTY." >&2
        echo "         Re-run interactively, or pass --yes if you mean it." >&2
        exit 1
    fi
    echo "This creates BILLED AWS infrastructure: EKS cluster, VPC + NAT gateway,"
    echo "RDS, and an ALB. It runs until you tear it down with 'make aws-down'."
    read -p "Continue? [y/N] " ans
    [ "$ans" = "y" ] || { echo "Cancelled."; exit 1; }
fi
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n scripts/aws/up-all.sh`
Expected: exit 0, no output.

- [ ] **Step 4: Prove the guard precedes everything, by reading**

```bash
grep -nE '^[^#]' scripts/aws/up-all.sh | head -20
```

Confirm no `terraform`, `aws`, `kubectl`, `helm`, or `"$ROOT"/scripts/...` invocation appears **above** the guard. **Do not proceed to Step 5 until this is confirmed by reading** — if the guard is misplaced, Step 5 spends money.

- [ ] **Step 5: Test the refusal path only**

```bash
echo "" | bash scripts/aws/up-all.sh; echo "exit=$?"
```

Expected: `REFUSED: ... stdin is not a TTY`, `exit=1`. Nothing else runs.

**Do not test `--yes`.** Verify it by reading.

- [ ] **Step 6: Document it**

Add the confirmation to `scripts/aws/RUNBOOK.md` where it describes invoking `up-all.sh`, and note `--yes` for automation.

- [ ] **Step 7: Commit**

```bash
git add scripts/aws/up-all.sh scripts/aws/RUNBOOK.md
git commit -m "fix(aws): confirm before a billed EKS bring-up

up-all.sh created real infrastructure with no prompt. Non-TTY refuses rather
than proceeds — the absence of a human is not consent. --yes opts in."
```

---

## Task 5: F4 — the two teaching pages

**Files:**
- Modify: `docs/k8s-architecture.html` (711 lines, 10 stale refs)
- Modify: `docs/k8s-eli5.html` (282 lines, 4 stale refs)

**`docs/service-architecture.html` has ZERO stale references — do not touch it.** The recorded gap list says three pages; that is wrong.

These are **teaching artifacts**. Rewrite the explanations to describe the Helm reality; do not delete the sections. A learner who came for "how do the overlays work" needs to be taught about the chart, not to find a hole.

- [ ] **Step 1: Enumerate exactly what is stale**

```bash
grep -nE 'k8s/|kustomize|overlay' docs/k8s-architecture.html docs/k8s-eli5.html
```

Expected: 14 hits total. Read each in context before editing — some may be prose describing the concept rather than this repo's layout.

- [ ] **Step 2: Rewrite the references**

The mapping from deleted to current:

| was | is now |
|---|---|
| `k8s/apps/overlays/local` (kustomize) | `deploy/charts/microecom` (Helm umbrella), `make deploy ENV=k8s` |
| `k8s/apps/base/<svc>/` | `charts/apps/templates/deployments.yaml`, one template over `.Values.apps` |
| `k8s/infra/manifests/` | `charts/infra/templates/` |
| `k8s/infra/jobs/*` (bootstrap Jobs) | `make secrets-seed ENV=k8s` + `make seed ENV=k8s STAGE=pre-apps\|post-apps` |
| `make k8s-bootstrap` | `make bootstrap ENV=k8s` |
| `make k8s-apps` | `make deploy ENV=k8s` |

- [ ] **Step 3: Verify no stale references remain**

```bash
grep -cE 'k8s/(apps|infra)|kustomize|overlays' docs/k8s-architecture.html docs/k8s-eli5.html
```

Expected: `0` for both. **Also assert the files are still substantial** — `wc -l` should remain close to 711 and 282. A large drop means sections were deleted rather than rewritten, which is the failure mode this task exists to avoid.

- [ ] **Step 4: Read the rendered pages**

Open both in a browser (or read the HTML) and confirm the explanations still teach a coherent story. Grep cannot answer "does this teach the right thing".

- [ ] **Step 5: Commit**

```bash
git add docs/k8s-architecture.html docs/k8s-eli5.html
git commit -m "docs: teach the Helm reality, not the deleted kustomize tree

Phase 8 deleted k8s/. These two teaching pages still described overlays, bases
and bootstrap Jobs. Rewritten rather than trimmed — a learner needs the chart
explained, not a hole where the explanation was. service-architecture.html had
no stale references and is untouched."
```

---

## Verification summary

| Gate | Where | Criterion |
|---|---|---|
| `make down` stops MinIO | live compose | 0 minio containers after `down`; other-project containers untouched |
| MinIO readiness poll finally exercised | live compose | `make up` after a real cold start reaches `objects seeded` |
| staleness decision table | offline, fixture | `6 passed, 0 failed`; both fail-safe rows assert non-stale explicitly |
| fast path unchanged | live compose | `make up` twice → `already running` non-zero, `registration is stale` **0** |
| stale path heals | live compose | `HOST_IP_OVERRIDE` run restarts exactly the 7 registered services; catalog then serves `total: 30` |
| `up-all.sh` refuses | offline | non-TTY invocation exits 1 before any AWS call; `--yes` verified by reading only |
| teaching pages | `docs/*.html` | 0 stale refs, line counts roughly unchanged, prose still coherent |
