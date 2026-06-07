# In-Cluster Payment-Flow Stress Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the in-cluster k6 payment-saga stress test run cleanly on the kind cluster and prove a fixed SLO (hold 50 VUs / 3 min, errors <5%, p95 create_payment <2s), producing throughput numbers + a populated Grafana k6 dashboard + an HPA scale-up observation — and delete the now-unused k6 surfaces it replaces.

**Architecture:** A new idempotent kustomize bootstrap Job (`06-perftest-seed`, SQL co-located in-tree) seeds the 100 perftest users + admin into authorization-server MySQL, wired into `make k8s-bootstrap`. `payment-flow.js` gets the locked SLO profile/thresholds; `payment-job.yaml` is pointed at real seeded catalog product IDs. Two new Makefile targets fire/tail the payment Job re-runnably. The unused host harness (`k6-tests/`) and the in-cluster browse stress (`k6-stress` Job + `script.js`) are removed. Phase 0 brings the whole cluster up from scratch (first live exercise of the Java-25 mock-paypal wiring) and a single-VU dry run gates the real load run.

**Tech Stack:** kind (local k8s), kustomize, k6 (grafana/k6:0.54.0), VictoriaMetrics + Grafana (k6 dashboard #19665), MySQL 8.0, GNU Make, mock-paypal-service (Java 25 / Spring Boot 3.5.3).

**Spec:** `docs/superpowers/specs/2026-06-05-incluster-payment-stress-design.md`

---

## Context the engineer needs (read before starting)

- **Seed-Job pattern to mirror:** `k8s/infra/jobs/01-mysql-seed/` (`job.yaml`, `seed.sh`, `kustomization.yaml`). It connects to `mysql.infra.svc.cluster.local` as `root` / `MYSQL_ROOT_PASSWORD=root`, against schema `ecommerce_dev`. **Difference for us:** `01-mysql-seed` loads out-of-tree `docker/ecommerce.sql`, so it needs imperative configMaps + `apply -f`. Our seed SQL lives *in the Job dir* (in-tree), so we use the normal `configMapGenerator` + `kubectl apply -k` (like the vault/minio/kafka seed Jobs).
- **Ordering SCAR:** `docker/ecommerce.sql` is data-only; JPA tables are created by Hibernate `ddl-auto` at service boot. So any MySQL seed that writes `account`/`user`/`role` MUST run **after** `k8s-apps` (authorization-server Ready). That is why `k8s-seed-mysql` and `k8s-seed-inventory` run after `k8s-apps`, and `06-perftest-seed` joins them.
- **`set -eu` seed scripts:** always `sh -n` a seed script after editing — a parse error is fatal and aborts the Job.
- **Real catalog product IDs** (from `docker/product.json`, seeded into Mongo and inventoried by `k8s-seed-inventory`): `67c000000000000000000001`, `67c000000000000000000002`, `67c000000000000000000003`. These are the values `payment-flow.js` must use; its current default (`test-product-1..3`) is fake and does not exist in this architecture.
- **k6 tag names already in `payment-flow.js`:** login request is tagged `name: 'login'` (line ~82); payment creation is tagged `name: 'create_payment'` (line ~104). The SLO thresholds key off these exact tags.
- **`payment-flow.js` setup() credentials defaults** already match the seed: `ADMIN_USER=perftest_admin` / `ADMIN_PASS=Admin@123456` / `USER_PASS=Test@123456` / `USER_COUNT=100`.
- **Sandbox note:** the assistant cannot run bare `rm`. The cleanup task (Task 7) uses `git rm`; if that is also blocked in your environment, ask the user to run the deletion with a `! ` prefix.

---

## File Structure

| File | Responsibility |
|---|---|
| `k8s/infra/jobs/06-perftest-seed/perftest-users.sql` *(new)* | Users-only seed SQL (admin + 100 users + ADMIN/USER roles). No product/inventory inserts. |
| `k8s/infra/jobs/06-perftest-seed/seed.sh` *(new)* | Idempotency guard + pipe the SQL into MySQL master. |
| `k8s/infra/jobs/06-perftest-seed/job.yaml` *(new)* | Job (ns `bootstrap`, image `mysql:8.0`) mounting the two generated configMaps. |
| `k8s/infra/jobs/06-perftest-seed/kustomization.yaml` *(new)* | Generates both configMaps from the in-tree files; applied with `kubectl apply -k`. |
| `Makefile` *(modify)* | `k8s-seed-perftest` target + chain into `k8s-bootstrap`; `k8s-payment-stress` + `k8s-payment-stress-logs` targets; remove `k8s-stress`/`k8s-stress-logs`; fix help text. |
| `k8s/apps/base/k6-stress/payment-flow.js` *(modify)* | SLO `options` (profile + thresholds) + fix stale seed-path comment. |
| `k8s/apps/base/k6-stress/payment-job.yaml` *(modify)* | `PRODUCT_IDS` env = real catalog IDs. |
| `k6-tests/` *(delete, whole tree)* | Unused host harness (run.sh, scenarios/*, tests/full-flow.js, config.js, helpers/*, setup/seed-users.sql). |
| `k8s/apps/base/k6-stress/script.js` *(delete)* | Unused browse-only stress script. |
| `k8s/apps/base/k6-stress/job.yaml` *(delete)* | Unused browse stress Job (`k6-stress`). |
| `k8s/apps/base/k6-stress/kustomization.yaml` *(delete)* | Becomes unused once browse Job is gone and the payment target applies `payment-job.yaml` directly. |
| `k8s/README.md`, `mock-paypal-service/README.md` *(modify)* | Drop references to deleted artifacts; point at the in-cluster payment flow. |

---

## Task 1: Users-only perftest seed SQL (in the Job dir)

**Files:**
- Create: `k8s/infra/jobs/06-perftest-seed/perftest-users.sql`

Seeds only the authorization-server tables, against the **real** schema (verified from the JPA entities + `docker/ecommerce.sql`), which differs from the old `k6-tests/setup/seed-users.sql`:
- Tables/relationship: `user(id, email UNIQUE)` ← `account(id, username UNIQUE, password, is_activated, user_id NOT NULL→user.id)` → `account_role(id, account_id, role_id)`. **`account` has no `created_at`; `user` has no `account_id`.** Insert order is user → account → account_role.
- Roles in this schema are `EMPLOYEE, ADMIN, MERCHANT` — **there is no `USER` role.** Order/payment endpoints require `AUTHORIZED` (any authenticated account), so the 100 load users get **no role row**; only `perftest_admin` gets `ADMIN` (needed for the `PATCH /inventory-service/...` top-up in k6 `setup()`).
- BCrypt hashes are cost-10 and **verified with `htpasswd`** to match `Admin@123456` / `Test@123456` (the hashes in the old file did NOT match their labels). All 100 users share one verified `Test@123456` hash.
- Idempotent: `email`/`username` are UNIQUE so `INSERT IGNORE` is a no-op on re-run; the admin role link is guarded by a pre-counted variable.

- [ ] **Step 1: Create the SQL file**

```sql
-- =============================================
-- K6 Performance Test - USERS-ONLY Seed (in-cluster safe)
-- =============================================
-- Seeds only authorization-server tables: `user`, `account`, `account_role`.
-- Schema (from authorization-server JPA entities + docker/ecommerce.sql):
--   user(id PK, email UNIQUE NOT NULL, name, gender, address, avatar_url)
--   account(id PK, username UNIQUE NOT NULL, password NOT NULL,
--           is_activated NOT NULL, user_id NOT NULL -> user.id)
--   account_role(id PK, account_id NOT NULL, role_id NOT NULL)
--   role(id PK, name)        -- existing roles: EMPLOYEE, ADMIN, MERCHANT
-- Insert order matters: user -> account (FK user_id) -> account_role.
--
-- Authorization model (docker/api_role.json): the order/payment endpoints the
-- k6 flow hits require AUTHORIZED (any authenticated account), so the 100 load
-- users need NO role row -- only a valid account to log in. perftest_admin gets
-- the ADMIN role because the k6 setup() phase tops up stock via
-- PATCH /inventory-service/v1/inventories/** which requires ADMIN. There is no
-- "USER" role in this schema.
--
-- Products are NOT seeded here (catalog lives in MongoDB; the k6 test points
-- PRODUCT_IDS at real seeded catalog IDs).
--
-- Passwords (bcrypt cost 10, verified with htpasswd against this exact hash):
--   perftest_admin  = Admin@123456
--   perftest_user_N = Test@123456
-- Idempotent: `email`/`username` are UNIQUE so INSERT IGNORE is a no-op on
-- re-run; the admin role link is guarded by a pre-counted variable. The
-- 06-perftest-seed Job additionally skips the whole script if perftest_admin
-- already exists (see seed.sh).
-- =============================================

-- ---- admin: user -> account -> ADMIN role ----
INSERT IGNORE INTO `user` (id, email)
VALUES (UUID(), 'perftest_admin@test.com');

SET @admin_user_id = (SELECT id FROM `user` WHERE email = 'perftest_admin@test.com');

INSERT IGNORE INTO `account` (id, username, password, is_activated, user_id)
VALUES (
  UUID(),
  'perftest_admin',
  '$2a$10$4piyvE7LAoy8KVqhbcwN1.hUxQTkP9eOU.4ZvlPFJlMwPgaIYS3MG', -- Admin@123456
  1,
  @admin_user_id
);

SET @admin_account_id = (SELECT id FROM `account` WHERE username = 'perftest_admin');
SET @admin_role_id    = (SELECT id FROM `role` WHERE name = 'ADMIN' LIMIT 1);
SET @admin_link_count = (SELECT COUNT(*) FROM `account_role`
                         WHERE account_id = @admin_account_id AND role_id = @admin_role_id);

-- account_role has no UNIQUE(account_id, role_id), so guard via the pre-counted
-- variable (FROM DUAL avoids referencing the target table in the INSERT-SELECT).
INSERT INTO `account_role` (id, account_id, role_id)
SELECT UUID(), @admin_account_id, @admin_role_id
FROM DUAL
WHERE @admin_role_id IS NOT NULL AND @admin_link_count = 0;

-- ---- 100 load users: user + account only (AUTHORIZED = authenticated) ----
DELIMITER //
DROP PROCEDURE IF EXISTS create_perftest_users//
CREATE PROCEDURE create_perftest_users()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE v_user_id VARCHAR(36);
  DECLARE uname VARCHAR(50);
  DECLARE uemail VARCHAR(100);

  WHILE i <= 100 DO
    SET uname  = CONCAT('perftest_user_', i);
    SET uemail = CONCAT('perftest_user_', i, '@test.com');

    INSERT IGNORE INTO `user` (id, email) VALUES (UUID(), uemail);
    SET v_user_id = (SELECT id FROM `user` WHERE email = uemail);

    INSERT IGNORE INTO `account` (id, username, password, is_activated, user_id)
    VALUES (
      UUID(),
      uname,
      '$2a$10$p0YRQWiVtDe8ioifDNLyI.y9rbjl/5aWWYR.q3bFb5tSNhs5DTtZC', -- Test@123456
      1,
      v_user_id
    );

    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;

CALL create_perftest_users();
DROP PROCEDURE IF EXISTS create_perftest_users;

SELECT 'perftest admin:'  AS status, COUNT(*) AS n FROM `account` WHERE username = 'perftest_admin';
SELECT 'perftest users:'  AS status, COUNT(*) AS n FROM `account` WHERE username LIKE 'perftest_user_%';
SELECT 'admin ADMIN link:' AS status, COUNT(*) AS n
  FROM `account_role` ar
  JOIN `account` a ON a.id = ar.account_id
  JOIN `role` r    ON r.id = ar.role_id
  WHERE a.username = 'perftest_admin' AND r.name = 'ADMIN';
```

- [ ] **Step 2: Sanity-check the SQL is well-formed**

Run:
```bash
grep -c 'DELIMITER' k8s/infra/jobs/06-perftest-seed/perftest-users.sql
grep -ci 'INSERT INTO product\|INSERT INTO inventory' k8s/infra/jobs/06-perftest-seed/perftest-users.sql
```
Expected: first prints `2` (the two full `DELIMITER` lines: `DELIMITER //` to open and `DELIMITER ;` to restore), second prints `0` (no monolith product/inventory inserts leaked in).

- [ ] **Step 3: Commit**

```bash
git add k8s/infra/jobs/06-perftest-seed/perftest-users.sql
git commit -m "feat(k8s): users-only perftest seed SQL (in-cluster safe)"
```

---

## Task 2: `06-perftest-seed` bootstrap Job

**Files:**
- Create: `k8s/infra/jobs/06-perftest-seed/seed.sh`
- Create: `k8s/infra/jobs/06-perftest-seed/job.yaml`
- Create: `k8s/infra/jobs/06-perftest-seed/kustomization.yaml`

Mirrors `01-mysql-seed`, but both source files are in-tree so the kustomization's `configMapGenerator` reads them directly and the Job is applied with `kubectl apply -k`. The Job runs in namespace `bootstrap`, uses `mysql:8.0`, mounts `seed.sh` at `/scripts` and `perftest-users.sql` at `/seed`.

- [ ] **Step 1: Create `seed.sh`**

```sh
#!/usr/bin/env sh
# Seed perftest users (admin + 100 users + roles) into authorization-server
# MySQL. Idempotent: skip if perftest_admin already present; the SQL itself is
# also INSERT IGNORE / ON DUPLICATE KEY. Must run AFTER k8s-apps so the JPA
# tables (account/user/role/account_role) exist (Hibernate ddl-auto creates
# them at authorization-server startup).
set -eu

EXISTS=$(mysql -h mysql.infra.svc.cluster.local -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -N -e "SELECT COUNT(*) FROM ecommerce_dev.account WHERE username='perftest_admin';")

if [ "${EXISTS}" -gt 0 ]; then
  echo "perftest users already seeded (perftest_admin present); skipping"
  exit 0
fi

echo "seeding perftest users..."
mysql -h mysql.infra.svc.cluster.local -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  ecommerce_dev < /seed/perftest-users.sql
echo "perftest user seed complete"
```

- [ ] **Step 2: Verify the script parses**

Run: `sh -n k8s/infra/jobs/06-perftest-seed/seed.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Create `job.yaml`**

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: perftest-seed
  namespace: bootstrap
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: seed
          image: mysql:8.0
          env:
            - name: MYSQL_ROOT_PASSWORD
              value: root
          command: ["/bin/sh", "/scripts/seed.sh"]
          volumeMounts:
            - name: scripts
              mountPath: /scripts
            - name: sql
              mountPath: /seed
      volumes:
        - name: scripts
          configMap:
            name: perftest-seed-scripts
            defaultMode: 0755
        - name: sql
          configMap:
            name: perftest-seed-sql
```

- [ ] **Step 4: Create `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: bootstrap
resources:
  - job.yaml
# Both source files are in-tree, so (unlike 01-mysql-seed, whose data lives
# out-of-tree in docker/) the generator reads them directly and the Makefile
# uses plain `kubectl apply -k`.
configMapGenerator:
  - name: perftest-seed-scripts
    files:
      - seed.sh
  - name: perftest-seed-sql
    files:
      - perftest-users.sql
generatorOptions:
  disableNameSuffixHash: true
```

- [ ] **Step 5: Verify the kustomization builds and wires the configMaps**

Run:
```bash
kubectl kustomize k8s/infra/jobs/06-perftest-seed >/tmp/perftest-seed.yaml && \
  grep -E "name: perftest-seed-(scripts|sql)|kind: (Job|ConfigMap)" /tmp/perftest-seed.yaml
```
Expected: shows `kind: ConfigMap` for `perftest-seed-scripts` and `perftest-seed-sql`, plus `kind: Job`. (If `kubectl` is unavailable offline, fall back to `python3 -c "import yaml; list(yaml.safe_load_all(open('k8s/infra/jobs/06-perftest-seed/job.yaml'))); print('OK')"` → `OK`.)

- [ ] **Step 6: Commit**

```bash
git add k8s/infra/jobs/06-perftest-seed/seed.sh k8s/infra/jobs/06-perftest-seed/job.yaml k8s/infra/jobs/06-perftest-seed/kustomization.yaml
git commit -m "feat(k8s): 06-perftest-seed bootstrap Job for k6 perftest users"
```

---

## Task 3: Makefile `k8s-seed-perftest` target + wire into bootstrap

**Files:**
- Modify: `Makefile` (the `.PHONY` block near `k8s-seed-inventory` ~line 192, after the `k8s-seed-inventory` target ~line 259, and the `k8s-bootstrap` recipe ~line 316)

- [ ] **Step 1: Add the `k8s-seed-perftest` target**

Add immediately after the `k8s-seed-inventory` target (after its `scripts/seed/k8s-inventory.sh` line, ~line 259):

```makefile

# k8s-seed-perftest: seed the k6 load-test fixtures (perftest_admin + 100
# perftest_user_N + role assignments) into authorization-server MySQL. Runs
# SEPARATELY, AFTER k8s-apps — the account/user/role tables are created by
# Hibernate ddl-auto at authorization-server startup. Both the script and the
# SQL are in-tree, so this uses plain `kubectl apply -k`. Idempotent (seed.sh
# skips if perftest_admin exists; the SQL is INSERT IGNORE). Re-runnable: the
# Job is deleted first (Jobs are immutable).
k8s-seed-perftest:
	@echo "==> applying 06-perftest-seed (job/perftest-seed)"
	@kubectl -n bootstrap delete job perftest-seed --ignore-not-found >/dev/null
	@kubectl apply -k k8s/infra/jobs/06-perftest-seed
	@kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/perftest-seed
	@echo "k8s-seed-perftest complete"
```

- [ ] **Step 2: Add `k8s-seed-perftest` to the `.PHONY` list**

Find (~192):
```makefile
.PHONY: k8s-infra k8s-seed k8s-seed-mysql k8s-seed-inventory k8s-seed-images k8s-app-secrets
```
Replace with:
```makefile
.PHONY: k8s-infra k8s-seed k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest k8s-seed-images k8s-app-secrets
```

- [ ] **Step 3: Wire it into `k8s-bootstrap`**

Find (~316):
```makefile
k8s-bootstrap: k8s-cluster-up k8s-infra k8s-build k8s-seed k8s-seed-images k8s-apps k8s-seed-mysql k8s-seed-inventory
```
Replace with:
```makefile
k8s-bootstrap: k8s-cluster-up k8s-infra k8s-build k8s-seed k8s-seed-images k8s-apps k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest
```

- [ ] **Step 4: Verify Make parses the target**

Run: `make -n k8s-seed-perftest`
Expected: prints the echo, `kubectl ... delete job perftest-seed`, `kubectl apply -k k8s/infra/jobs/06-perftest-seed`, and the `wait` — no "No rule to make target".

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "feat(make): k8s-seed-perftest target wired into k8s-bootstrap"
```

---

## Task 4: Makefile payment-stress fire/tail targets

**Files:**
- Modify: `Makefile` (the `.PHONY: k8s-apps ...` block ~line 268 and after the existing `k8s-stress-logs` target ~line 309)

The new target creates the `k6-payment-script` configMap imperatively and applies **only** `payment-job.yaml` with `kubectl apply -f` — deliberately NOT `kubectl apply -k k8s/apps/base/k6-stress` (which would also be wrong after Task 7 removes the browse pieces). Re-runnable: deletes the prior Job first (Jobs are immutable).

- [ ] **Step 1: Extend the `.PHONY` line**

Find (~268):
```makefile
.PHONY: k8s-apps k8s-apps-down k8s-status k8s-stress k8s-stress-logs
```
Replace with:
```makefile
.PHONY: k8s-apps k8s-apps-down k8s-status k8s-stress k8s-stress-logs k8s-payment-stress k8s-payment-stress-logs
```
*(Task 7 later trims `k8s-stress k8s-stress-logs` from this line; leave them for now so the existing targets stay valid until then.)*

- [ ] **Step 2: Add the two targets after `k8s-stress-logs`**

Insert immediately after the existing `k8s-stress-logs` target (~line 309):

```makefile

# Fire the k6 PAYMENT-saga stress Job (drives mock-paypal-service through the
# full login -> order -> payment -> approve flow). Opt-in. Re-runnable — deletes
# the previous Job first (Jobs are immutable). Applies ONLY payment-job.yaml;
# the script configMap is created imperatively (stable name `k6-payment-script`).
k8s-payment-stress:
	@kubectl -n apps delete job k6-payment-stress --ignore-not-found
	@kubectl -n apps create configmap k6-payment-script \
	  --from-file=k8s/apps/base/k6-stress/payment-flow.js --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f k8s/apps/base/k6-stress/payment-job.yaml
	@echo "k6 payment stress running. Watch with: make k8s-payment-stress-logs"
	@echo "Watch HPA: kubectl -n apps get hpa -w"

k8s-payment-stress-logs:
	@kubectl -n apps logs -f -l app=k6-payment-stress --tail=-1
```

- [ ] **Step 3: Verify Make parses both targets**

Run: `make -n k8s-payment-stress && make -n k8s-payment-stress-logs`
Expected: `k8s-payment-stress` prints the delete, the `create configmap k6-payment-script` pipeline, `kubectl apply -f k8s/apps/base/k6-stress/payment-job.yaml`, and the two echoes; `k8s-payment-stress-logs` prints the `kubectl ... logs -f -l app=k6-payment-stress` line.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat(make): k8s-payment-stress + logs targets (re-runnable, payment Job only)"
```

---

## Task 5: SLO profile + thresholds in `payment-flow.js`

**Files:**
- Modify: `k8s/apps/base/k6-stress/payment-flow.js` (the `options` block ~lines 31-42, and the stale seed-path comment ~line 19)

- [ ] **Step 1: Replace the `options` block**

Find:
```javascript
export const options = {
  stages: [
    { duration: '30s', target: 10 },
    { duration: '1m',  target: 30 },
    { duration: '2m',  target: 30 },   // hold — gives the saga time under load
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.10'],
    checks: ['rate>0.90'],
  },
};
```
Replace with:
```javascript
export const options = {
  // SLO bar: hold 50 VUs for 3m. The held, error-free VU level is the
  // sustained-throughput figure to quote. If the kind cluster saturates on a
  // laptop, step the hold target down to 30/20 and re-run.
  stages: [
    { duration: '1m',  target: 50 },   // ramp to the SLO load
    { duration: '3m',  target: 50 },   // HOLD — the sustained-throughput window
    { duration: '30s', target: 0 },    // ramp down
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    checks: ['rate>0.95'],
    'http_req_duration{name:create_payment}': ['p(95)<2000'],
    'http_req_duration{name:login}': ['p(95)<800'],
  },
};
```

- [ ] **Step 2: Fix the stale seed-path comment**

Find (~line 19, inside the header comment):
```javascript
// Prerequisites in the cluster: the perftest users (k6-tests/setup/seed-users.sql)
// and the PRODUCT_IDS must exist. The script fails loudly in setup() otherwise.
```
Replace with:
```javascript
// Prerequisites in the cluster: the perftest users (seeded by `make
// k8s-seed-perftest` / the 06-perftest-seed Job) and the PRODUCT_IDS must exist.
// The script fails loudly in setup() otherwise.
```

- [ ] **Step 3: Verify the script still parses as JS**

Run: `node --check k8s/apps/base/k6-stress/payment-flow.js && echo OK`
Expected: `OK`. (If `node` is unavailable, syntax can be eyeballed — `--check` only validates parse, which is the goal; k6's runtime imports won't resolve under bare node anyway.)

- [ ] **Step 4: Confirm the threshold tags match the request tags in the file**

Run: `grep -nE "tags: \{ name: '(login|create_payment)'" k8s/apps/base/k6-stress/payment-flow.js`
Expected: two lines — one `name: 'login'` and one `name: 'create_payment'`.

- [ ] **Step 5: Commit**

```bash
git add k8s/apps/base/k6-stress/payment-flow.js
git commit -m "feat(k6): SLO profile (hold 50 VUs/3m) + thresholds for payment stress"
```

---

## Task 6: Real catalog `PRODUCT_IDS` in `payment-job.yaml`

**Files:**
- Modify: `k8s/apps/base/k6-stress/payment-job.yaml` (the `env:` list)

Without `PRODUCT_IDS`, `payment-flow.js` falls back to `test-product-1,2,3`, which do not exist in this architecture. Point it at three real seeded ObjectIds.

- [ ] **Step 1: Add the `PRODUCT_IDS` env var**

Find (in the `env:` list, after the `INGRESS_ORIGIN` line ~25):
```yaml
            - { name: INGRESS_ORIGIN, value: "http://api.microecom.local" }
```
Add immediately after it:
```yaml
            # Real seeded catalog ObjectIds (docker/product.json -> Mongo,
            # inventoried by `make k8s-seed-inventory`). The script's default
            # (test-product-1..3) is fake and does not exist in this split
            # architecture, so this override is required.
            - { name: PRODUCT_IDS, value: "67c000000000000000000001,67c000000000000000000002,67c000000000000000000003" }
```

- [ ] **Step 2: Verify the YAML is valid and the var is present**

Run:
```bash
python3 -c "import yaml; d=list(yaml.safe_load_all(open('k8s/apps/base/k6-stress/payment-job.yaml'))); env=d[0]['spec']['template']['spec']['containers'][0]['env']; print([e for e in env if e['name']=='PRODUCT_IDS'])"
```
Expected: `[{'name': 'PRODUCT_IDS', 'value': '67c000000000000000000001,67c000000000000000000002,67c000000000000000000003'}]`

- [ ] **Step 3: Confirm those IDs exist in the catalog seed**

Run:
```bash
python3 -c "
import json
ids={p['_id']['\$oid'] for p in json.load(open('docker/product.json'))}
for want in ['67c000000000000000000001','67c000000000000000000002','67c000000000000000000003']:
    print(want, 'FOUND' if want in ids else 'MISSING')
"
```
Expected: all three print `FOUND`.

- [ ] **Step 4: Commit**

```bash
git add k8s/apps/base/k6-stress/payment-job.yaml
git commit -m "fix(k6): point payment stress at real seeded catalog product IDs"
```

---

## Task 7: Delete unused k6 surfaces

**Files:**
- Delete: `k6-tests/` (whole tree — run.sh, scenarios/*, tests/full-flow.js, config.js, helpers/*, setup/seed-users.sql)
- Delete: `k8s/apps/base/k6-stress/script.js`, `k8s/apps/base/k6-stress/job.yaml`, `k8s/apps/base/k6-stress/kustomization.yaml`
- Modify: `Makefile` (remove `k8s-stress`/`k8s-stress-logs` targets, trim `.PHONY`, fix help text)
- Modify: `k8s/README.md`, `mock-paypal-service/README.md`

The host harness and the browse stress are superseded by the in-cluster payment flow. The `k6-stress` kustomization is unused once the browse Job is gone and the payment target applies `payment-job.yaml` directly (Task 4).

- [ ] **Step 1: Delete the host harness and browse-stress files**

```bash
git rm -r k6-tests
git rm k8s/apps/base/k6-stress/script.js k8s/apps/base/k6-stress/job.yaml k8s/apps/base/k6-stress/kustomization.yaml
```
Expected: git lists the removed paths. (If `git rm` is sandbox-blocked, ask the user to run the two commands with a `! ` prefix.) After this, `k8s/apps/base/k6-stress/` contains only `payment-flow.js` and `payment-job.yaml`.

- [ ] **Step 2: Remove the `k8s-stress` / `k8s-stress-logs` targets**

In `Makefile`, find and delete the whole block (~lines 300-309):
```makefile
# Fire the k6 stress Job. Opt-in (NOT part of k8s-apps) so `make k8s-apps`
# doesn't trigger load. Re-runnable — deletes the previous Job first.
k8s-stress:
	@kubectl -n apps delete job k6-stress --ignore-not-found
	@kubectl apply -k k8s/apps/base/k6-stress
	@echo "k6 stress running. Watch with: make k8s-stress-logs"
	@echo "Watch HPA: kubectl -n apps get hpa -w"

k8s-stress-logs:
	@kubectl -n apps logs -f -l app=k6-stress --tail=-1
```

- [ ] **Step 3: Trim the `.PHONY` line (was extended in Task 4)**

Find:
```makefile
.PHONY: k8s-apps k8s-apps-down k8s-status k8s-stress k8s-stress-logs k8s-payment-stress k8s-payment-stress-logs
```
Replace with:
```makefile
.PHONY: k8s-apps k8s-apps-down k8s-status k8s-payment-stress k8s-payment-stress-logs
```

- [ ] **Step 4: Fix the help text**

Find (~lines 42-43):
```makefile
	@echo "  make k8s-stress       — fire k6 load Job (opt-in)"
	@echo "  make k8s-stress-logs  — tail k6 output"
```
Replace with:
```makefile
	@echo "  make k8s-payment-stress      — fire k6 payment-saga load Job (opt-in)"
	@echo "  make k8s-payment-stress-logs — tail k6 payment-stress output"
```

- [ ] **Step 5: Scrub doc references to the deleted artifacts**

Update `k8s/README.md` and `mock-paypal-service/README.md`: replace any mention of `k6-stress`/`script.js`/`make k8s-stress`, the host `k6-tests/` harness (`full-flow.js`, `seed-users.sql`, `run.sh`), with the in-cluster equivalents (`make k8s-payment-stress`, `payment-flow.js`, `make k8s-seed-perftest`). Find them with:
```bash
grep -rni "k6-stress\|k8s-stress\|k6-tests\|full-flow\|seed-users\|script\.js" k8s/README.md mock-paypal-service/README.md
```
Reword each hit (keep it short — these are reference docs, not prose). Re-run the grep after editing.

- [ ] **Step 6: Verify nothing still references the deleted paths**

Run:
```bash
grep -rni --exclude-dir=.git --exclude-dir=docs "k6-tests\|k8s-stress\b\|k6-stress\b\|/script\.js\|seed-users\.sql\|full-flow\.js" . | grep -v "payment-stress\|payment-flow"
```
Expected: **no output** (every remaining reference is to the payment Job/flow). Anything printed is a dangling reference to fix.

- [ ] **Step 7: Verify Make still parses end-to-end**

Run: `make -n k8s-payment-stress && make -n k8s-seed-perftest && echo OK`
Expected: both expand cleanly, ending `OK` — and `make -n k8s-stress` now errors with "No rule to make target" (target removed).

- [ ] **Step 8: Commit**

```bash
git add -A k6-tests k8s/apps/base/k6-stress Makefile k8s/README.md mock-paypal-service/README.md
git commit -m "chore(k6): delete unused host harness + browse stress; keep in-cluster payment flow"
```
*(Note: scope the `git add` to the listed paths — do NOT `git add -A` from the repo root.)*

---

## Task 8: Phase 0 — full bootstrap + single-VU dry run (verification gate)

This task runs no edits unless a defect surfaces; it is the gate that proves the wiring works before load. **Do not skip — this is the first time the Java-25 mock-paypal k8s wiring runs on a live cluster.** If a step fails, switch to `superpowers:systematic-debugging`, fix at the failing layer, commit the fix, and re-run from the failed step.

- [ ] **Step 1: Bring up the whole cluster from scratch**

Run: `make k8s-bootstrap`
Expected: completes through `k8s-status` + the `/etc/hosts` banner. The new `k8s-seed-perftest` runs last and prints `k8s-seed-perftest complete`.

- [ ] **Step 2: Confirm `/etc/hosts` entries (one-time, user action if missing)**

Run: `grep -E 'microecom\.local' /etc/hosts`
Expected: both `microecom.local` and `api.microecom.local` → `127.0.0.1`. If missing, ask the user to add them.

- [ ] **Step 3: Confirm all apps Ready, including mock-paypal**

Run: `kubectl -n apps get pods`
Expected: every pod `Running` and ready, including `mock-paypal-service-*`.

- [ ] **Step 4: Confirm payment-service points at the mock**

Run:
```bash
kubectl -n apps exec deploy/payment-service -- printenv | grep -i 'paypal\|SPRING_APPLICATION_JSON'
```
Expected: shows the mock base-url (`http://mock-paypal-service.apps.svc.cluster.local:8585/mock-paypal-service`). If not, the overlay patch isn't applied — fix and `make k8s-apps`.

- [ ] **Step 5: Confirm perftest users seeded**

Run:
```bash
kubectl -n infra exec -i $(kubectl -n infra get pod -l app=mysql -o jsonpath='{.items[0].metadata.name}') -- \
  mysql -uroot -proot -N -e "SELECT COUNT(*) FROM ecommerce_dev.account WHERE username LIKE 'perftest_user_%';"
```
Expected: `100`. (If the label differs, find the pod via `kubectl -n infra get pods | grep mysql`.)

- [ ] **Step 6: Confirm the metrics sink is reachable**

Run: `kubectl -n monitoring get svc vmsingle`
Expected: a `ClusterIP` service exists. If the name differs, `kubectl -n monitoring get svc | grep -i vm` and update `payment-job.yaml`'s `K6_PROMETHEUS_RW_SERVER_URL` host before the real run.

- [ ] **Step 7: Single-VU dry run (the saga must go green once before load)**

```bash
kubectl -n apps delete pod k6-payment-dryrun --ignore-not-found
kubectl -n apps create configmap k6-payment-script \
  --from-file=k8s/apps/base/k6-stress/payment-flow.js --dry-run=client -o yaml | kubectl apply -f -
kubectl -n apps run k6-payment-dryrun --image=grafana/k6:0.54.0 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"k6","image":"grafana/k6:0.54.0","args":["run","--vus","1","--iterations","1","/scripts/payment-flow.js"],"env":[{"name":"BASE_URL","value":"http://gateway.apps.svc.cluster.local:6868"},{"name":"INGRESS_ORIGIN","value":"http://api.microecom.local"},{"name":"PRODUCT_IDS","value":"67c000000000000000000001,67c000000000000000000002,67c000000000000000000003"}],"volumeMounts":[{"name":"script","mountPath":"/scripts"}]}],"volumes":[{"name":"script","configMap":{"name":"k6-payment-script"}}]}}'
kubectl -n apps wait --for=condition=Ready pod/k6-payment-dryrun --timeout=60s || true
kubectl -n apps logs -f pod/k6-payment-dryrun
```
Expected: `setup()` passes (admin login OK, inventory topped up) and the iteration's checks (`login 200`, `order 201`, `payment 200`, `has links`, `flow settled`) all pass. No `admin login failed` / `gateway not reachable`.

- [ ] **Step 8: Confirm the saga actually completed (not just HTTP 200s)**

```bash
kubectl -n infra exec -i $(kubectl -n infra get pod -l app=mysql -o jsonpath='{.items[0].metadata.name}') -- \
  mysql -uroot -proot -N -e "SELECT status, COUNT(*) FROM ecommerce_dev.\`order\` GROUP BY status;"
```
Expected: at least one order in a terminal saga state (`COMPLETED`, or a cancelled/failed state for the 5/5 decisions), proving the Kafka/orchestrator saga ran end-to-end. If everything is stuck at `PROCESSING`, consult the Mongo-CDC/Avro SCAR in `k8s/CLAUDE.md` before load testing.

- [ ] **Step 9: Clean up the dry-run pod**

Run: `kubectl -n apps delete pod k6-payment-dryrun --ignore-not-found`
Expected: `pod "k6-payment-dryrun" deleted`.

*(No commit unless a defect fix was required — commit any such fix at the layer it was found.)*

---

## Task 9: SLO run + read results

The deliverable: a held throughput figure with p95 + error rate, a populated Grafana k6 dashboard, and an HPA scale-up observation.

- [ ] **Step 1: Open watchers**

Background: `kubectl -n apps get hpa -w`. Grafana: `kubectl -n monitoring port-forward svc/grafana 3000:80`, open dashboard **#19665**. (Confirm the svc name with `kubectl -n monitoring get svc | grep -i grafana`.)

- [ ] **Step 2: Fire the SLO run**

Run: `make k8s-payment-stress`
Expected: prints "k6 payment stress running" + the HPA hint; Job `k6-payment-stress` starts in `apps`.

- [ ] **Step 3: Tail to completion**

Run: `make k8s-payment-stress-logs`
Expected: k6 ramps 0→50, holds 50 for 3m, ramps down; the **THRESHOLDS** block reports pass/fail for `http_req_failed<0.05`, `checks>0.95`, `p95{create_payment}<2000`, `p95{login}<800`.

- [ ] **Step 4: Record the result**

Capture: total iterations, `http_reqs` rate (req/s), `iteration_duration` p95, per-tag p95 for `create_order`/`create_payment`, `checks` pass rate; and from the HPA watch, whether `order-service`/`inventory-service` scaled up and to how many replicas.
Expected: a one-paragraph summary for the interview: "sustained 50 VUs ≈ M payment sagas/s at p95 X ms, error rate Y% (<5% SLO); order-service autoscaled A→B pods under load."

- [ ] **Step 5: Calibrate if saturated (only if thresholds failed on resource saturation)**

If `http_req_failed` exceeded 5% due to saturation (timeouts/503s, not a logic bug), edit the Task-5 `options` block: change both `target: 50` to `target: 30` (then `20` if needed), commit (`fix(k6): calibrate SLO hold to 30 VUs for kind capacity`), and re-run `make k8s-payment-stress`. The highest hold level that stays under thresholds is the quoted figure.

- [ ] **Step 6: (Optional) capture a Grafana screenshot** of dashboard #19665 for the run window.

---

## Self-Review notes (already applied)

- **Spec coverage:** users-only seed SQL (T1) ✓; `06-perftest-seed` Job (T2) ✓; Makefile seed target + bootstrap wiring (T3) ✓; payment-stress fire/tail targets (T4) ✓; SLO options (T5) ✓; real PRODUCT_IDS (T6) ✓; cleanup of unused k6 surfaces (T7, added per user request) ✓; Phase 0 bootstrap + dry-run gate (T8) ✓; SLO run + read incl. HPA story (T9) ✓.
- **Divergences from spec (intentional, noted):** (a) seed SQL relocated from `k6-tests/setup/` into the Job dir `k8s/infra/jobs/06-perftest-seed/` — makes it in-tree so the kustomization generator + `apply -k` work cleanly; (b) the spec's "out of scope" browse-Job and host-scenario items are now **in scope as deletions** per the user's cleanup request.
- **No placeholders:** every file has full literal content; every command has expected output; product IDs are concrete.
- **Consistency:** configMap names (`perftest-seed-scripts`/`perftest-seed-sql`, `k6-payment-script`), Job names (`perftest-seed`, `k6-payment-stress`), label selector (`app=k6-payment-stress`), and k6 tag names (`login`, `create_payment`) match across the Job YAML, Makefile targets, and threshold selectors. The `.PHONY` line is extended in T4 and trimmed in T7 against its exact post-T4 text.
```
