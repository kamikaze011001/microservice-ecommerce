# Backend Stabilization — Design Spec

**Date:** 2026-05-02
**Goal:** Restore the local-dev backend to a known-good state so Phase 3 frontend E2E can run against real auth, register, and login flows.

## Problem

Phase 3 frontend verification is blocked by backend instability:

1. **MySQL replication is broken.** Slaves report `Replica_IO_Running: No` and "Replica failed to initialize applier metadata structure from the repository". Slaves contain no databases, so the read-write routing layer (`core-routing-db`) sends reads to empty slaves. Symptom: `Table 'ecommerce_dev.user' doesn't exist` on register, which surfaces as a 401 because Spring Boot dispatches the SQLException to `/error` and Spring Security rejects the secondary request.
2. **Five local-dev fixes are uncommitted.** They were applied during ad-hoc debugging and are at risk if any reset goes sideways:
   - Vault seed key rename `jdbc-url` → `url` (Atomikos `MysqlXADataSource` binds `url`).
   - Auth-server `application.yml`: explicit comma-separated `vault://` import for `ecommerce`/`authorization-server`/`core-s3` (the empty `optional:vault://` form does not honor `additional-contexts`); management port reassigned to 19091.
   - Gateway `application.yml`: management port reassigned to 19093 (port 9091 already held by eureka in single-host dev).
   - Auth-server `SecurityConfiguration.java`: literal colon endpoints (`/v1/auth:register`, etc.) added to `permitAll`. Turned out to be unrelated to the 401 root cause but is still correct and stays.
   - `frontend/src/api/schema.d.ts`: regenerated against a running gateway. Will be regenerated after the reset.

## Scope

**In scope:** MySQL reset only (Mid). Slave URLs in Vault repointed at master:3306 (single-DB dev — keeps the read-write routing code path exercised without depending on real replication). All other infra (Vault, Mongo, Kafka, MinIO, Redis) preserved. Service restart in tier order. Verification gate before frontend E2E.

**Out of scope:** Production replication topology (untouched — production Vault keeps real slave URLs). The unrelated `kafka-connect` unhealthy state. The `frontend/src/api/schema.d.ts` regen (handled after backend is green).

## Approach

Linear, idempotent, recoverable. Commit local fixes FIRST so nothing is lost if a later step fails.

### 1. Pre-flight — capture local fixes

Branch: `chore/local-dev-stabilization`.

Two changes folded into the seed file:
- Rename `spring.datasource.{master,slave1,slave2}.jdbc-url` → `url`.
- Repoint `slave1.url` and `slave2.url` at `localhost:3306` (master). Comment in the file explains this is local-dev only.

Commit each file with a focused message. The frontend schema is left out of this commit — it gets regenerated post-reset.

### 2. MySQL reset (Mid)

```
make svc-stop                                  # stops any running JVMs
docker compose -f docker/docker-compose-mysql.yml down -v   # MySQL volumes only
docker compose -f docker/docker-compose-mysql.yml up -d     # triggers init-mysql.sh
```

Wait until `mysql-master`, `mysql-slave1`, `mysql-slave2` all report `(healthy)`. The init script runs replication setup automatically. Even though we are now pointing app reads at master, leaving real replication healthy is harmless and matches the production topology.

Re-seed master with `make seed-mysql`. With slaves URL'd at master, all reads land on master where the seed lives.

### 3. Vault refresh

```
make vault-import   # re-imports secret/ecommerce with the new url keys + slave→master URLs
```

Vault is already unsealed; no init/unseal step. Verify with `vault kv get secret/ecommerce | grep slave1.url` — should show `:3306`.

### 4. Service start

```
make svc-start
```

Tier order (per `scripts/services.list`): eureka → auth + gateway → inventory → product/order/payment/orchestrator/bff. The drift guard validates the registry. Auth-server's Hibernate `ddl-auto: update` validates schema on first connect; it does not need to recreate tables since the seed already loaded them.

### 5. Verification gate

The backend is "ready for Phase 3 E2E" when all of the following pass:

- [ ] 8 PIDs alive in `logs/pids/`
- [ ] `make status` reports healthy across the board
- [ ] `mysql-master` shows the 4 tables (`account`, `account_role`, `role`, `user`); both slaves identical (since they replicate from master, even though apps don't read from them in dev)
- [ ] `Replica_IO_Running: Yes` AND `Replica_SQL_Running: Yes` on both slaves
- [ ] `vault kv get secret/ecommerce` shows 33 keys with `slave1.url` pointing at `:3306`
- [ ] Mongo `api_role` collection contains 31 docs
- [ ] `GET http://localhost:6868/authorization-server/.well-known/jwks.json` → 200 with RSA key
- [ ] `POST /authorization-server/v1/auth:register` with a fresh user → 2xx with `{accessToken, refreshToken}` (the canary — this is the symptom that triggered the whole stabilization)
- [ ] `POST /authorization-server/v1/auth:login` with that user → 200
- [ ] `GET http://localhost:6868/v3/api-docs` → aggregated swagger JSON

Once all green, regenerate `frontend/src/api/schema.d.ts` and resume Phase 3 Task 14 (live E2E).

## Failure modes & rollback

- **MySQL volumes won't remove** (in use): `docker compose down` first, then `docker volume rm`. If still stuck, `docker volume rm -f`.
- **Replication fails to come up**: this is non-blocking for dev (apps point at master). File a ticket; do not block frontend work.
- **Seed fails on master**: `mysql-master` may not be ready yet — wait for healthcheck, retry `make seed-mysql`.
- **Service won't start**: check Atomikos lock files in `authorization-server/tmlog*.log` and `*.epoch`; remove if a previous JVM left them behind.

## Definition of Done

- All five local fixes committed on `chore/local-dev-stabilization`.
- Verification checklist green.
- `frontend/src/api/schema.d.ts` regenerated against the live gateway and committed.
- Phase 3 Task 14 (live E2E) unblocked.
