# microservice-ecommerce

Microservice e-commerce platform — Spring Boot 3.3.6 / Java 17, master-slave MySQL, Mongo, Kafka, Vault, gRPC, Vue 3 SPA.

## Quick start

```bash
cp docker/.env.example docker/.env  # fill values
make bootstrap                       # first-run only
make up                              # start everything
make status                          # health table
```

Stop with `make down`. Wipe and start fresh with `make nuke`.

## Docs

- **[`docs/getting-started.md`](docs/getting-started.md)** — bootstrap, daily lifecycle, per-service ops, troubleshooting, ports.
- **[`docs/local-e2e-setup.md`](docs/local-e2e-setup.md)** — Gmail SMTP + PayPal sandbox config for end-to-end flows.
- **[`CLAUDE.md`](CLAUDE.md)** — architecture overview and codebase conventions (also auto-loaded by Claude Code).
- Per-module CLAUDE.md files inside each `*-service/` and `core/*/` directory describe module-specific gotchas.

## Architecture at a glance

- **9 JVM services** behind a single API gateway on `:8080` — eureka, auth, gateway, inventory, product, order, payment, orchestrator, bff.
- **Master-slave MySQL** with package-level routing (`repository/master/` writes, `repository/slave/` reads).
- **Mongo + Debezium CDC → Kafka** drives the order saga via the orchestrator.
- **Vault** holds every service's secrets; sealed Vault → services crash on boot. `make up` auto-unseals.
- **Frontend** is a Vue 3 + Vite SPA in `frontend/`, hits the gateway directly.

See [`CLAUDE.md`](CLAUDE.md) for the full picture.

## Service ports (canonical = `scripts/services.list`)

| Service | HTTP | gRPC |
|---|---|---|
| eureka-server | 8761 | — |
| authorization-server | 6666 | — |
| gateway | 6868 (ext 8080) | — |
| inventory-service | 6969 | 9090 |
| product-service | 7777 | — |
| order-service | 9696 | — |
| payment-service | 8484 | — |
| orchestrator-service | 9999 | — |
| bff-service | 8087 | — |

For everything else, run `make help`.
