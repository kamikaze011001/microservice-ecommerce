# Bootstrap Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace 8 root-level shell scripts (~2,000 LOC) with a Makefile-driven `scripts/` tree, add a service-list source of truth, auto-unseal Vault, and wire three on-disk seed datasets to load on first run.

**Architecture:** A single `Makefile` exposes `bootstrap` (first-run, slow, idempotent) and `up` (daily, fast). Both are thin wrappers over scripts in `scripts/{lib,infra,vault,kafka,maven,seed,services}/`. A `scripts/services.env` registry replaces the duplicated service map. Seed data (`docker/ecommerce.sql` → MySQL `ecommerce_dev`; `docker/api_role.json` → Mongo `ecommerce_inventory.api_role`; `docker/product.json` → Mongo `ecommerce_inventory.product`) loads as the last step of `make bootstrap`, idempotently.

**Tech Stack:** GNU Make, Bash, Docker Compose, MySQL 8 client (in master container), `mongoimport` (in mongodb container), Vault HTTP API.

**Spec:** `docs/superpowers/specs/2026-04-27-bootstrap-refactor-design.md`

**Test approach:** This refactor has no new test suites. Each task verifies by running its targets end-to-end and asserting expected output, exit codes, or post-conditions (services up, collections seeded, etc.). Final task runs the full cold-start flow.

---

## File Structure

**Created:**
```
Makefile
scripts/
  lib/{colors.sh,env.sh,wait.sh,registry.sh}
  services.env
  infra/{up.sh,down.sh,status.sh}
  vault/{init.sh,unseal.sh,import-secrets.sh}
  kafka/{topics.sh,mongo-connector.sh}
  maven/install-modules.sh
  seed/{all.sh,mysql.sh,mongo-roles.sh,mongo-products.sh}
  services/{start.sh,stop.sh,status.sh,logs.sh}
```

**Modified:**
- `docker/mongodb.yml` — mount `../docker/api_role.json` and `../docker/product.json` into the container at `/seed/`
- `CLAUDE.md` — replace setup section with `make` targets
- `README.md` — replace setup section with `make` targets

**Deleted (after verification, last task):**
- Root-level `start-infrastructure.sh`, `init-vault.sh`, `init-kafka-topics.sh`, `install-mongodb-kafka-connector.sh`, `install-modules.sh`, `start-services.sh`, `vault-import-secrets.sh`, `vault-login.sh`

Notes:
- `scripts/maven/install-modules.sh` is verbatim from the existing `install-modules.sh` (no rewrite needed beyond moving).
- `scripts/vault/init.sh` and `scripts/vault/unseal.sh` are split out from the existing `init-vault.sh` (which has both `init` and `unseal` subcommands today).
- `scripts/kafka/topics.sh` is verbatim from `init-kafka-topics.sh`. `scripts/kafka/mongo-connector.sh` is verbatim from `install-mongodb-kafka-connector.sh`.
- `scripts/infra/up.sh` is the docker-compose orchestration logic from `start-infrastructure.sh`, minus the Vault init/unseal step (moved to Vault scripts) and minus the inline service-list (moved to registry).
- `scripts/services/{start,stop,status,logs}.sh` are NEW rewrites (driven by `services.env`); the old `start-services.sh` is deleted.

---

## Task 1: Shared library — colors, env loader, wait, registry parser

**Files:**
- Create: `scripts/lib/colors.sh`
- Create: `scripts/lib/env.sh`
- Create: `scripts/lib/wait.sh`
- Create: `scripts/lib/registry.sh`

These four files are sourced by every other script. Centralizing them removes the duplicated color/wait/load_env code that exists in 8 places today.

- [ ] **Step 1: Create `scripts/lib/colors.sh`**

```bash
#!/bin/bash
# Shared color codes. Source, don't execute.
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export NC='\033[0m'

# Logging helpers — write to stderr so command output stays clean on stdout
log_info()  { echo -e "${BLUE}$*${NC}" >&2; }
log_ok()    { echo -e "${GREEN}✓ $*${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
log_err()   { echo -e "${RED}✗ $*${NC}" >&2; }
```

- [ ] **Step 2: Create `scripts/lib/env.sh`**

```bash
#!/bin/bash
# Load docker/.env and (optionally) extract VAULT_TOKEN from vault-keys.json.
# Source, don't execute. Caller decides whether vault token is required.

# Resolves repo root from any caller location: $REPO_ROOT is exported.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

load_dotenv() {
    if [ -f "$REPO_ROOT/docker/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        source "$REPO_ROOT/docker/.env"
        set +a
        log_ok "Loaded docker/.env"
    else
        log_err "docker/.env not found — copy from docker/.env.example and fill in values"
        return 1
    fi
}

load_vault_token() {
    if [ ! -f "$REPO_ROOT/vault-keys.json" ]; then
        log_err "vault-keys.json not found — run 'make bootstrap' first"
        return 1
    fi
    VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('$REPO_ROOT/vault-keys.json'))['root_token'])" 2>/dev/null)
    if [ -z "$VAULT_TOKEN" ]; then
        log_err "Could not extract VAULT_TOKEN from vault-keys.json"
        return 1
    fi
    export VAULT_TOKEN
    log_ok "VAULT_TOKEN loaded"
}
```

- [ ] **Step 3: Create `scripts/lib/wait.sh`**

```bash
#!/bin/bash
# Port and HTTP readiness checks. Source, don't execute.

# wait_for_port <label> <port> [max_attempts=36]
# Polls localhost:<port> at 5s intervals. 36*5s = 3min default.
wait_for_port() {
    local label=$1 port=$2 max=${3:-36} attempt=1
    log_info "Waiting for $label (port $port)..."
    while [ "$attempt" -le "$max" ]; do
        if (echo > /dev/tcp/localhost/"$port") 2>/dev/null; then
            log_ok "$label is up"
            return 0
        fi
        echo "  [$attempt/$max] Not ready yet..."
        sleep 5
        attempt=$((attempt + 1))
    done
    log_err "$label failed to start on port $port"
    return 1
}

# wait_for_http <label> <url> [max_attempts=36]
wait_for_http() {
    local label=$1 url=$2 max=${3:-36} attempt=1
    log_info "Waiting for $label ($url)..."
    while [ "$attempt" -le "$max" ]; do
        if curl -sf "$url" > /dev/null 2>&1; then
            log_ok "$label is up"
            return 0
        fi
        sleep 5
        attempt=$((attempt + 1))
    done
    log_err "$label failed: $url not responding"
    return 1
}
```

- [ ] **Step 4: Create `scripts/lib/registry.sh`**

```bash
#!/bin/bash
# Parse scripts/services.env. Source, don't execute.
# After sourcing services.env, $SERVICES holds an array of "name port grpc tier" strings.
# This file exposes helpers for iterating that array.

REGISTRY_FILE="$REPO_ROOT/scripts/services.env"

# Load $SERVICES from the registry file.
load_registry() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        log_err "scripts/services.env not found"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$REGISTRY_FILE"
}

# svc_field <line> <field_index>  (1-indexed: 1=name, 2=http, 3=grpc, 4=tier)
svc_field() {
    echo "$1" | awk -v i="$2" '{print $i}'
}

# Iterate registry: prints "name http grpc tier" one per line.
svc_list() {
    for line in "${SERVICES[@]}"; do
        echo "$line"
    done
}

# Get the registry line for a single service name. Returns 1 if not found.
svc_get() {
    local name=$1
    for line in "${SERVICES[@]}"; do
        if [ "$(svc_field "$line" 1)" = "$name" ]; then
            echo "$line"
            return 0
        fi
    done
    return 1
}

# Drift guard: warn if any *-service / gateway / eureka-server directory
# exists in the repo root but is not in the registry.
check_drift() {
    local registered drift_found=0
    registered=$(svc_list | awk '{print $1}')
    for dir in "$REPO_ROOT"/*-service "$REPO_ROOT"/gateway "$REPO_ROOT"/eureka-server; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        if ! echo "$registered" | grep -qx "$name"; then
            log_err "Drift: directory '$name' exists but is not in scripts/services.env"
            drift_found=1
        fi
    done
    [ "$drift_found" -eq 0 ]
}
```

- [ ] **Step 5: Verify lib files are syntactically valid**

Run:
```bash
cd /Users/sonanh/Documents/Mangala/microservice-ecommerce
bash -n scripts/lib/colors.sh && \
bash -n scripts/lib/env.sh && \
bash -n scripts/lib/wait.sh && \
bash -n scripts/lib/registry.sh && \
echo "all lib files OK"
```
Expected: `all lib files OK`

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/
git commit -m "refactor(bootstrap): add shared lib (colors, env, wait, registry)"
```

---

## Task 2: Service registry file

**Files:**
- Create: `scripts/services.env`

- [ ] **Step 1: Create `scripts/services.env`**

```bash
# scripts/services.env — single source of truth for service list.
# Format:  name  http_port  grpc_port  tier
#   tier 0 must come up before tier 1, etc. Same-tier services start in parallel.
#   "-" means no port for that field.

SERVICES=(
  "eureka-server         8761  -     0"
  "authorization-server  6666  -     1"
  "gateway               6868  -     1"
  "inventory-service     6969  9090  2"
  "product-service       7777  -     3"
  "order-service         9696  -     3"
  "payment-service       8484  -     3"
  "orchestrator-service  9999  -     3"
  "bff-service           8087  -     3"
)
```

- [ ] **Step 2: Verify the registry loads and parses correctly**

Run:
```bash
cd /Users/sonanh/Documents/Mangala/microservice-ecommerce
bash -c '
source scripts/lib/colors.sh
source scripts/lib/env.sh
source scripts/lib/registry.sh
load_registry
svc_list | awk "{print \$1, \$2}"
'
```
Expected output (9 lines):
```
eureka-server 8761
authorization-server 6666
gateway 6868
inventory-service 6969
product-service 7777
order-service 9696
payment-service 8484
orchestrator-service 9999
bff-service 8087
```

- [ ] **Step 3: Verify drift guard passes (every dir has a registry entry)**

Run:
```bash
bash -c '
source scripts/lib/colors.sh
source scripts/lib/env.sh
source scripts/lib/registry.sh
load_registry
check_drift && echo "no drift"
'
```
Expected: `no drift`

- [ ] **Step 4: Commit**

```bash
git add scripts/services.env
git commit -m "refactor(bootstrap): add scripts/services.env registry"
```

---

## Task 3: Move infrastructure scripts

**Files:**
- Create: `scripts/infra/up.sh`
- Create: `scripts/infra/down.sh`
- Create: `scripts/infra/status.sh`

The existing `start-infrastructure.sh` does three things: load env, bring up docker-compose stacks, run vault init/unseal at the end. We're splitting: vault concerns leave (Task 4), and we get pure infra lifecycle.

- [ ] **Step 1: Create `scripts/infra/up.sh`**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/colors.sh
source "$SCRIPT_DIR/../lib/colors.sh"
# shellcheck source=../lib/env.sh
source "$SCRIPT_DIR/../lib/env.sh"
# shellcheck source=../lib/wait.sh
source "$SCRIPT_DIR/../lib/wait.sh"

load_dotenv

log_info "Bringing up infrastructure..."
cd "$REPO_ROOT"

docker compose -f docker/mysql.yml    up -d
docker compose -f docker/mongodb.yml  up -d
docker compose -f docker/redis.yml    up -d
docker compose -f docker/kafka.yml    up -d
docker compose -f docker/vault.yml    up -d

log_info "Waiting for core services..."
wait_for_port "MySQL master"     3306
wait_for_port "MongoDB"          27017
wait_for_port "Redis"            6379
wait_for_port "Kafka broker"     9092
wait_for_port "Vault"            8200

log_ok "Infrastructure is up"
```

- [ ] **Step 2: Create `scripts/infra/down.sh`**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"

KEEP_VOLUMES=${KEEP_VOLUMES:-1}  # default: preserve volumes

cd "$REPO_ROOT"
log_info "Stopping infrastructure..."

if [ "$KEEP_VOLUMES" = "0" ]; then
    log_warn "Wiping volumes (KEEP_VOLUMES=0)"
    docker compose -f docker/vault.yml    down -v
    docker compose -f docker/kafka.yml    down -v
    docker compose -f docker/redis.yml    down -v
    docker compose -f docker/mongodb.yml  down -v
    docker compose -f docker/mysql.yml    down -v
else
    docker compose -f docker/vault.yml    down
    docker compose -f docker/kafka.yml    down
    docker compose -f docker/redis.yml    down
    docker compose -f docker/mongodb.yml  down
    docker compose -f docker/mysql.yml    down
fi

log_ok "Infrastructure stopped"
```

- [ ] **Step 3: Create `scripts/infra/status.sh`**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"

cd "$REPO_ROOT"
echo "Infrastructure containers:"
docker compose -f docker/mysql.yml -f docker/mongodb.yml -f docker/redis.yml -f docker/kafka.yml -f docker/vault.yml ps
```

- [ ] **Step 4: Make scripts executable + syntax-check**

```bash
chmod +x scripts/infra/*.sh
bash -n scripts/infra/up.sh && bash -n scripts/infra/down.sh && bash -n scripts/infra/status.sh && echo "OK"
```
Expected: `OK`

- [ ] **Step 5: Commit (defer end-to-end test until Makefile exists)**

```bash
git add scripts/infra/
git commit -m "refactor(bootstrap): split infra lifecycle into scripts/infra/"
```

---

## Task 4: Move vault scripts

**Files:**
- Create: `scripts/vault/init.sh`
- Create: `scripts/vault/unseal.sh`
- Create: `scripts/vault/import-secrets.sh`

The existing `init-vault.sh` accepts subcommands (`init`, `unseal`); we split them into separate files so each Make target maps 1:1 to a script. `vault-import-secrets.sh` moves verbatim with one rename.

- [ ] **Step 1: Create `scripts/vault/init.sh` by copying the `init` portion of `init-vault.sh`**

Read the existing file to identify the init logic:
```bash
grep -n "init_vault\|enable_kv\|configure_secrets\|^main\|case " /Users/sonanh/Documents/Mangala/microservice-ecommerce/init-vault.sh
```

Copy `init-vault.sh` to `scripts/vault/init.sh`, then:
1. Strip the `case "$1"` dispatcher at the bottom — this script always inits.
2. Replace the leading color/log block with `source` calls to `scripts/lib/colors.sh` and `scripts/lib/env.sh`.
3. Use `$REPO_ROOT/vault-keys.json` (not relative) for the keys file.

Skeleton:
```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"

VAULT_ADDR="http://localhost:8200"
VAULT_INIT_FILE="$REPO_ROOT/vault-keys.json"

# ... paste init/check/unseal-after-init/enable-kv logic from init-vault.sh ...
# Final exit: vault is initialized AND unsealed AND vault-keys.json exists.
```

- [ ] **Step 2: Create `scripts/vault/unseal.sh` (idempotent — exits 0 if already unsealed)**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"

VAULT_ADDR="http://localhost:8200"
VAULT_INIT_FILE="$REPO_ROOT/vault-keys.json"

if [ ! -f "$VAULT_INIT_FILE" ]; then
    log_err "Vault not initialized — $VAULT_INIT_FILE missing. Run 'make bootstrap' first."
    exit 1
fi

# Quick sealed check
sealed=$(curl -s "$VAULT_ADDR/v1/sys/seal-status" | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null || echo "unknown")

if [ "$sealed" = "False" ]; then
    log_ok "Vault already unsealed"
    exit 0
fi

log_info "Unsealing Vault..."
KEY1=$(python3 -c "import json; print(json.load(open('$VAULT_INIT_FILE'))['unseal_keys_b64'][0])")
KEY2=$(python3 -c "import json; print(json.load(open('$VAULT_INIT_FILE'))['unseal_keys_b64'][1])")
KEY3=$(python3 -c "import json; print(json.load(open('$VAULT_INIT_FILE'))['unseal_keys_b64'][2])")

for KEY in "$KEY1" "$KEY2" "$KEY3"; do
    curl -s -X PUT --data "{\"key\":\"$KEY\"}" "$VAULT_ADDR/v1/sys/unseal" > /dev/null
done

# Re-check
sealed=$(curl -s "$VAULT_ADDR/v1/sys/seal-status" | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])")
if [ "$sealed" = "False" ]; then
    log_ok "Vault unsealed"
else
    log_err "Failed to unseal Vault"
    exit 1
fi
```

- [ ] **Step 3: Create `scripts/vault/import-secrets.sh` from `vault-import-secrets.sh`**

Copy the existing file. Replace the leading color block and env loading with `source` calls to `scripts/lib/`. Use `$REPO_ROOT` for any path references.

- [ ] **Step 4: Make executable + syntax-check**

```bash
chmod +x scripts/vault/*.sh
bash -n scripts/vault/init.sh && bash -n scripts/vault/unseal.sh && bash -n scripts/vault/import-secrets.sh && echo OK
```
Expected: `OK`

- [ ] **Step 5: Live verify `unseal.sh` against running Vault**

If Vault is currently up, run:
```bash
./scripts/vault/unseal.sh
```
Expected: either `✓ Vault already unsealed` or `Unsealing Vault...` followed by `✓ Vault unsealed`.

If Vault is not up, skip this step — full E2E happens in Task 13.

- [ ] **Step 6: Commit**

```bash
git add scripts/vault/
git commit -m "refactor(bootstrap): split vault lifecycle into scripts/vault/"
```

---

## Task 5: Move kafka scripts

**Files:**
- Create: `scripts/kafka/topics.sh`
- Create: `scripts/kafka/mongo-connector.sh`

- [ ] **Step 1: Move topic creation script**

```bash
git mv init-kafka-topics.sh scripts/kafka/topics.sh
```

Then edit `scripts/kafka/topics.sh`:
- Replace inline color block with `source "$SCRIPT_DIR/../lib/colors.sh"`.
- Add `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` at the top.
- Source `scripts/lib/env.sh` and call `load_dotenv`.
- Replace any relative path with `$REPO_ROOT/...`.

- [ ] **Step 2: Move connector install script**

```bash
git mv install-mongodb-kafka-connector.sh scripts/kafka/mongo-connector.sh
```

Edit identically: source lib helpers, use `$REPO_ROOT`, drop the duplicated color block.

- [ ] **Step 3: Make executable + syntax-check**

```bash
chmod +x scripts/kafka/*.sh
bash -n scripts/kafka/topics.sh && bash -n scripts/kafka/mongo-connector.sh && echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add scripts/kafka/
git commit -m "refactor(bootstrap): move kafka scripts to scripts/kafka/"
```

---

## Task 6: Move maven script

**Files:**
- Create: `scripts/maven/install-modules.sh`

- [ ] **Step 1: Move + adjust paths**

```bash
mkdir -p scripts/maven
git mv install-modules.sh scripts/maven/install-modules.sh
```

Edit `scripts/maven/install-modules.sh`:
- Add at top:
  ```bash
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  source "$SCRIPT_DIR/../lib/colors.sh"
  source "$SCRIPT_DIR/../lib/env.sh"
  cd "$REPO_ROOT"
  ```
- Drop the duplicated color block.

- [ ] **Step 2: Syntax check**

```bash
chmod +x scripts/maven/install-modules.sh
bash -n scripts/maven/install-modules.sh && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/maven/
git commit -m "refactor(bootstrap): move install-modules to scripts/maven/"
```

---

## Task 7: Service lifecycle (start/stop/status/logs) driven by registry

**Files:**
- Create: `scripts/services/start.sh`
- Create: `scripts/services/stop.sh`
- Create: `scripts/services/status.sh`
- Create: `scripts/services/logs.sh`
- Delete: `start-services.sh` (after this task verifies)

This task replaces the existing `start-services.sh` with four registry-driven scripts. `bff-service` is automatically picked up because it's in `services.env`.

- [ ] **Step 1: Create `scripts/services/start.sh`**

```bash
#!/bin/bash
# Usage: start.sh           — start all services in tier order
#        start.sh <name>    — start a single service
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"
source "$SCRIPT_DIR/../lib/wait.sh"
source "$SCRIPT_DIR/../lib/registry.sh"

load_dotenv
load_vault_token
export PAYPAL_CLIENT_ID PAYPAL_CLIENT_SECRET PAYPAL_TUNNEL_URL

load_registry
check_drift || { log_err "Fix drift before starting (add missing services to scripts/services.env)"; exit 1; }

LOG_DIR="$REPO_ROOT/logs/services"
PID_DIR="$REPO_ROOT/logs/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

start_one() {
    local name=$1
    local dir="$REPO_ROOT/$name"
    if [ ! -d "$dir" ]; then log_err "Directory not found: $dir"; return 1; fi
    log_info "Starting $name..."
    (cd "$dir" && mvn spring-boot:run) > "$LOG_DIR/$name.log" 2>&1 &
    echo $! > "$PID_DIR/$name.pid"
    log_ok "  Started (PID $!)"
}

start_tier() {
    local tier=$1
    local started=()
    while IFS= read -r line; do
        local t; t=$(svc_field "$line" 4)
        [ "$t" = "$tier" ] || continue
        local name; name=$(svc_field "$line" 1)
        start_one "$name"
        started+=("$line")
    done < <(svc_list)

    # Block until every started service's port(s) are open.
    for line in "${started[@]}"; do
        local name http grpc
        name=$(svc_field "$line" 1)
        http=$(svc_field "$line" 2)
        grpc=$(svc_field "$line" 3)
        [ "$http" != "-" ] && wait_for_port "$name HTTP" "$http"
        [ "$grpc" != "-" ] && wait_for_port "$name gRPC" "$grpc"
    done
}

# --- Single-service mode ---
if [ -n "$1" ] && [ "$1" != "all" ]; then
    line=$(svc_get "$1") || { log_err "Unknown service: $1"; exit 1; }
    start_one "$1"
    http=$(svc_field "$line" 2); grpc=$(svc_field "$line" 3)
    [ "$http" != "-" ] && wait_for_port "$1 HTTP" "$http"
    [ "$grpc" != "-" ] && wait_for_port "$1 gRPC" "$grpc"
    log_ok "🎉 $1 is running"
    exit 0
fi

# --- All-services mode: tiers 0,1,2,3 in order ---
echo "========================================="
echo "  Starting Spring Microservices"
echo "========================================="
for tier in 0 1 2 3; do
    start_tier "$tier"
done

echo ""
echo "========================================="
log_ok "🎉 All services are running"
echo "========================================="
echo ""
echo "Swagger UI:        http://localhost:6868/swagger-ui.html"
echo "Eureka Dashboard:  http://localhost:8761"
echo "Logs:              $LOG_DIR/"
```

- [ ] **Step 2: Create `scripts/services/stop.sh`**

```bash
#!/bin/bash
# Usage: stop.sh           — stop all services
#        stop.sh <name>    — stop a single service
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"
source "$SCRIPT_DIR/../lib/registry.sh"

PID_DIR="$REPO_ROOT/logs/pids"

stop_one() {
    local name=$1
    local pid_file="$PID_DIR/$name.pid"
    if [ ! -f "$pid_file" ]; then log_warn "$name: no PID file"; return 0; fi
    local pid; pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        log_info "Stopping $name (PID $pid)..."
        kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        log_ok "  $name stopped"
    else
        log_warn "$name (PID $pid) was not running"
    fi
    rm -f "$pid_file"
}

if [ -n "$1" ] && [ "$1" != "all" ]; then
    stop_one "$1"
    exit 0
fi

if [ ! -d "$PID_DIR" ]; then log_warn "No PID directory — services may not be running"; exit 0; fi

load_registry
while IFS= read -r line; do
    stop_one "$(svc_field "$line" 1)"
done < <(svc_list)

log_ok "All services stopped"
```

- [ ] **Step 3: Create `scripts/services/status.sh`**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"
source "$SCRIPT_DIR/../lib/registry.sh"

load_registry

echo "========================================="
echo "  Spring Services Status"
echo "========================================="
while IFS= read -r line; do
    name=$(svc_field "$line" 1)
    http=$(svc_field "$line" 2)
    if [ "$http" = "-" ]; then continue; fi
    if (echo > /dev/tcp/localhost/"$http") 2>/dev/null; then
        echo -e "  ${GREEN}● $name (port $http)${NC}"
    else
        echo -e "  ${RED}○ $name (port $http) — not running${NC}"
    fi
done < <(svc_list)
echo ""
```

- [ ] **Step 4: Create `scripts/services/logs.sh`**

```bash
#!/bin/bash
# Usage: logs.sh <name>
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"

if [ -z "$1" ]; then log_err "Usage: logs.sh <service-name>"; exit 1; fi

LOG="$REPO_ROOT/logs/services/$1.log"
if [ ! -f "$LOG" ]; then log_err "Log not found: $LOG"; exit 1; fi

tail -f "$LOG"
```

- [ ] **Step 5: Make executable + syntax-check**

```bash
chmod +x scripts/services/*.sh
for f in scripts/services/*.sh; do bash -n "$f" || exit 1; done
echo OK
```
Expected: `OK`

- [ ] **Step 6: Verify status.sh runs against current state (services likely down)**

Run:
```bash
./scripts/services/status.sh
```
Expected: a 9-line table with `○` markers for any service not running.

- [ ] **Step 7: Delete the old root-level `start-services.sh`**

```bash
git rm start-services.sh
```

- [ ] **Step 8: Commit**

```bash
git add scripts/services/
git commit -m "refactor(bootstrap): registry-driven service lifecycle, drop start-services.sh"
```

---

## Task 8: Mongo seed wiring

**Files:**
- Modify: `docker/mongodb.yml` — add seed file mount
- Create: `scripts/seed/mongo-roles.sh`
- Create: `scripts/seed/mongo-products.sh`

- [ ] **Step 1: Mount seed files into the mongodb container**

Open `docker/mongodb.yml`. Locate the `volumes:` block under `ecommerce-mongodb`:

```yaml
    volumes:
      - ecommerce_data:/data/db
      - ./temp-keyfile.key:/tmp/temp-keyfile.key
```

Replace with:

```yaml
    volumes:
      - ecommerce_data:/data/db
      - ./temp-keyfile.key:/tmp/temp-keyfile.key
      - ./api_role.json:/seed/api_role.json:ro
      - ./product.json:/seed/product.json:ro
```

- [ ] **Step 2: Create `scripts/seed/mongo-roles.sh`**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"

load_dotenv
DB="ecommerce_inventory"
COLLECTION="api_role"
CONTAINER="ecommerce-mongodb"

cd "$REPO_ROOT"

# Idempotency check
count=$(docker compose -f docker/mongodb.yml exec -T "$CONTAINER" \
    mongosh -u "$MONGO_USERNAME" -p "$MONGO_PASSWORD" --authenticationDatabase admin \
    --quiet --eval "db.getSiblingDB('$DB').$COLLECTION.countDocuments({})" 2>/dev/null | tail -1 | tr -d '[:space:]' || echo 0)

if [ "${count:-0}" -gt 0 ]; then
    log_ok "$DB.$COLLECTION already seeded ($count docs); skipping"
    exit 0
fi

log_info "Seeding $DB.$COLLECTION from /seed/api_role.json..."
docker compose -f docker/mongodb.yml exec -T "$CONTAINER" \
    mongoimport --jsonArray \
    --uri "mongodb://$MONGO_USERNAME:$MONGO_PASSWORD@localhost:27017/$DB?authSource=admin" \
    --collection "$COLLECTION" \
    --file /seed/api_role.json

log_ok "Seeded $DB.$COLLECTION"
```

- [ ] **Step 3: Create `scripts/seed/mongo-products.sh`**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"

load_dotenv
DB="ecommerce_inventory"
COLLECTION="product"
CONTAINER="ecommerce-mongodb"

cd "$REPO_ROOT"

count=$(docker compose -f docker/mongodb.yml exec -T "$CONTAINER" \
    mongosh -u "$MONGO_USERNAME" -p "$MONGO_PASSWORD" --authenticationDatabase admin \
    --quiet --eval "db.getSiblingDB('$DB').$COLLECTION.countDocuments({})" 2>/dev/null | tail -1 | tr -d '[:space:]' || echo 0)

if [ "${count:-0}" -gt 0 ]; then
    log_ok "$DB.$COLLECTION already seeded ($count docs); skipping"
    exit 0
fi

log_info "Seeding $DB.$COLLECTION from /seed/product.json..."
docker compose -f docker/mongodb.yml exec -T "$CONTAINER" \
    mongoimport --jsonArray \
    --uri "mongodb://$MONGO_USERNAME:$MONGO_PASSWORD@localhost:27017/$DB?authSource=admin" \
    --collection "$COLLECTION" \
    --file /seed/product.json

log_ok "Seeded $DB.$COLLECTION"
```

- [ ] **Step 4: Make executable + syntax-check**

```bash
mkdir -p scripts/seed
chmod +x scripts/seed/mongo-*.sh
bash -n scripts/seed/mongo-roles.sh && bash -n scripts/seed/mongo-products.sh && echo OK
```
Expected: `OK`

- [ ] **Step 5: Restart mongodb so the new mount takes effect, then live-verify**

```bash
cd /Users/sonanh/Documents/Mangala/microservice-ecommerce
docker compose -f docker/mongodb.yml down
docker compose -f docker/mongodb.yml up -d
sleep 15
./scripts/seed/mongo-roles.sh
./scripts/seed/mongo-products.sh
```
Expected: both either `✓ Seeded ...` (if collections were empty) or `✓ ... already seeded; skipping` (if already populated). Re-run both — both must say "already seeded" the second time.

- [ ] **Step 6: Commit**

```bash
git add docker/mongodb.yml scripts/seed/mongo-roles.sh scripts/seed/mongo-products.sh
git commit -m "feat(bootstrap): wire mongo seed data (api_role, product)"
```

---

## Task 9: MySQL seed

**Files:**
- Create: `scripts/seed/mysql.sh`

- [ ] **Step 1: Create `scripts/seed/mysql.sh`**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"
source "$SCRIPT_DIR/../lib/env.sh"

load_dotenv
DB="ecommerce_dev"
CONTAINER="master"   # service name in docker/mysql.yml

cd "$REPO_ROOT"

# Idempotency check: skip if 'account' table already has rows.
count=$(docker compose -f docker/mysql.yml exec -T "$CONTAINER" \
    mysql -uroot -p"$MYSQL_MASTER_PASSWORD" -N -B -e \
    "SELECT COUNT(*) FROM $DB.account" 2>/dev/null | tail -1 || echo 0)

if [ "${count:-0}" -gt 0 ]; then
    log_ok "MySQL $DB.account already seeded ($count rows); skipping"
    exit 0
fi

log_info "Seeding MySQL $DB from docker/ecommerce.sql..."
docker compose -f docker/mysql.yml exec -T "$CONTAINER" \
    mysql -uroot -p"$MYSQL_MASTER_PASSWORD" "$DB" < docker/ecommerce.sql

log_ok "Seeded MySQL $DB"
```

- [ ] **Step 2: Make executable + syntax-check**

```bash
chmod +x scripts/seed/mysql.sh
bash -n scripts/seed/mysql.sh && echo OK
```
Expected: `OK`

- [ ] **Step 3: Live verify (requires MySQL master running)**

```bash
./scripts/seed/mysql.sh
```
Expected: `✓ Seeded MySQL ecommerce_dev` on first run; `✓ ... already seeded; skipping` on second.

- [ ] **Step 4: Commit**

```bash
git add scripts/seed/mysql.sh
git commit -m "feat(bootstrap): wire mysql seed (ecommerce.sql) idempotently"
```

---

## Task 10: Seed-all wrapper

**Files:**
- Create: `scripts/seed/all.sh`

- [ ] **Step 1: Create `scripts/seed/all.sh`**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/colors.sh"

log_info "Running all seeders..."
"$SCRIPT_DIR/mysql.sh"
"$SCRIPT_DIR/mongo-roles.sh"
"$SCRIPT_DIR/mongo-products.sh"
log_ok "All seeders done"
```

- [ ] **Step 2: Syntax check + run**

```bash
chmod +x scripts/seed/all.sh
bash -n scripts/seed/all.sh && echo OK
./scripts/seed/all.sh
```
Expected: three "skipping" lines (idempotent — Tasks 8 and 9 already seeded).

- [ ] **Step 3: Commit**

```bash
git add scripts/seed/all.sh
git commit -m "feat(bootstrap): seed-all wrapper"
```

---

## Task 11: Makefile

**Files:**
- Create: `Makefile`

- [ ] **Step 1: Create `Makefile` at repo root**

```makefile
# Bootstrap & development entry point.
# Single source of truth: scripts/services.env. Business logic lives in scripts/.

.DEFAULT_GOAL := help
.PHONY: help bootstrap up down nuke restart status \
        infra-up infra-down vault-init vault-unseal vault-import \
        kafka-topics mongo-connector maven-install \
        seed-data seed-mysql seed-mongo \
        svc-start svc-stop svc-restart logs \
        build build-svc

help:
	@echo "make bootstrap       — first-run: bring up infra, init vault, topics, connector, build, seed"
	@echo "make up              — daily: infra up, vault unseal, services start"
	@echo "make down            — services stop, infra stop (volumes preserved)"
	@echo "make nuke            — like 'down' but wipes all docker volumes (DESTROYS DATA)"
	@echo "make restart         — make down && make up"
	@echo "make status          — show service status table"
	@echo ""
	@echo "make svc-start svc=NAME    — start one service"
	@echo "make svc-stop  svc=NAME    — stop one service"
	@echo "make svc-restart svc=NAME"
	@echo "make logs svc=NAME         — tail service log"
	@echo ""
	@echo "make build           — mvn install all modules"
	@echo "make build-svc svc=NAME"
	@echo ""
	@echo "Building blocks (rarely called directly):"
	@echo "  make infra-up infra-down vault-init vault-unseal vault-import"
	@echo "  make kafka-topics mongo-connector maven-install"
	@echo "  make seed-data seed-mysql seed-mongo"

# === Composite targets ===

bootstrap: infra-up vault-init vault-import kafka-topics mongo-connector maven-install seed-data
	@echo ""
	@echo "✓ Bootstrap complete. Now run 'make up' to start services."

up: infra-up vault-unseal svc-start

down: svc-stop infra-down

nuke:
	@echo "⚠️  This will WIPE all Docker volumes (MySQL, Mongo, Kafka, Vault, Redis)."
	@read -p "Type 'yes' to continue: " ok && [ "$$ok" = "yes" ] || (echo "Aborted." && exit 1)
	@$(MAKE) svc-stop
	@KEEP_VOLUMES=0 ./scripts/infra/down.sh

restart: down up

status:
	@./scripts/services/status.sh

# === Building blocks ===

infra-up:
	@./scripts/infra/up.sh

infra-down:
	@./scripts/infra/down.sh

vault-init:
	@./scripts/vault/init.sh

vault-unseal:
	@./scripts/vault/unseal.sh

vault-import:
	@./scripts/vault/import-secrets.sh

kafka-topics:
	@./scripts/kafka/topics.sh

mongo-connector:
	@./scripts/kafka/mongo-connector.sh

maven-install:
	@./scripts/maven/install-modules.sh

seed-data:
	@./scripts/seed/all.sh

seed-mysql:
	@./scripts/seed/mysql.sh

seed-mongo:
	@./scripts/seed/mongo-roles.sh
	@./scripts/seed/mongo-products.sh

# === Service lifecycle ===

svc-start:
ifdef svc
	@./scripts/services/start.sh $(svc)
else
	@./scripts/services/start.sh
endif

svc-stop:
ifdef svc
	@./scripts/services/stop.sh $(svc)
else
	@./scripts/services/stop.sh
endif

svc-restart:
ifndef svc
	$(error svc=NAME required)
endif
	@./scripts/services/stop.sh $(svc)
	@./scripts/services/start.sh $(svc)

logs:
ifndef svc
	$(error svc=NAME required)
endif
	@./scripts/services/logs.sh $(svc)

# === Building ===

build:
	@./scripts/maven/install-modules.sh

build-svc:
ifndef svc
	$(error svc=NAME required)
endif
	@cd $(svc) && mvn clean install
```

- [ ] **Step 2: Verify Makefile parses (no syntax errors)**

```bash
make help
```
Expected: the help output with all targets listed.

- [ ] **Step 3: Verify `make status` works**

```bash
make status
```
Expected: 9-line table.

- [ ] **Step 4: Verify error path — `make logs` without `svc=` errors loudly**

```bash
make logs 2>&1 | head -3
```
Expected: line containing `svc=NAME required`.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "feat(bootstrap): add Makefile entry point"
```

---

## Task 12: Update CLAUDE.md and README

**Files:**
- Modify: `CLAUDE.md` — replace setup section
- Modify: `README.md` — replace setup section

- [ ] **Step 1: Update `CLAUDE.md` "Common Development Commands" section**

Read `CLAUDE.md` and locate the "## Common Development Commands" section (lines roughly 35–80 — read the file first to confirm exact line numbers). Replace the sub-sections "One-Time Setup", "After Docker Restart", "Building and Running Services", "Infrastructure Management", and "Development Workflow" with:

```markdown
### One-Time Setup (First Run)
```bash
cp docker/.env.example docker/.env   # fill in passwords + PayPal credentials
make bootstrap                        # infra → vault → topics → connector → build → seed (5–10 min)
make up                               # start all 9 Spring services
```

### Daily Workflow
```bash
make up                  # bring everything up (auto-unseals Vault)
make status              # see what's running
make logs svc=order-service
make svc-restart svc=bff-service
make down                # stop services + infra (volumes preserved)
```

### Reset to clean state
```bash
make nuke                # WIPES ALL DATA (Docker volumes)
make bootstrap           # re-seed and rebuild
make up
```

### Available targets
Run `make` (or `make help`) for the full list.
```

- [ ] **Step 2: Update `README.md` similarly**

Read `README.md`. It's currently 24 bytes (essentially empty). Add a Quick Start section:

```markdown
# Microservice E-Commerce

Spring Boot microservices backend with Kafka, MySQL master-slave, MongoDB, Redis, Vault, and gRPC. See `CLAUDE.md` for architecture and conventions.

## Quick Start

```bash
cp docker/.env.example docker/.env   # fill in values
make bootstrap                        # one-time: 5–10 minutes
make up                               # start everything
make status                           # check
```

Open http://localhost:6868/swagger-ui.html.

Run `make help` for all targets.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update setup instructions to use make targets"
```

---

## Task 13: End-to-end verification

This task does NOT modify code — it runs the full bootstrap flow and asserts everything works. If anything fails, return to the appropriate task and fix.

- [ ] **Step 1: Cold start from fully clean state**

```bash
cd /Users/sonanh/Documents/Mangala/microservice-ecommerce
make nuke              # type 'yes' when prompted
make bootstrap
```
Expected: each step in `bootstrap` prints `✓` lines. Final line: `✓ Bootstrap complete. Now run 'make up' to start services.` Total time: 5–10 minutes.

- [ ] **Step 2: Start services**

```bash
make up
```
Expected: tier-by-tier startup, ending with `✓ All services are running` and the Swagger / Eureka URLs.

- [ ] **Step 3: Verify status table**

```bash
make status
```
Expected: 9 lines, all green `●`.

- [ ] **Step 4: Verify seed data loaded**

```bash
# Login should succeed for sonanh2001 (password from ecommerce.sql)
# Get a sample product
curl -s http://localhost:6868/product-service/v1/products | head -c 200
```
Expected: a JSON response with `data` containing product entries (e.g. "Uniqlo shirt"). Not 403, not empty.

```bash
# Verify api_role docs exist
docker compose -f docker/mongodb.yml exec -T ecommerce-mongodb mongosh \
  -u ecommerce -p ecommerce_mongo --authenticationDatabase admin --quiet \
  --eval "db.getSiblingDB('ecommerce_inventory').api_role.countDocuments({})"
```
Expected: `32`.

- [ ] **Step 5: Verify Docker-restart recovery (auto-unseal)**

```bash
docker compose -f docker/vault.yml restart
sleep 10
make up
```
Expected: `vault-unseal` runs automatically (you see "Unsealing Vault..." then "✓ Vault unsealed"), services come up green.

- [ ] **Step 6: Verify per-service restart**

```bash
make svc-restart svc=bff-service
make status
```
Expected: only bff-service restarts; other 8 stay up; status shows all 9 green.

- [ ] **Step 7: Verify drift guard**

```bash
mkdir tmp-fake-service
make up 2>&1 | tail -5
```
Expected: error: `Drift: directory 'tmp-fake-service' exists but is not in scripts/services.env`.

```bash
rmdir tmp-fake-service
```

- [ ] **Step 8: Verify seed idempotency**

```bash
make seed-data
```
Expected: three "already seeded; skipping" lines. No errors.

- [ ] **Step 9: Commit any documentation tweaks**

If verification revealed gaps in `CLAUDE.md`/`README.md`, update them and commit:

```bash
git add CLAUDE.md README.md
git commit -m "docs: clarify setup based on E2E verification"
```

If everything passed without changes, no commit here — proceed to Task 14.

---

## Task 14: Delete remaining root-level shims

After E2E verification passes, remove the legacy entry points. They have already been moved (Tasks 3–7). The remaining ones (vault scripts copied not moved, etc.) come out now.

- [ ] **Step 1: Inventory root-level scripts that still exist**

```bash
ls /Users/sonanh/Documents/Mangala/microservice-ecommerce/*.sh 2>/dev/null
```
Expected: only `start-infrastructure.sh`, `init-vault.sh`, `vault-import-secrets.sh`, `vault-login.sh`. (Tasks 5, 6, 7 already removed kafka/maven/services scripts via `git mv` / `git rm`.)

- [ ] **Step 2: Delete them**

```bash
git rm start-infrastructure.sh init-vault.sh vault-import-secrets.sh vault-login.sh
```

- [ ] **Step 3: Final E2E sanity (everything still works)**

```bash
make status
```
Expected: 9 services green.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(bootstrap): remove legacy root-level shell scripts"
```

---

## Self-Review Notes

- Spec coverage:
  - "One command first-run + daily" → Tasks 11 (Makefile), 13 step 1+2 (verification).
  - "services.env single source of truth" → Tasks 1+2.
  - "Vault auto-unseal in `make up`" → Task 4 step 2 + Task 11 (`up` depends on `vault-unseal`).
  - "Three seed datasets land on first run" → Tasks 8, 9, 10, plus `bootstrap` chain in Task 11.
  - "Drift guard" → Task 1 step 4 (`check_drift`) + Task 7 step 1 (called in `start.sh`).
  - "No new runtime tooling" → only `make` and bash; verified.
- Type/name consistency: `svc_field`, `svc_list`, `svc_get`, `check_drift`, `load_registry` — used identically across Task 1, 7. `MONGO_USERNAME`/`MONGO_PASSWORD`/`MYSQL_MASTER_PASSWORD` — match `docker/.env.example`.
- Container service names: `master` (mysql.yml), `ecommerce-mongodb` (mongodb.yml) — confirmed from existing compose files.
- No placeholders / TODOs / "similar to" references.
