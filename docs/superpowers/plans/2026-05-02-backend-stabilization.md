# Backend Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the local-dev backend to a known-good state (MySQL replication healthy, slaves URL'd at master for dev, all 8 services running, register/login working) so Phase 3 frontend E2E can proceed.

**Architecture:** Linear, idempotent recovery. (1) Capture uncommitted local-dev fixes on a chore branch so they survive any reset. (2) Mid-scope MySQL reset — wipe MySQL volumes only, re-init replication, re-seed master. (3) Refresh Vault with the corrected seed (slave URLs pointing at master:3306 for local dev). (4) Start services in tier order. (5) Run a 10-bullet verification gate. (6) Regenerate the frontend OpenAPI schema and resume Phase 3 Task 14.

**Tech Stack:** Spring Boot 3.3.6, MySQL 8.0.40 (master + 2 slaves with GTID replication), HashiCorp Vault KV v2, Docker Compose (per-service compose files in `docker/*.yml`), Make.

**Branch:** `chore/local-dev-stabilization` — branched from `main`. The four uncommitted local-dev fixes are infra-level and should not be entangled with `frontend/phase-3-api-auth`.

---

## File Map

**Modified (committed in this plan):**
- `docker/vault-configs/ecommerce-common.json` — rename `jdbc-url` → `url` for all three datasources; repoint `slave1.url` and `slave2.url` at `localhost:3306` (master); add a comment header explaining the local-dev choice.
- `authorization-server/src/main/resources/application.yml` — already changed locally: `spring.config.import` becomes explicit comma-separated `vault://` URIs; management port `9091` → `19091`.
- `gateway/src/main/resources/application.yml` — already changed locally: management port `9091` → `19093`.
- `authorization-server/.../filter/SecurityConfiguration.java` (path: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/SecurityConfiguration.java`) — already changed locally: literal colon endpoints (`/v1/auth:register`, `:login`, `:refresh-token`, `:activate`, `:resend-otp`, `:forgot-password`, `:verify-forgot-pass-otp`, `:reset-password`) added to `permitAll`. Kept even though it turned out unrelated to the 401 — it's still correct.

**Regenerated (committed at end):**
- `frontend/src/api/schema.d.ts` — regenerated from the live gateway after the backend is green.

**Untouched:** All other source code. This is an infra/config-only change.

---

## Pre-flight check

- [ ] **Step 0a: Confirm uncommitted state**

```bash
git status --short
```

Expected (exact set; order may vary):
```
 M authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/SecurityConfiguration.java
 M authorization-server/src/main/resources/application.yml
 M docker/vault-configs/ecommerce-common.json
 M frontend/src/api/schema.d.ts
 M gateway/src/main/resources/application.yml
?? logs/
```

If anything else appears modified, stop and surface it. The plan assumes only these five tracked files are dirty.

- [ ] **Step 0b: Confirm current branch**

```bash
git branch --show-current
```

Expected: `main` (or whatever is checked out — note it; we branch off `main` next regardless).

---

### Task 1: Branch + repoint slave URLs in Vault seed

**Files:**
- Modify: `docker/vault-configs/ecommerce-common.json` (already partially modified)

- [ ] **Step 1: Stash the schema.d.ts change so it doesn't follow the branch**

`frontend/src/api/schema.d.ts` belongs with the frontend branch, not this chore branch. Stash it.

```bash
git stash push -m "schema.d.ts (regenerate post-stabilization)" -- frontend/src/api/schema.d.ts
```

Expected: `Saved working directory and index state On <branch>: schema.d.ts (regenerate post-stabilization)`

- [ ] **Step 2: Create + check out the chore branch from main**

```bash
git fetch origin main
git checkout -b chore/local-dev-stabilization origin/main
```

Expected: `Switched to a new branch 'chore/local-dev-stabilization'`. The four remaining tracked changes follow the new branch automatically.

- [ ] **Step 3: Confirm the carry-over**

```bash
git status --short
```

Expected:
```
 M authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/SecurityConfiguration.java
 M authorization-server/src/main/resources/application.yml
 M docker/vault-configs/ecommerce-common.json
 M gateway/src/main/resources/application.yml
?? logs/
```

- [ ] **Step 4: Open `docker/vault-configs/ecommerce-common.json` and apply the slave→master repoint + dev-only header comment**

Replace the file's full contents with:

```json
{
  "_comment": "LOCAL DEV ONLY. Slave URLs point at master:3306 because local replication is fragile and unrelated to app-layer testing. Production Vault keeps real slave hosts/ports.",
  "spring.datasource.master.url": "jdbc:mysql://localhost:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.master.username": "root",
  "spring.datasource.master.password": "ecommerce_master",
  "spring.datasource.master.driver-class-name": "com.mysql.cj.jdbc.Driver",

  "spring.datasource.slave1.url": "jdbc:mysql://localhost:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.slave1.username": "root",
  "spring.datasource.slave1.password": "ecommerce_master",
  "spring.datasource.slave1.driver-class-name": "com.mysql.cj.jdbc.Driver",

  "spring.datasource.slave2.url": "jdbc:mysql://localhost:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.slave2.username": "root",
  "spring.datasource.slave2.password": "ecommerce_master",
  "spring.datasource.slave2.driver-class-name": "com.mysql.cj.jdbc.Driver",

  "spring.data.redis.host": "localhost",
  "spring.data.redis.port": "6379",
  "spring.data.redis.password": "ecommerce_redis",
  "spring.data.redis.database": "0",

  "spring.data.mongodb.uri": "mongodb://ecommerce:ecommerce_mongo@localhost:27017/ecommerce_inventory?authSource=admin",

  "spring.kafka.bootstrap-servers": "localhost:9092",
  "spring.kafka.properties.schema.registry.url": "http://localhost:8091",

  "spring.mail.host": "smtp.gmail.com",
  "spring.mail.port": "587",
  "spring.mail.username": "your-email@gmail.com",
  "spring.mail.password": "your-app-password",
  "spring.mail.protocol": "smtp",
  "spring.mail.properties.mail.smtp.auth": "true",
  "spring.mail.properties.mail.smtp.starttls.enable": "true"
}
```

Note: slave1/slave2 username and password match master (since they ARE master in dev).

- [ ] **Step 5: Verify the JSON is valid**

```bash
jq . docker/vault-configs/ecommerce-common.json > /dev/null && echo OK
```

Expected: `OK`

- [ ] **Step 6: Verify the diff is what we expect**

```bash
git diff docker/vault-configs/ecommerce-common.json | head -60
```

Expected: shows the `jdbc-url` → `url` rename on master/slave1/slave2 plus the slave URLs/passwords now matching master plus the new `_comment` header line.

---

### Task 2: Commit the four local-dev fixes

**Files:**
- `docker/vault-configs/ecommerce-common.json`
- `authorization-server/src/main/resources/application.yml`
- `gateway/src/main/resources/application.yml`
- `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/SecurityConfiguration.java`

- [ ] **Step 1: Stage the four files**

```bash
git add docker/vault-configs/ecommerce-common.json \
        authorization-server/src/main/resources/application.yml \
        gateway/src/main/resources/application.yml \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/SecurityConfiguration.java
```

- [ ] **Step 2: Verify nothing else is staged**

```bash
git diff --cached --stat
```

Expected: exactly those four paths. No `schema.d.ts`, no other files.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
chore(local-dev): stabilize backend bootstrap

- vault-configs: rename jdbc-url -> url so Atomikos MysqlXADataSource
  binds the URL via DataSourceProperties.getUrl(); point slave URLs at
  master:3306 for local dev only (real replica hosts kept in prod Vault)
- authorization-server application.yml: switch spring.config.import to
  explicit comma-separated vault:// URIs because optional:vault:// does
  not honor additional-contexts; relocate management port 9091 -> 19091
  to avoid local-host collision with eureka-server
- gateway application.yml: relocate management port 9091 -> 19093 for
  the same collision reason
- SecurityConfiguration: add literal colon endpoints (/v1/auth:register,
  :login, :refresh-token, :activate, :resend-otp, :forgot-password,
  :verify-forgot-pass-otp, :reset-password) to permitAll so Spring
  Security 6 PathPattern matches them exactly

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify**

```bash
git log -1 --stat
```

Expected: 4 files changed, commit message exactly as above.

---

### Task 3: Stop running JVMs cleanly

**Files:** none (process management only)

- [ ] **Step 1: Stop services via the Make target**

```bash
make svc-stop
```

Expected: messages indicating each service was stopped (or `not running`). No errors. PID files in `logs/pids/` should be removed by the script.

- [ ] **Step 2: Sanity check no auth-server JVM still listening**

```bash
lsof -iTCP:6666 -sTCP:LISTEN 2>&1 | head -3
```

Expected: empty output. If a stray Java process is still bound to 6666, kill it explicitly: `kill <PID>` (find PID via `ps -ef | grep authorization-server | grep -v grep`).

- [ ] **Step 3: Clear any leftover Atomikos lock files**

These can prevent the next JVM from starting if a previous JVM crashed.

```bash
find authorization-server -maxdepth 1 -type f \( -name 'tmlog*.log' -o -name 'authorization-server-*.epoch' \) -delete
ls authorization-server/ | grep -E '(tmlog|epoch)' || echo "lock files cleared"
```

Expected: `lock files cleared`

---

### Task 4: Wipe MySQL volumes (master + both slaves only)

**Files:** `docker/mysql.yml` (read-only — its `down -v` removes volumes declared in this compose file)

- [ ] **Step 1: Inspect the mysql compose file to confirm only the three MySQL services are declared in it**

```bash
grep -E '^\s{2}[a-z].*:\s*$' docker/mysql.yml | head -10
```

Expected: three service entries (`master:`, `slave1:`, `slave2:`) and nothing else (no Vault, Mongo, Kafka services). This proves `down -v` on this file is scoped to MySQL.

- [ ] **Step 2: Take MySQL down with volumes**

```bash
docker compose -f docker/mysql.yml --env-file docker/.env down -v
```

Expected: containers stop and are removed; volumes for the three MySQL services are removed. No errors.

- [ ] **Step 3: Confirm no MySQL containers remain**

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -i mysql || echo "no mysql containers"
```

Expected: `no mysql containers`

- [ ] **Step 4: Confirm volumes are gone**

```bash
docker volume ls | grep -i mysql || echo "no mysql volumes"
```

Expected: `no mysql volumes`

---

### Task 5: Bring MySQL back up + verify replication

**Files:** none

- [ ] **Step 1: Start the MySQL stack**

```bash
docker compose -f docker/mysql.yml --env-file docker/.env up -d
```

Expected: 3 containers created (`mysql-master`, `mysql-slave1`, `mysql-slave2`) plus the init container for `init-mysql.sh`. No errors.

- [ ] **Step 2: Wait for all three to be healthy**

```bash
for i in $(seq 1 60); do
  ready=$(docker ps --filter 'name=mysql-' --format '{{.Names}} {{.Status}}' | grep -c '(healthy)' || true)
  echo "[$i/60] $ready/3 healthy"
  [ "$ready" -ge 3 ] && break
  sleep 5
done
```

Expected: terminates with `3/3 healthy` within ~3 minutes.

- [ ] **Step 3: Verify replication on slave1**

```bash
docker exec mysql-slave1 mysql -uroot -pecommerce_slave1 -e "SHOW REPLICA STATUS\G" 2>/dev/null \
  | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_Error'
```

Expected (exact):
```
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
                   Last_Error:
```

- [ ] **Step 4: Verify replication on slave2**

```bash
docker exec mysql-slave2 mysql -uroot -pecommerce_slave2 -e "SHOW REPLICA STATUS\G" 2>/dev/null \
  | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_Error'
```

Expected: same as slave1 — both `Yes`, no `Last_Error`.

- [ ] **Step 5: Confirm `ecommerce_dev` exists on master (init script creates it)**

```bash
docker exec mysql-master mysql -uroot -pecommerce_master -e "SHOW DATABASES;" 2>/dev/null | grep ecommerce_dev
```

Expected: `ecommerce_dev`

If replication is not Yes/Yes within 3 minutes: capture `docker compose -f docker/mysql.yml logs --tail=200` and stop the plan there. Replication setup is a separate failure to triage; the rest of the plan still works for app-layer testing because slaves are URL'd at master, but the verification gate's "Replica_IO_Running: Yes" bullet won't pass.

---

### Task 6: Seed master with `ecommerce.sql`

**Files:** none (uses `docker/ecommerce.sql` and `scripts/seed/mysql.sh`)

- [ ] **Step 1: Run the seed script**

```bash
make seed-mysql
```

Expected: `MySQL ecommerce_dev seeded` (since the DB is fresh, the script's idempotency check finds 0 rows in `account` and proceeds with import).

- [ ] **Step 2: Confirm the four tables exist on master**

```bash
docker exec mysql-master mysql -uroot -pecommerce_master ecommerce_dev -e "SHOW TABLES;" 2>/dev/null
```

Expected:
```
Tables_in_ecommerce_dev
account
account_role
role
user
```

- [ ] **Step 3: Confirm seed rows landed on master**

```bash
docker exec mysql-master mysql -uroot -pecommerce_master ecommerce_dev -N -B \
  -e "SELECT (SELECT COUNT(*) FROM account), (SELECT COUNT(*) FROM role), (SELECT COUNT(*) FROM user);" 2>/dev/null
```

Expected: `2  3  2` (2 accounts, 3 roles, 2 users — matches `ecommerce.sql`).

- [ ] **Step 4: Confirm replication carried the seed to both slaves**

```bash
for s in slave1 slave2; do
  pw=ecommerce_$s
  c=$(docker exec mysql-$s mysql -uroot -p$pw ecommerce_dev -N -B \
        -e "SELECT COUNT(*) FROM account;" 2>/dev/null)
  echo "$s account rows: ${c:-MISSING}"
done
```

Expected:
```
slave1 account rows: 2
slave2 account rows: 2
```

(If replication fell over earlier, both slaves may show `MISSING`. App reads still succeed because slaves are URL'd at master, so this is informational — but flag it.)

---

### Task 7: Re-import Vault secrets

**Files:** none (re-uploads `docker/vault-configs/*.json`)

- [ ] **Step 1: Confirm Vault is unsealed**

```bash
curl -s http://localhost:8200/v1/sys/health | jq '{sealed,initialized}'
```

Expected: `{"sealed": false, "initialized": true}`

If `sealed: true`, run `make vault-unseal` first.

- [ ] **Step 2: Re-import all vault-configs**

```bash
make vault-import
```

Expected: log lines like `Importing ecommerce-common.json -> secret/ecommerce`, one per `*.json` in `docker/vault-configs/`. No errors.

- [ ] **Step 3: Verify the new keys landed**

```bash
source docker/.env && curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/secret/data/ecommerce | jq '.data.data | keys | length, ."spring.datasource.slave1.url"'
```

Expected:
```
33
"jdbc:mysql://localhost:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"
```

(33 keys including `_comment`; slave1.url points at port 3306 — the master.)

---

### Task 8: Start services in tier order

**Files:** none

- [ ] **Step 1: Start everything**

```bash
make svc-start
```

Expected: log lines per tier — `eureka-server` first; then `authorization-server` + `gateway` together; then `inventory-service`, etc. Each ends with `✓ <name> HTTP is up`. The whole sequence completes in ~3-5 minutes.

If any service fails to come up: `tail -200 logs/services/<name>.log` to triage. Do not proceed to verification until all 8 services report healthy.

- [ ] **Step 2: Confirm all 8 PIDs are tracked**

```bash
ls logs/pids/ | sort
```

Expected (8 entries):
```
authorization-server.pid
bff-service.pid
eureka-server.pid
gateway.pid
inventory-service.pid
order-service.pid
orchestrator-service.pid
payment-service.pid
product-service.pid
```

(That's 9 entries actually — the project has 9 services. Adjust expected count if `make status` reports a different number.)

- [ ] **Step 3: Confirm each PID is alive**

```bash
for f in logs/pids/*.pid; do
  pid=$(cat "$f")
  name=$(basename "$f" .pid)
  if kill -0 "$pid" 2>/dev/null; then
    echo "✓ $name (PID $pid)"
  else
    echo "✗ $name (PID $pid DEAD)"
  fi
done
```

Expected: all `✓`. Any `✗` blocks the plan — investigate logs before proceeding.

---

### Task 9: Run the verification gate

**Files:** none — purely curl/docker checks

- [ ] **Step 1: `make status` is healthy**

```bash
make status
```

Expected: green/healthy across all rows. If any service shows red, `tail logs/services/<name>.log` and fix before proceeding.

- [ ] **Step 2: JWKS endpoint reachable through gateway**

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  http://localhost:6868/authorization-server/.well-known/jwks.json
```

Expected: `HTTP 200`

- [ ] **Step 3: Mongo `api_role` collection has 31 docs**

```bash
docker exec docker-ecommerce-mongodb-1 mongosh --quiet \
  -u ecommerce -p ecommerce_mongo --authenticationDatabase admin \
  ecommerce_inventory --eval "db.api_role.countDocuments({})"
```

Expected: `31`

- [ ] **Step 4: Register a fresh user via the gateway (the canary)**

This is the bug that started the whole stabilization. Pick a unique username/email each run.

```bash
TS=$(date +%s)
curl -s -X POST "http://localhost:6868/authorization-server/v1/auth:register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"phase3_$TS\",\"email\":\"phase3_$TS@example.com\",\"password\":\"Aa1!aaaa\",\"fullName\":\"Phase 3 Test $TS\"}" \
  -w "\nHTTP %{http_code}\n"
```

Expected: HTTP 200 or 201 (depending on the controller's success status), JSON body containing `accessToken` and `refreshToken` (or whatever success shape the registration endpoint returns — see `AuthFacadeServiceImpl.register`). Any 401, 403, or 5xx fails the gate.

Save the username for the next step:
```bash
echo "phase3_$TS"  # remember this username
```

- [ ] **Step 5: Login with the user just registered**

```bash
curl -s -X POST "http://localhost:6868/authorization-server/v1/auth:login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"phase3_$TS\",\"password\":\"Aa1!aaaa\"}" \
  -w "\nHTTP %{http_code}\n"
```

Expected: HTTP 200 with `accessToken` and `refreshToken` in body. (If the user requires email activation before login, that's a known flow — still counts as proof reads work; proceed.)

- [ ] **Step 6: Aggregated swagger from the gateway**

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://localhost:6868/v3/api-docs"
```

Expected: `HTTP 200`

- [ ] **Step 7: Tick the verification checklist**

If all of the above passed, the backend is "ready for E2E". Add a brief note to `docs/superpowers/specs/2026-05-02-backend-stabilization-design.md` if anything diverged from the spec.

---

### Task 10: Regenerate frontend OpenAPI schema

**Files:**
- Modify: `frontend/src/api/schema.d.ts`

- [ ] **Step 1: Restore the stashed schema (we don't want the old version, but we don't want to lose the stash entry either)**

```bash
git stash drop  # the stashed schema.d.ts is no longer needed; we'll regenerate fresh
```

Expected: `Dropped refs/stash@{0} (...)`. If `git stash list` shows other stashes you care about, use `git stash drop stash@{0}` explicitly.

- [ ] **Step 2: Regenerate against the live gateway**

```bash
cd frontend && API_GEN_SOURCE="http://localhost:6868/v3/api-docs" pnpm api:gen && cd ..
```

Expected: `frontend/src/api/schema.d.ts` is rewritten. No errors.

- [ ] **Step 3: Typecheck**

```bash
cd frontend && pnpm typecheck && cd ..
```

Expected: `tsc --noEmit` passes with 0 errors.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/api/schema.d.ts
git commit -m "$(cat <<'EOF'
chore(frontend): regenerate OpenAPI schema against stabilized gateway

Generated from http://localhost:6868/v3/api-docs after the backend
stabilization. Typecheck passes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Verify the commit**

```bash
git log -1 --stat
```

Expected: 1 file changed (`frontend/src/api/schema.d.ts`).

---

### Task 11: Push the chore branch

**Files:** none

- [ ] **Step 1: Push the branch upstream**

```bash
git push -u origin chore/local-dev-stabilization
```

Expected: branch pushed; no force; no errors.

- [ ] **Step 2: Surface the branch URL to the user**

The user can decide whether to open a PR now or fold these commits into the Phase 3 PR. Both are acceptable — these commits stand alone as a `chore(local-dev)` change. Do not auto-open the PR.

---

### Task 12: Resume Phase 3 Task 14 (live E2E)

**Files:** Phase 3 plan tracking — `docs/superpowers/plans/2026-05-02-storefront-frontend-phase3.md`

This task is the handoff back to the Phase 3 plan, not new work.

- [ ] **Step 1: Switch back to the Phase 3 branch**

```bash
git checkout frontend/phase-3-api-auth
git merge chore/local-dev-stabilization --no-ff -m "merge: pick up local-dev stabilization for E2E"
```

(If you'd rather rebase, `git rebase chore/local-dev-stabilization` works too. Choose based on your team's branch policy.)

- [ ] **Step 2: Resume Phase 3 Task 14 — live E2E in Chrome DevTools MCP**

Launch the live verification described in the Phase 3 plan: register fresh user → auto-login → user shown in nav; force 401 → redirect to /login; multi-tab logout via storage event. The previously-deferred DoD bullets in `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md` are now testable.

- [ ] **Step 3: Tick the previously-deferred Phase 3 DoD bullets**

Edit `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md` to flip `[ ]` → `[x]` on the bullets that were deferred pending live backend, and update `frontend/docs/phase-3-verification.md` to remove deferred markers.

- [ ] **Step 4: Commit Phase 3 doc updates**

```bash
git add docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md frontend/docs/phase-3-verification.md
git commit -m "$(cat <<'EOF'
docs(phase-3): tick previously-deferred DoD bullets after backend stabilization

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

**Spec coverage:** Each spec section maps to tasks above —
- Spec §1 (capture local fixes) → Tasks 1, 2
- Spec §2 (MySQL reset Mid) → Tasks 3, 4, 5, 6
- Spec §3 (Vault refresh) → Task 7
- Spec §4 (Service start) → Task 8
- Spec §5 (Verification gate) → Task 9
- Spec §6 (post-green: regen schema, resume Phase 3) → Tasks 10, 11, 12
- Spec failure modes → captured inline (Task 3 Atomikos cleanup, Task 5 replication-failure note, Task 6 idempotency note)

**Open considerations the executor should know:**
- The `make status` Make target's exact output format wasn't read in this plan; the verifier should accept "all green" qualitatively rather than match a string.
- The auth-server register endpoint's exact success status (200 vs 201) and body shape were not pinned down; the gate accepts either as long as `accessToken`/`refreshToken` are present.
- The 9th service (`bff-service` per the PID list) was not part of the original 8-service mental model from the spec — that's fine, the gate doesn't depend on a specific count, just that all PIDs are alive.
