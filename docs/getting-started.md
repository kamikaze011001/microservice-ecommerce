# Getting Started

From `git clone` to a fully running stack, then how to drive the daily loop and tear things down. If something here disagrees with `make help`, trust `make help` — it's generated from the Makefile.

For SMTP + PayPal sandbox configuration after the stack is up, see [`local-e2e-setup.md`](./local-e2e-setup.md).
For per-module conventions, see the `CLAUDE.md` at the repo root and inside each service/module.

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Docker + Docker Compose | recent | infra runs in containers |
| Java | **17** (Temurin recommended) | Spring Boot 3.3.6 |
| Maven | **3.9+** | core modules build first |
| Node | **20+** | frontend |
| pnpm | **9+** | frontend package manager |
| `bash` | 4+ | macOS users — install via Homebrew if needed |
| Free ports | see [Ports](#ports) | bootstrap fails fast on conflicts |

`make` is required and assumed throughout. Every entrypoint goes through it.

---

## 1. First-time bootstrap

One-time, idempotent. Re-running is safe.

```bash
git clone <repo-url> microservice-ecommerce
cd microservice-ecommerce

# 1. Configure environment
cp docker/.env.example docker/.env
$EDITOR docker/.env        # fill MySQL / Redis / Mongo / PayPal values
                           # leave VAULT_TOKEN empty — it's set during init

# 2. Bootstrap everything: infra → vault → kafka → maven → seed
make bootstrap

# 3. Start the JVM services
make up

# 4. Sanity check
make status                # all 9 services should show "● running"
```

`make bootstrap` runs in this order (see Makefile L41):
1. **`infra-up`** — Docker compose: MySQL master+2 slaves, Redis, Mongo, Kafka, Schema Registry, Vault, MinIO
2. **`vault-init`** — initialize Vault, write keys to `vault-keys.json`
3. **`vault-unseal`** — unseal Vault using the keys
4. **`vault-import`** — load app secrets from `docker/secrets/*.json` into Vault
5. **`kafka-topics`** — create topics
6. **`mongo-connector`** — register the Debezium MongoDB → Kafka CDC connector (drives the saga)
7. **`build`** — `mvn install` core modules then services in correct order
8. **`seed-data`** — seed MySQL (`ecommerce_dev`) + Mongo collections (`api_role`, `product`)

If bootstrap fails partway through, fix the underlying cause and re-run — each step is idempotent.

> **Don't lose `vault-keys.json`.** It's gitignored and contains the unseal keys + root token. Without it, your local data in Vault is effectively gone. `make nuke` deletes it on purpose.

### What `make up` does (Makefile L45)
1. `infra-up` — starts containers if they aren't running
2. `vault-unseal` — Docker restarts re-seal Vault, this fixes that automatically
3. `mongo-connector-ensure` — re-registers the CDC connector if Kafka Connect lost it
4. `svc-start` — boots the 9 JVM services in tier order

The tier order is enforced from `scripts/services.list`:
- **Tier 0** — eureka-server (everyone needs the registry)
- **Tier 1** — authorization-server, gateway
- **Tier 2** — inventory-service (waits until BOTH HTTP `:6969` and gRPC `:9090` are listening)
- **Tier 3** — product, order, payment, orchestrator, bff (start in parallel)

---

## 2. Daily loop

```bash
make up        # start everything (auto-unseals vault)
make down      # stop services + infra (preserves all data)
make restart   # equivalent to: make down && make up
make status    # health table for every service + infra container
```

`make down` keeps Docker volumes intact — your DBs, Mongo collections, MinIO buckets, and Vault data persist across restarts.

After laptop reboot or Docker restart, `make up` is all you need. Vault re-seals on container restart; the `up` target unseals it before services try to read secrets.

---

## 3. Per-service operations

Run individual services without touching the rest of the stack:

```bash
make svc-start   svc=order-service
make svc-stop    svc=order-service
make svc-restart svc=order-service
make logs        svc=order-service     # tail logs/<service>.log
```

Useful loop after editing a service:

```bash
cd order-service && mvn -q compile      # or: mvn -q -DskipTests install
make svc-restart svc=order-service
make logs svc=order-service
```

Service ports are listed in [`Ports`](#ports). Build artifacts and per-service logs live under `logs/`.

---

## 4. Adding a new service

1. Add the service directory under repo root.
2. Register it in `scripts/services.list`:
   ```
   my-service  PORT  GRPC_PORT_OR_-  TIER
   ```
3. The drift guard in `scripts/services/start.sh` refuses to start until every `*-service` / `gateway` / `eureka-server` directory is registered, so this step is enforced.
4. Add a `CLAUDE.md` to the new directory describing what's non-obvious.

---

## 5. Shutdown options

| When you want to… | Command | What it touches |
|---|---|---|
| Stop for the day | `make down` | Stops services + containers; **keeps volumes** |
| Stop just one service | `make svc-stop svc=NAME` | One JVM only; infra untouched |
| Restart everything | `make restart` | `down` then `up` |
| Wipe DBs + start fresh | `make nuke` | **Deletes all volumes**, prompts y/N first |

### `make nuke` (destructive)

Stops everything and **deletes Docker volumes** for MySQL master + slaves, Redis, Mongo, Kafka, Vault, MinIO. Also removes `vault-keys.json`. Asks for confirmation before running.

Use when:
- Schemas drifted and you want a clean slate
- A migration is half-applied
- You want to test bootstrap from scratch

After `make nuke`, you must run `make bootstrap` again before `make up`.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Service crashes with "vault sealed" | Vault re-sealed after Docker restart | `make up` (it auto-unseals); or `make vault-unseal` directly |
| `make up` fails with "port already in use" | Another stack / leftover process bound the port | `lsof -iTCP:PORT -sTCP:LISTEN` to find owner; kill or rebind |
| Service starts then exits with `Failed to load ApplicationContext` | Vault returned no secrets for that service | `make vault-import` — re-loads `docker/secrets/*.json` |
| inventory-service "stuck starting" | gRPC port `:9090` not yet bound | Wait — order-service correctly blocks until both ports are up |
| Cart shows "0 available" right after bootstrap | inventory tables not seeded | `make seed-data` (or `make seed-mysql`); see `memory/project_inventory_seed.md` |
| Saga not firing on order create | Mongo CDC connector unregistered | `make mongo-connector-ensure` (also runs in `make up`) |
| `make build` fails with "package … does not exist" | Core modules not installed before services | `make build` always installs core modules first; if it still fails, run `mvn -pl core/<module> install` manually |
| Maven build slow / inconsistent | `~/.m2` cache contains stale local artifacts | `mvn -q -U clean install` to force-update |
| Frontend can't reach API | Gateway not running, or wrong base URL | `make status` (gateway should be on `:6868` per services.list, exposed externally as `:8080`); check `frontend/.env` if present |
| GitHub blocks push due to secret scan | A token leaked into a commit | Don't use the bypass URL — rewrite history with `git rebase` to remove the literal value, then push |

---

## Ports

From `scripts/services.list` (canonical) and infra compose files:

### Application services
| Service | HTTP | gRPC |
|---|---|---|
| eureka-server | 8761 | — |
| authorization-server | 6666 | — |
| gateway | 6868 (ext :8080) | — |
| inventory-service | 6969 | 9090 |
| product-service | 7777 | — |
| order-service | 9696 | — |
| payment-service | 8484 | — |
| orchestrator-service | 9999 | — |
| bff-service | 8087 | — |

### Infrastructure
| Component | Port |
|---|---|
| MySQL master | 3306 |
| MySQL slave 1 / 2 | 3307 / 3308 |
| Redis | 6379 |
| MongoDB | 27017 |
| Kafka | 9092 |
| Schema Registry | 8081 |
| Kafka Connect REST | 8093 |
| Vault | 8200 |
| MinIO API / Console | 9000 / 9001 |
| Eureka Dashboard | 8761 |

Each JVM service also exposes Spring Boot Actuator on `:9091` internally — **not** routed through the gateway. Locally only one service can bind it (smoke-test one service at a time, or assign distinct management ports per service).

---

## Reference

| Command | Where |
|---|---|
| Full Makefile listing | `make help` |
| Architecture overview | root `CLAUDE.md` |
| Per-module conventions | `<module>/CLAUDE.md` |
| SMTP + PayPal sandbox config | [`docs/local-e2e-setup.md`](./local-e2e-setup.md) |
| Service registry (ports + tier) | `scripts/services.list` |
| Vault secrets (local) | `vault-keys.json` (gitignored) |
| Per-service logs | `logs/<service>.log` |
| Pidfiles | `logs/<service>.pid` |
