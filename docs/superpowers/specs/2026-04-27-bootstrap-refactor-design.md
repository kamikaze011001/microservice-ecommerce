# Bootstrap Refactor — Design

**Status:** Approved
**Date:** 2026-04-27
**Scope:** Replace the 8 root-level shell scripts (~2,000 LOC) with a `Makefile` + restructured `scripts/` tree, add a single source of truth for the service list, wire up first-run seed data that today sits unused on disk, and make Vault auto-unseal on every `make up`.

---

## Problem

A fresh clone today requires six manual steps in a specific order: `cp .env.example`, `start-infrastructure.sh`, `init-vault.sh`, `init-kafka-topics.sh`, `install-mongodb-kafka-connector.sh`, `install-modules.sh`, then `start-services.sh`. After every Docker restart, Vault re-seals and services crash on boot until the dev remembers to run `init-vault.sh unseal`.

Three concrete problems:

1. **No single entry point.** Six scripts, executed in order, with names that don't make the order obvious.
2. **Drift in the service list.** `start-services.sh` hardcodes the service map twice (in `start_all` and `status_all`) and is *already* missing `bff-service`. Adding a new service today is a multi-file edit waiting to silently break.
3. **Init data on disk but unwired.** Three seed datasets exist (`docker/ecommerce.sql`, `docker/api_role.json`, `docker/product.json`) and none of them auto-load. On a fresh clone: no login works (no users), every gateway route 403s (no `api_role` docs), product catalog is empty.

## Goals

- One command for first-run (`make bootstrap`) and one for daily startup (`make up`).
- A flat `scripts/services.env` registry that's the only place the service list lives.
- Vault auto-unseals on `make up`. Re-running anything is idempotent.
- All three seed datasets land in their target databases on first run.
- No new runtime tooling required (no `task`, `just`, etc.) — only `make`, which devs already have.

## Non-Goals

- Containerizing the Java services (separate decision; deferred).
- Replacing Vault, Kafka, or Eureka. Topology stays exactly as-is.
- Changing application code. This is purely a developer-experience / bootstrap refactor.
- Production deployment scripts. This document covers local dev only.

---

## Architecture

### Repo layout

```
microservice-ecommerce/
├── Makefile                          ← single entry point for ALL dev tasks
├── scripts/
│   ├── lib/
│   │   ├── colors.sh                 ← shared color/log helpers (deduped from 8 scripts)
│   │   ├── wait.sh                   ← wait_for_port, wait_for_http
│   │   └── env.sh                    ← load_env (docker/.env + vault-keys.json)
│   ├── services.env                  ← SOURCE OF TRUTH: one line per service
│   ├── infra/
│   │   ├── up.sh                     ← docker compose up (was start-infrastructure.sh)
│   │   ├── down.sh
│   │   └── status.sh
│   ├── vault/
│   │   ├── init.sh                   ← first-run init + key save (was init-vault.sh init)
│   │   ├── unseal.sh                 ← idempotent unseal (was init-vault.sh unseal)
│   │   └── import-secrets.sh         ← was vault-import-secrets.sh
│   ├── kafka/
│   │   ├── topics.sh                 ← was init-kafka-topics.sh
│   │   └── mongo-connector.sh        ← was install-mongodb-kafka-connector.sh
│   ├── maven/
│   │   └── install-modules.sh        ← was install-modules.sh (unchanged)
│   ├── seed/
│   │   ├── all.sh                    ← runs mysql + mongo seeders idempotently
│   │   ├── mysql.sh                  ← imports docker/ecommerce.sql
│   │   ├── mongo-roles.sh            ← imports docker/api_role.json
│   │   └── mongo-products.sh         ← imports docker/product.json
│   └── services/
│       ├── start.sh                  ← reads services.env, supports start.sh [name|all]
│       ├── stop.sh
│       ├── status.sh
│       └── logs.sh                   ← tails $LOG_DIR/<name>.log
└── docs/superpowers/specs/2026-04-27-bootstrap-refactor-design.md
```

### Invariants

- The 8 root-level scripts move under `scripts/` and shed duplication via `scripts/lib/`.
- `scripts/services.env` is the only place the service list lives.
- Make targets are thin wrappers over `scripts/*` — the `Makefile` holds *no* business logic.
- Logs and PIDs continue to live in `logs/services/` and `logs/pids/` (unchanged).

---

## Components

### 1. Service registry (`scripts/services.env`)

Plain bash-sourceable file:

```bash
# scripts/services.env — name http_port grpc_port tier
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

**Tiers** define start order. Within a tier, services start in parallel and the runner blocks on the union of their ports before moving on. Adding a new service is a one-line change.

### 2. Make target API

```
# === First-run (slow, idempotent, run once) ===
make bootstrap            → infra-up → vault-init → vault-import → kafka-topics
                            → mongo-connector → maven-install → seed-data

# === Daily loop ===
make up                   → infra-up → vault-unseal → svc-start  (the 30-second path)
make down                 → svc-stop → infra-down                (preserves volumes)
make nuke                 → svc-stop → infra-down -v             (wipes data; warns first)
make restart              → make down && make up

# === Granular ===
make svc-start svc=NAME   → start one service (registers from services.env)
make svc-stop svc=NAME
make svc-restart svc=NAME
make logs svc=NAME        → tail -f logs/services/<name>.log
make status               → table of every service: ● running | ○ down

# === Building ===
make build                → mvn install across all modules in dependency order
make build-svc svc=NAME

# === Bootstrap building blocks (rarely called directly) ===
make infra-up / infra-down / vault-unseal / vault-init
make kafka-topics / mongo-connector / seed-data / seed-mongo / seed-mysql
```

### 3. Seed data wiring

Three datasets land in their final homes on `make bootstrap`. All three live under `scripts/seed/` with idempotent guards.

| File | Target | Idempotency check |
|---|---|---|
| `docker/ecommerce.sql` | MySQL master, DB `ecommerce_dev` (tables `account`, `account_role`, `role`, `user`) | Skip if `SELECT COUNT(*) FROM account > 0` |
| `docker/api_role.json` | MongoDB `ecommerce_inventory.api_role` (gateway permission rules — `gateway/.../entity/ApiRole.java` declares `@Document(value = "api_role")`) | Skip if `db.api_role.countDocuments() > 0` |
| `docker/product.json` | MongoDB `ecommerce_inventory.product` (sample products — `product-service/.../entity/Product.java` uses default `@Document`) | Skip if `db.product.countDocuments() > 0` |

**Mechanism:**
- `mysql.sh`: `docker compose exec -T mysql-master mysql -uroot -p... ecommerce_dev < docker/ecommerce.sql`
- `mongo-roles.sh`: `docker compose exec -T mongodb mongoimport --jsonArray --db ecommerce_inventory --collection api_role --file /seed/api_role.json`
- `mongo-products.sh`: same with `--collection product` and `product.json`

**One `docker/mongodb.yml` change required:** mount `./docker/api_role.json` and `./docker/product.json` into the mongodb container at `/seed/` so `mongoimport` can read them in-container. Single-line volume addition.

**Lifecycle:** seed runs as the last step of `make bootstrap`. It does NOT run on `make up` — that path assumes data is already seeded. If volumes are wiped (`make nuke`), the next `make bootstrap` re-seeds cleanly.

### 4. Vault auto-unseal on `make up`

Vault re-seals on every Docker restart. `make up` always runs `scripts/vault/unseal.sh` before starting services. The script reads unseal keys from `vault-keys.json` (already on disk, already gitignored — no expansion of trust boundary), posts the unseal call, exits 0 if Vault is already unsealed.

If `vault-keys.json` is missing, `unseal.sh` exits with: `"Vault not initialized — run 'make bootstrap' first."` This is the new-dev guidance path.

### 5. Drift guard

At the top of `scripts/services/start.sh`: list all `*-service` directories plus `gateway` and `eureka-server`. Diff against `services.env`. If any are missing from the registry, abort with a loud warning naming them. This catches the `bff-service`-shaped bug at edit time, not three weeks later when staging breaks.

---

## Failure modes

| Symptom | Detection | Recovery |
|---|---|---|
| Vault sealed after Docker restart | `make up` always runs `vault-unseal` first | Auto-recovered |
| `vault-keys.json` missing | `vault-unseal` exits with friendly error | `make bootstrap` |
| Service won't start (port stuck) | `wait_for_port` times out at 3 min; runner prints `tail -50 logs/services/<name>.log` | `make logs svc=…` |
| Kafka topic missing for new service | Runtime error in service log | `make kafka-topics` (idempotent) |
| Mongo seed already imported | Seeders detect non-empty collection, log "already seeded, skipping" | None |
| New service not in `services.env` | Drift guard in `start.sh` aborts at start time | Add the line to `services.env` |
| MySQL seed conflicts (re-import after manual writes) | Skip-if-non-empty guard | `make nuke && make bootstrap` to reset |

---

## Test plan

This refactor has no new test suites — its correctness is verified by running it end-to-end:

1. **Cold start.** `make nuke && make bootstrap && make up` from a clean state. Expect: 8 services running, login works with `sonanh2001`, `GET /product-service/v1/products` returns ~10 sample products, gateway permission rules enforced (anonymous request to `/order-service/v1/orders` returns 401).
2. **Docker restart recovery.** `docker compose down && make up`. Expect: Vault auto-unseals, all services come up green within 3 minutes.
3. **Per-service restart.** `make svc-restart svc=bff-service`. Expect: only bff-service restarts; others untouched; `make status` reflects this.
4. **Status accuracy.** Run `make status` between every step above. Expect: table matches actual state.
5. **Seed idempotency.** Run `make seed-data` twice in a row. Expect: second run prints "already seeded, skipping" for all three; no errors, no duplicate rows.
6. **Drift guard.** Add a phantom `*-service` directory, run `make svc-start svc=all`. Expect: loud abort naming the missing entry.

---

## Migration

The 8 root-level scripts and their existing flags continue to work during the transition (they are *moved*, not deleted, on a single commit). The README and `CLAUDE.md` update in the same commit to point at `make` targets. After one stable week, the old root-level entry points become thin shims that print `"deprecated, use make <target>"` and call through.

## Out of scope (deferred)

- Dockerizing Java services for local dev (see Goals → Non-Goals).
- CI integration of these targets (CI doesn't currently bootstrap a full stack).
- Replacing Vault with a simpler secret store for local dev.
