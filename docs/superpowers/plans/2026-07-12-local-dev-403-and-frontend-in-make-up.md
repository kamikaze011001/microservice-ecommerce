# Local-dev 403 Fix + Frontend in `make up` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `make up` produce a stack the frontend can actually talk to — seed `api_role` so the gateway stops returning a blanket 403, start Vite as a tier-4 service, and move dev traffic to a same-origin `/api` proxy.

**Architecture:** Three independent changes to the local-dev orchestration layer only. (1) A new idempotent `mongo-seed-ensure` Makefile target wraps the existing `scripts/seed/mongo-roles.sh` behind a Mongo-readiness poll and joins the `up` chain, mirroring the `mongo-connector-ensure` idiom already there. (2) `frontend` becomes a tier-4 entry in `scripts/services.list`; `start.sh` learns to branch on `pom.xml` vs `package.json`; `stop.sh`'s broken hand-rolled parser is replaced with `registry.sh` helpers so `make down` actually stops things (prerequisite — see Task 1). (3) `frontend/.env.development` points the dev client at `/api`, which the existing (unused) Vite proxy forwards to the gateway.

**Tech Stack:** Bash, GNU Make, Docker Compose, MongoDB (`mongosh`/`mongoimport`), Vite 6 + pnpm, Spring Cloud Gateway.

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-07-12-local-dev-403-and-frontend-in-make-up-design.md`). Every task's requirements implicitly include these.

- **No change may affect k8s local dev or AWS.** If a task tempts you to edit anything under `k8s/`, `terraform/`, `frontend/Dockerfile`, or `frontend/Caddyfile` — stop. You are off-plan.
- **`k8s/images/build.sh` keeps its own `SERVICES=(...)` array** and must NOT be made to read `scripts/services.list`. That separation is what makes Task 3 k8s-safe.
- **Seed only `api_role` from `make up` — never `scripts/seed/all.sh`.** `mongo-products.sh` drops its collection before importing, so calling `all.sh` from `up` would wipe local product data on every `make up`.
- **`VITE_API_BASE_URL` is build-time.** Vite loads `.env.development` only in dev mode; `pnpm build` (production) never reads it, and Docker builds pass `--build-arg` which wins regardless. Do not add `.env`, `.env.production`, or touch `frontend/Dockerfile`.
- **The gateway is on port `6868`** locally (`scripts/services.list`). `8080` is the Caddy port *inside* the frontend container — not a local port.
- **A 403 from this gateway can never mean "unauthenticated"** (that is a 401 from `JwtAuthenticationFilter`). It means "no matching `api_role` row" or "wrong role". Assertions in this plan depend on that distinction.
- Branch: `fix/local-dev-403-and-frontend-up`. Commit after every task.

## Testing strategy (read before Task 1)

This repo has **no shell test harness** — no bats, no `.bats` files, no `tests/` dir for scripts. Installing one is out of scope. So "write the failing test first" here means: **write an executable assertion command that fails today for the exact reason the task fixes, run it, watch it fail, then fix, then re-run.** Every task below gives you that command and its expected before/after output. Treat them as tests: if the "expected: FAIL" step passes, stop — your premise is wrong and the rest of the task is unsafe.

Tasks 1 and 3 have assertions that need **no Docker and no running stack** (pure parser behavior). Tasks 2 and 4 need the stack.

## File structure

| File | Change | Task |
|---|---|---|
| `scripts/services/stop.sh` | Modify — replace parser with `registry.sh` helpers | 1 |
| `scripts/seed/mongo-roles.sh` | Modify — add Mongo readiness poll | 2 |
| `Makefile` | Modify — add `mongo-seed-ensure`, wire into `up` | 2 |
| `scripts/services.list` | Modify — add `frontend` tier 4 | 3 |
| `scripts/services/start.sh` | Modify — branch maven/node, tier loop `0..4` | 3 |
| `frontend/.env.development` | Create — `VITE_API_BASE_URL=/api` | 4 |
| `CLAUDE.md` | Modify — gateway port 8080 → 6868 | 4 |
| `frontend/CLAUDE.md` | Modify — gateway port + credentials/CORS claim | 4 |

---

### Task 1: Repair `stop.sh`'s services.list parser

**Why first:** `make down` currently stops **nothing**. It is masked today only because `infra-down` kills Docker and the JVM services then crash on their own. Vite has no Docker dependency — so if you add the frontend (Task 3) before fixing this, `make down` leaves Vite squatting on 5173 and the next `make up` fails to bind. This task is a prerequisite, not cleanup.

**The bug:** `services.list` stores entries as quoted bash array elements. `registry.sh` *sources* the file, so bash strips the quotes. `stop.sh` instead parses the raw text with `awk`/`read`, so it sees `"gateway` (leading double-quote) and also ingests the literal `SERVICES=(` and `)` lines. Consequence: no pidfile name ever matches, `port_for` always returns empty, the `lsof` orphan-kill fallback never fires, and `make down` prints "All services stopped" while stopping nothing.

**Files:**
- Modify: `scripts/services/stop.sh` (whole file)

**Interfaces:**
- Consumes: `scripts/lib/registry.sh` — `load_registry` (loads `$SERVICES`), `svc_list` (prints one `"name http grpc tier"` line per service), `svc_field <line> <1..4>` (1=name, 2=http, 3=grpc, 4=tier), `svc_get <name>` (prints the line, returns 1 if unknown). `registry.sh` reads `$REPO_ROOT` **at source time**, so `REPO_ROOT` must be exported before sourcing it, and `colors.sh` must be sourced first (`load_registry` calls `log_err`).
- Produces: a working `make down`. Task 3 relies on the `lsof -tiTCP:<port>` fallback in this file to reap Vite's forked child.

- [ ] **Step 1: Write the failing assertion**

This proves the parser is broken without needing Docker or a running stack. Run it from the repo root:

```bash
bash -c '
  echo "--- what stop.sh actually iterates today ---"
  while read -r name port _grpc _tier; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue;; esac
    printf "name=[%s] port=[%s]\n" "$name" "$port"
  done < scripts/services.list
'
```

- [ ] **Step 2: Run it to see the breakage**

Expected output — note the leading `"` on every name, and the junk `SERVICES=(` / `)` rows:

```
name=[SERVICES=(] port=[]
name=["eureka-server] port=[8761]
name=["authorization-server] port=[6666]
...
name=[)] port=[]
```

A name of `"eureka-server` never matches `logs/pids/eureka-server.pid`, and `port_for "eureka-server"` (matching `$1 == s`) returns empty — so `kill_orphan_on_port` returns early every time. That is the bug, confirmed.

- [ ] **Step 3: Rewrite `scripts/services/stop.sh`**

Replace the entire file with this. The kill logic is unchanged — only the parsing changes.

```bash
#!/bin/bash
# Stop one service or all started services. Usage: stop.sh [name|all]   (default: all)
#
# Two-step kill per service:
#   1. SIGTERM the PID in logs/pids/<name>.pid (if present)
#   2. Fallback: kill anything still listening on the service's canonical port
#      from scripts/services.list. Without step 2, orphans started outside the
#      pidfile system (direct `mvn spring-boot:run`, sessions before pidfile
#      tracking existed) survive `make nuke` and silently break fresh
#      bootstraps — the port stays bound, so a new boot crashes on the
#      Atomikos transaction-log lock and seed-data fails on missing tables.
#      Step 2 is also the only thing that reaps `pnpm dev`'s forked Vite child,
#      whose PID is not the one we wrote to the pidfile.
#
# services.list stores entries as quoted bash array elements, so it MUST be read
# through registry.sh (which sources it, letting bash strip the quotes). Parsing
# the raw text yields names like `"gateway` and silently stops nothing.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/registry.sh
source "$REPO_ROOT/scripts/lib/registry.sh"

PID_DIR="$REPO_ROOT/logs/pids"

load_registry

port_for() {
    local line
    line=$(svc_get "$1") || return 0
    svc_field "$line" 2
}

kill_orphan_on_port() {
    local name=$1 port=$2
    [ -n "$port" ] && [ "$port" != "-" ] || return 0
    local orphans
    orphans=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    [ -n "$orphans" ] || return 0
    log_warn "$name: orphan(s) on :$port — killing $orphans"
    # shellcheck disable=SC2086
    kill $orphans 2>/dev/null || true
    sleep 1
    orphans=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$orphans" ]; then
        log_warn "$name: orphan(s) survived SIGTERM, sending SIGKILL"
        # shellcheck disable=SC2086
        kill -9 $orphans 2>/dev/null || true
    fi
}

stop_one() {
    local name=$1
    local pid_file="$PID_DIR/$name.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Stopping $name (PID $pid)..."
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
            log_ok "$name stopped"
        else
            log_warn "$name (PID $pid) was not running"
        fi
        rm -f "$pid_file"
    fi
    kill_orphan_on_port "$name" "$(port_for "$name")"
}

target=${1:-all}

if [ "$target" = "all" ]; then
    # Iterate every service in services.list — covers both pidfile-tracked
    # processes AND port orphans that have no pidfile.
    while IFS= read -r line; do
        stop_one "$(svc_field "$line" 1)"
    done < <(svc_list)
    log_ok "All services stopped"
else
    stop_one "$target"
fi
```

- [ ] **Step 4: Re-run the assertion — parser now yields clean names**

```bash
bash -c '
  export REPO_ROOT=$(pwd)
  source scripts/lib/colors.sh
  source scripts/lib/registry.sh
  load_registry
  while IFS= read -r line; do
    name=$(svc_field "$line" 1)
    printf "name=[%s] port=[%s]\n" "$name" "$(svc_field "$line" 2)"
  done < <(svc_list)
'
```

Expected — no quotes, no `SERVICES=(` row, exactly 10 lines:

```
name=[eureka-server] port=[8761]
name=[authorization-server] port=[6666]
name=[gateway] port=[6868]
name=[inventory-service] port=[6969]
name=[product-service] port=[7777]
name=[order-service] port=[9696]
name=[payment-service] port=[8484]
name=[orchestrator-service] port=[9999]
name=[bff-service] port=[8087]
name=[mock-paypal-service] port=[8585]
```

- [ ] **Step 5: Prove `make down` now actually stops a service**

With the stack up (`make up` if it isn't):

```bash
lsof -tiTCP:7777 -sTCP:LISTEN   # product-service — expect a PID
bash scripts/services/stop.sh product-service
lsof -tiTCP:7777 -sTCP:LISTEN   # expect: empty output, exit 1
```

Expected: the second `lsof` prints nothing. Before this task, it would still print the PID. Restart it afterwards with `bash scripts/services/start.sh product-service` if you want the stack whole.

- [ ] **Step 6: Commit**

```bash
git add scripts/services/stop.sh
git commit -m "fix(scripts): stop.sh must read services.list through registry.sh

The hand-rolled awk/read parser saw quoted array elements (\"gateway) and
the literal SERVICES=( / ) lines, so no pidfile ever matched and the
lsof orphan-kill fallback never fired — make down stopped nothing while
printing 'All services stopped'. Masked because infra-down kills Docker
and the JVM services crash on their own."
```

---

### Task 2: Guarantee `api_role` is seeded on `make up`

**Why:** This is the actual 403 fix. The gateway's `AuthorizationFilter` resolves every request's permissions from the MongoDB `api_role` collection; a path matching zero rows returns 403 `auth.forbidden`. Only `make bootstrap` seeds — `make up` does not. So on any machine with an empty Mongo volume (fresh clone, `make nuke`, Docker prune/Desktop reset), `make up` reports ten healthy services and hands you a stack where *every* API call is forbidden, including `PERMIT_ALL` routes that need no token at all.

**Files:**
- Modify: `scripts/seed/mongo-roles.sh` (add readiness poll)
- Modify: `Makefile` (`up` target ~line 75; new `mongo-seed-ensure` target near the seed block ~line 148)

**Interfaces:**
- Consumes: `scripts/lib/colors.sh` (`log_info`/`log_ok`/`log_warn`/`log_err`), `scripts/lib/env.sh` (`load_dotenv`).
- Produces: a `mongo-seed-ensure` Make target, safe to call unconditionally and repeatedly.

**Design note — why patch `mongo-roles.sh` rather than add a wrapper script:** `mongo-roles.sh` is *already* idempotent (it skips when `countDocuments() > 0`). The only thing missing for `make up` use is a readiness poll: a started Mongo container is not yet an *accepting* Mongo, and today `count` would come back empty, `${count:-0}` would evaluate to 0, `mongoimport` would fail, and `set -e` would kill `make up`. Adding the poll in place keeps one seed script instead of two that can drift.

- [ ] **Step 1: Write the failing assertion**

Drop the collection to recreate the original bug, then confirm `make up` does not heal it.

```bash
docker exec ecommerce-mongodb mongosh ecommerce_inventory --quiet \
  --authenticationDatabase admin -u ecommerce -p ecommerce123 \
  --eval 'db.api_role.drop()'
make up
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:6868/product-service/v1/products
```

- [ ] **Step 2: Run it to verify the bug**

Expected: `403`. That route is `PERMIT_ALL` and needs no token — a 403 on it can only mean the `api_role` table has no matching row. (If you get 200, the collection was not actually dropped; re-check.)

- [ ] **Step 3a: Add the readiness poll to `scripts/seed/mongo-roles.sh`**

Insert this block after the `CONTAINER=` line and **before** the existing `count=$(...)` line:

```bash
# A started Mongo container is not an accepting Mongo. Without this poll the
# countDocuments below comes back empty, ${count:-0} evaluates to 0, mongoimport
# fails against a not-yet-listening server, and `set -e` kills `make up`.
# 15 x 2s = 30s, matching scripts/kafka/ensure-connector.sh.
for i in $(seq 1 15); do
    if docker exec "$CONTAINER" mongosh --quiet \
        --authenticationDatabase admin -u "$USER" -p "$PASS" \
        --eval 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 15 ]; then
        log_err "MongoDB ($CONTAINER) not accepting connections after 30s"
        exit 1
    fi
    sleep 2
done
```

- [ ] **Step 3b: Add the `mongo-seed-ensure` target to the `Makefile`**

Add it to the seed block (next to `seed-mongo`), mirroring the `mongo-connector-ensure` idiom:

```make
# Idempotent: mongo-roles.sh skips when api_role is already populated. Safe to
# call on every `make up`. Deliberately NOT seed-data / all.sh — mongo-products.sh
# DROPS its collection before importing, so calling it from `up` would wipe local
# product data on every start.
mongo-seed-ensure:
	@bash scripts/seed/mongo-roles.sh
```

…and add it to that block's `.PHONY` line:

```make
.PHONY: seed-data seed-mysql seed-mongo mongo-seed-ensure
```

- [ ] **Step 3c: Wire it into `up`**

Change `Makefile` line 75 from:

```make
up: infra-up vault-unseal mongo-connector-ensure svc-start
```

to:

```make
up: infra-up vault-unseal mongo-seed-ensure mongo-connector-ensure svc-start
```

Ordering matters: after `infra-up` (Mongo must exist) and before `svc-start` (no window where services are up but every route is forbidden).

- [ ] **Step 4: Re-run the assertion — 403 becomes 200**

```bash
docker exec ecommerce-mongodb mongosh ecommerce_inventory --quiet \
  --authenticationDatabase admin -u ecommerce -p ecommerce123 \
  --eval 'db.api_role.drop()'
make down
make up
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:6868/product-service/v1/products
```

Expected: `200`.

- [ ] **Step 5: Assert the 403→401 flip on an authenticated route**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:6868/bff-service/v1/cart
```

Expected: `401` — not 403. This is the signature of the fix: with `api_role` populated, an unauthenticated call to a protected route is correctly rejected by `JwtAuthenticationFilter` (401) rather than falling through to "path not registered" (403).

- [ ] **Step 6: Assert idempotency — second `make up` is a no-op and does not wipe products**

```bash
docker exec ecommerce-mongodb mongosh ecommerce_inventory --quiet \
  --authenticationDatabase admin -u ecommerce -p ecommerce123 \
  --eval 'db.product.countDocuments()'   # note the number (expect 30)
make up 2>&1 | grep -i api_role
docker exec ecommerce-mongodb mongosh ecommerce_inventory --quiet \
  --authenticationDatabase admin -u ecommerce -p ecommerce123 \
  --eval 'db.product.countDocuments()'   # expect the SAME number
```

Expected: the grep prints `api_role already seeded (40 docs) — skipping`, and the product count is unchanged. If products got wiped, you wired `seed-data`/`all.sh` into `up` instead of `mongo-roles.sh` — revert and re-read Step 3b.

- [ ] **Step 7: Commit**

```bash
git add Makefile scripts/seed/mongo-roles.sh
git commit -m "fix(make): seed api_role on \`make up\`, not just bootstrap

The gateway resolves every request's permissions from the api_role
collection; zero matching rows => 403 auth.forbidden. Only bootstrap
seeded it, so any machine with an empty Mongo volume got ten healthy
services and a stack where every call — including PERMIT_ALL routes —
was forbidden. mongo-roles.sh already self-guards; it just needed a
Mongo-readiness poll to be safe in the up chain."
```

---

### Task 3: Start the frontend from `make up`

**Files:**
- Modify: `scripts/services.list` (add one entry)
- Modify: `scripts/services/start.sh` (`start_one` at lines 69-91; tier loop at line 127)

**Interfaces:**
- Consumes: Task 1's repaired `stop.sh` (its `lsof -tiTCP:5173` fallback is what reaps Vite's forked child — the pidfile PID belongs to `pnpm`, not to Vite). `registry.sh`'s `svc_list`/`svc_field`/`check_drift`. `scripts/lib/wait.sh`'s `wait_for_port <label> <port>`.
- Produces: `frontend` as a tier-4 registry entry on port 5173. `status.sh` already reads the registry, so `make status` picks it up with no further change.

**k8s/AWS safety (do not skip):** the consumers of `scripts/services.list` are `registry.sh`, `start.sh`, `stop.sh`, and `scripts/next-error-target.mjs`. `k8s/images/build.sh` maintains its **own** `SERVICES=(...)` array and does not read the file. `next-error-target.mjs` filters with `name.endsWith('-service') || name === 'gateway'`, so `frontend` is invisible to it. `check_drift` scans *directories → list* (globbing only `*-service`, `gateway`, `eureka-server`), so an extra list entry cannot trip it. Nothing here reaches k8s or AWS.

- [ ] **Step 1: Write the failing assertion**

`start.sh` hardcodes `mvn spring-boot:run` for every service. Prove it would try to Maven-build the SPA:

```bash
grep -n 'mvn spring-boot:run' scripts/services/start.sh
grep -c 'pom.xml\|package.json' <(sed -n '69,91p' scripts/services/start.sh)
ls frontend/pom.xml 2>&1
```

- [ ] **Step 2: Run it to verify**

Expected: two `mvn spring-boot:run` lines (85 and 87), `start_one` contains no `package.json` branch, and `ls frontend/pom.xml` prints `No such file or directory`. So adding `frontend` to the registry today would make `start_one` run `mvn spring-boot:run` in a directory with no `pom.xml` — it must branch on the build system first.

- [ ] **Step 3a: Add the registry entry**

In `scripts/services.list`, add a final line inside the `SERVICES=(...)` array, after `mock-paypal-service`:

```
  "frontend              5173  -     4"
```

Tier 4 — the SPA starts only after the gateway (tier 1) is listening.

- [ ] **Step 3b: Split `start_one` in `scripts/services/start.sh`**

Replace the whole `start_one` function (lines 69-91) with these three functions:

```bash
start_maven() {
    local name=$1 dir=$2
    local jhome
    jhome=$(service_java_home "$dir")

    log_info "Starting $name..."
    if [ -n "$jhome" ]; then
        log_info "$name pins a newer Java than PATH — launching under ${jhome##*/}"
        (cd "$dir" && JAVA_HOME="$jhome" PATH="$jhome/bin:$PATH" mvn spring-boot:run) > "$LOG_DIR/$name.log" 2>&1 &
    else
        (cd "$dir" && mvn spring-boot:run) > "$LOG_DIR/$name.log" 2>&1 &
    fi
    echo $! > "$PID_DIR/$name.pid"
    log_ok "$name started (PID $!)"
}

# Note: the PID recorded here belongs to `pnpm`, not to the Vite server it forks.
# SIGTERM on it does not reliably reap the child — stop.sh's `lsof -tiTCP:5173`
# fallback is what actually frees the port. Don't remove that fallback.
start_node() {
    local name=$1 dir=$2
    if ! command -v pnpm >/dev/null 2>&1; then
        log_err "$name needs pnpm (https://pnpm.io/installation) — install it, or drop $name from scripts/services.list"
        return 1
    fi

    : > "$LOG_DIR/$name.log"
    if [ ! -d "$dir/node_modules" ]; then
        log_info "$name: node_modules missing — running pnpm install (first run, this takes a minute)..."
        if ! (cd "$dir" && pnpm install --frozen-lockfile) >> "$LOG_DIR/$name.log" 2>&1; then
            log_err "$name: pnpm install failed — see logs/services/$name.log"
            return 1
        fi
    fi

    log_info "Starting $name..."
    (cd "$dir" && pnpm dev) >> "$LOG_DIR/$name.log" 2>&1 &
    echo $! > "$PID_DIR/$name.pid"
    log_ok "$name started (PID $!)"
}

start_one() {
    local name=$1
    local dir="$REPO_ROOT/$name"
    [ -d "$dir" ] || { log_err "Directory not found: $dir"; return 1; }

    if [ -f "$PID_DIR/$name.pid" ] && kill -0 "$(cat "$PID_DIR/$name.pid")" 2>/dev/null; then
        log_warn "$name already running (PID $(cat "$PID_DIR/$name.pid"))"
        return 0
    fi

    # Branch on what the directory actually contains — the registry holds JVM
    # services and the Vue SPA side by side.
    if [ -f "$dir/pom.xml" ]; then
        start_maven "$name" "$dir"
    elif [ -f "$dir/package.json" ]; then
        start_node "$name" "$dir"
    else
        log_err "$name: no pom.xml or package.json in $dir — don't know how to launch it"
        return 1
    fi
}
```

`service_java_home` (lines 42-67) is unchanged and stays where it is — `start_maven` calls it.

- [ ] **Step 3c: Extend the tier loop**

Change line 127 of `scripts/services/start.sh` from:

```bash
    for tier in 0 1 2 3; do
```

to:

```bash
    for tier in 0 1 2 3 4; do
```

- [ ] **Step 4: Verify — frontend starts and stops with the stack**

```bash
make down
lsof -tiTCP:5173 -sTCP:LISTEN            # expect: empty
make up
lsof -tiTCP:5173 -sTCP:LISTEN            # expect: a PID
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5173/   # expect: 200
make status | grep frontend              # expect: frontend listed, port 5173
make down
lsof -tiTCP:5173 -sTCP:LISTEN            # expect: empty again — this is Task 1 paying off
```

Expected: all five as annotated. If the final `lsof` still shows a PID, Task 1's fix is not in place — go back; do not "fix" it by adding a special case for Vite here.

- [ ] **Step 5: Verify the drift guard and the error-catalog script still behave**

```bash
bash -c '
  export REPO_ROOT=$(pwd)
  source scripts/lib/colors.sh
  source scripts/lib/registry.sh
  load_registry
  check_drift && echo "drift guard: clean"
'
node scripts/next-error-target.mjs | grep -i frontend   # expect: no match, exit 1
grep -n 'SERVICES=(' k8s/images/build.sh                # expect: still its own array
```

Expected: `drift guard: clean` (frontend is not in `check_drift`'s glob, so the extra registry entry cannot trip it), `next-error-target.mjs` never mentions `frontend` (it filters to `*-service`/`gateway`), and `k8s/images/build.sh` still owns its own `SERVICES` array. This is the k8s-safety check — do not skip it.

- [ ] **Step 6: Commit**

```bash
git add scripts/services.list scripts/services/start.sh
git commit -m "feat(scripts): start the frontend from make up as a tier-4 service

start_one branched only on Maven; it now dispatches on pom.xml vs
package.json, so the Vue SPA runs under \`pnpm dev\` (with a first-run
pnpm install) alongside the JVM services. Tier 4 => Vite comes up after
the gateway. k8s/images/build.sh keeps its own SERVICES array, so this
does not reach k8s or AWS."
```

---

### Task 4: Same-origin `/api` in dev + correct two stale docs

**Why:** Cleanup, not the bug fix — CORS was never broken (measured: `OPTIONS /bff-service/v1/cart` → 200 with the right `Access-Control-Allow-Origin`, because `CorsWebFilter` is ordered at `SecurityWebFiltersOrder.CORS`, ahead of `AUTHORIZATION`, and answers preflight itself). It is included because it removes the entire class of failure the original hypothesis pointed at: no preflight, no allow-list to drift out of, and no `127.0.0.1`-vs-`localhost` footgun (which *would* defeat the allow-list for real). Dev then exercises the same same-origin topology as AWS.

**Files:**
- Create: `frontend/.env.development`
- Modify: `CLAUDE.md` (line 52 Swagger URL, line 57 port table)
- Modify: `frontend/CLAUDE.md` (line 3 gateway URL, line 42 credentials/CORS claim)

**Interfaces:**
- Consumes: the `/api` proxy already present in `frontend/vite.config.ts` — it targets `http://localhost:6868`, strips the `/api` prefix, and sets `changeOrigin`. It has simply never been exercised, because the client defaults to an absolute URL: `const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:6868'` (`src/api/client.ts:9`, `src/api/refresh.ts:3`, `src/api/queries/auth.ts:13`). **Do not edit those three files** — the env var is the whole mechanism.
- Produces: nothing other tasks depend on.

**Safety:** `frontend/.gitignore` ignores only `.env.local` and `.env.*.local`, so `.env.development` is committed and shared. Vite loads it **only in dev mode**; `pnpm build` runs in production mode and never reads it, and `frontend/Dockerfile` passes `--build-arg VITE_API_BASE_URL` explicitly — which takes precedence over `.env` files regardless. Vitest runs in *test* mode, so the 274 unit tests keep the existing `?? 'http://localhost:6868'` fallback and are unaffected.

- [ ] **Step 1: Write the failing assertion**

Prove the dev client currently uses an absolute cross-origin URL — i.e. that every dev call is a CORS call:

```bash
ls frontend/.env* 2>&1
grep -rn "VITE_API_BASE_URL" frontend/src/
grep -n "'/api'" frontend/vite.config.ts
```

- [ ] **Step 2: Run it to verify**

Expected: `frontend/.env.development` does not exist (`No such file or directory`); the three `src/api/*` files fall back to `http://localhost:6868`; and `vite.config.ts` *does* define an `/api` proxy. So the proxy exists and is dead code — nothing ever requests `/api`.

- [ ] **Step 3a: Create `frontend/.env.development`**

```
# Local dev only.
#
# Vite loads .env.development ONLY in dev mode (`pnpm dev`). `pnpm build` runs in
# production mode and never reads it, and the Docker build passes
# --build-arg VITE_API_BASE_URL explicitly (which outranks .env files anyway).
# So this cannot leak into the k8s or AWS images. Vitest runs in test mode, so
# unit tests keep the `?? 'http://localhost:6868'` fallback in src/api/client.ts.
#
# `/api` is same-origin: the browser calls http://localhost:5173/api/... and the
# proxy in vite.config.ts forwards it server-side to the gateway on :6868,
# stripping the prefix. No preflight, no CORS allow-list to drift out of — the
# same topology AWS serves in production.
VITE_API_BASE_URL=/api
```

- [ ] **Step 3b: Fix the two stale port references in root `CLAUDE.md`**

Line 52 — replace:

```
4. Swagger UI: `http://localhost:8080/swagger-ui.html`
```

with:

```
4. Swagger UI: `http://localhost:6868/swagger-ui.html`
```

Line 57 — replace the port-table row:

```
| Gateway (entry point) | 8080 |
```

with:

```
| Gateway (entry point) | 6868 |
| Frontend (Vite dev server) | 5173 |
```

(8080 is the Caddy port *inside* the frontend container, not a local port. The Vite row is new — Task 3 put it in `make up`, so it belongs in the table.)

- [ ] **Step 3c: Fix `frontend/CLAUDE.md`**

Line 3 — replace:

```
Vue 3 + Vite + TypeScript SPA. Hits the JVM stack through the gateway at `http://localhost:8080`.
```

with:

```
Vue 3 + Vite + TypeScript SPA. Hits the JVM stack through the gateway, which runs on `:6868` locally.
In dev the SPA calls the same-origin path `/api/...`, which the Vite proxy (`vite.config.ts`) forwards
to `http://localhost:6868`. `make up` starts the dev server as a tier-4 service on `:5173`.
```

Line 42 — replace:

```
- Auth: gateway sets cookies / returns JWT; client sends credentials. CORS is permissive on `:5173`.
```

with:

```
- Auth: the gateway returns a JWT, which `src/api/client.ts` attaches as an `Authorization: Bearer`
  header. There are **no cookies and no `credentials: 'include'`** anywhere in `src/` — don't add them.
- Dev traffic is same-origin via the `/api` proxy (`VITE_API_BASE_URL=/api` in `.env.development`),
  so CORS is not in the request path at all. The gateway's allow-list still lists `:5173` as a
  belt-and-braces fallback for anyone running the SPA without the proxy.
```

- [ ] **Step 4: Verify — the SPA works over `/api`, and nothing else moved**

```bash
cd frontend && pnpm test && pnpm typecheck && cd ..
make down && make up
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5173/api/product-service/v1/products
grep -rn "8080" CLAUDE.md frontend/CLAUDE.md
```

Expected: 274 tests pass and typecheck is clean (they run in test mode, so the env file is invisible to them); the proxied storefront call returns `200`; and the `grep` finds no `8080` in either doc. Then open `http://localhost:5173` in a browser, load the storefront, and confirm in DevTools → Network that requests go to `localhost:5173/api/...` with **no `OPTIONS` preflight row**.

- [ ] **Step 5: Verify the k8s/AWS build is untouched**

```bash
cd frontend && pnpm build 2>&1 | tail -3 && cd ..
grep -rn "VITE_API_BASE_URL" frontend/Dockerfile k8s/images/build.sh
git status --short frontend/Dockerfile frontend/Caddyfile k8s/
```

Expected: the production build succeeds; `frontend/Dockerfile` still declares `ARG VITE_API_BASE_URL=/api` and `k8s/images/build.sh` still passes `--build-arg "VITE_API_BASE_URL=${VITE_API_BASE_URL-http://api.microecom.local}"`; and `git status` shows **no modifications** under `frontend/Dockerfile`, `frontend/Caddyfile`, or `k8s/`. If anything there is dirty, you went off-plan — revert it.

- [ ] **Step 6: Commit**

```bash
git add frontend/.env.development CLAUDE.md frontend/CLAUDE.md
git commit -m "feat(frontend): same-origin /api in dev; fix stale gateway-port docs

vite.config.ts has always had an /api proxy to :6868; nothing used it,
because the client defaulted to the absolute http://localhost:6868. Point
dev at /api so local dev is same-origin — same topology as AWS, and the
CORS allow-list leaves the request path entirely. Build-time only: pnpm
build is production mode and the Docker build passes --build-arg, so k8s
and AWS are untouched.

Also: root CLAUDE.md said the gateway was on 8080 (that's Caddy inside the
frontend container; it's 6868), and frontend/CLAUDE.md claimed the client
sends credentials — there is no withCredentials anywhere in src/."
```

---

## Final verification (run once, after all four tasks)

This is the spec's Verification section, end to end. Start from a cold, unseeded Mongo — that is the state that produced the original bug.

```bash
# 1. Reproduce the original failure state
docker exec ecommerce-mongodb mongosh ecommerce_inventory --quiet \
  --authenticationDatabase admin -u ecommerce -p ecommerce123 \
  --eval 'db.api_role.drop()'
make down
make up

# 2. PERMIT_ALL route: 200, not 403
curl -s -o /dev/null -w 'storefront: %{http_code}\n' \
  http://localhost:6868/product-service/v1/products

# 3. Authenticated route, no token: 401, not 403
curl -s -o /dev/null -w 'cart (no token): %{http_code}\n' \
  http://localhost:6868/bff-service/v1/cart

# 4. Idempotent second run — seed is a no-op, products survive
docker exec ecommerce-mongodb mongosh ecommerce_inventory --quiet \
  --authenticationDatabase admin -u ecommerce -p ecommerce123 \
  --eval 'db.product.countDocuments()'
make up 2>&1 | grep -i 'api_role already seeded'
docker exec ecommerce-mongodb mongosh ecommerce_inventory --quiet \
  --authenticationDatabase admin -u ecommerce -p ecommerce123 \
  --eval 'db.product.countDocuments()'

# 5. Vite is up and same-origin
curl -s -o /dev/null -w 'spa: %{http_code}\n' http://localhost:5173/
curl -s -o /dev/null -w 'spa /api proxy: %{http_code}\n' \
  http://localhost:5173/api/product-service/v1/products

# 6. make down frees 5173
make down
lsof -tiTCP:5173 -sTCP:LISTEN && echo 'FAIL: 5173 still bound' || echo 'ok: 5173 free'

# 7. Frontend suite green
cd frontend && pnpm test && pnpm typecheck && cd ..
```

Expected: `storefront: 200`, `cart (no token): 401`, the same product count before and after (30), `api_role already seeded (40 docs) — skipping`, `spa: 200`, `spa /api proxy: 200`, `ok: 5173 free`, and a green frontend suite.

Finally, open `http://localhost:5173` in a browser: the storefront renders products, and DevTools → Network shows requests to `localhost:5173/api/...` with **no `OPTIONS` preflight**.
