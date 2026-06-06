# In-Cluster MySQL 1-Primary/2-Replica Replication — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the kind cluster's MySQL a real **1 primary + 2 replicas** with GTID async replication, so the app's existing read/write split (writes→`mysql`, reads→`mysql-replica`) hits separate nodes.

**Architecture:** Keep the existing `mysql` StatefulSet as the primary; add a `mysql-replica` StatefulSet (`replicas:2`); flip the existing `mysql-replica` read Service selector to the replicas; establish GTID replication (`SOURCE_AUTO_POSITION=1`) from inside `k8s/infra/install.sh` after both StatefulSets are Ready — mirroring the proven `docker/scripts/init-mysql.sh`. No app or Vault change.

**Tech Stack:** kind (local k8s), kubectl, MySQL 8.0.40 (GTID replication), bash (`install.sh`).

**Spec:** `docs/superpowers/specs/2026-06-06-mysql-incluster-replication-design.md`

**Branch:** implement on `feat/mock-paypal-service` (per user).

---

## Context the engineer needs (read before starting)

- **Why no app/Vault change:** Vault already wires `spring.datasource.master.url→mysql.infra…`, `slave1.url`/`slave2.url→mysql-replica.infra…` (`k8s/infra/jobs/03-vault-seed/seed.sh`). The app's `core-routing-db` round-robins `slave1`/`slave2`. We only make `mysql-replica` resolve to real replica pods.
- **The proven recipe:** `docker/mysql.yml` (server flags) + `docker/scripts/init-mysql.sh` (GTID `SOURCE_AUTO_POSITION=1`, `repl_user` with `REPLICATION SLAVE`). We mirror it.
- **Why GTID-from-empty works:** replicas start empty with `SOURCE_AUTO_POSITION=1` and pull the full binlog; the official MySQL entrypoint wraps its first-init SQL (DB/user/root creation) in `SET SQL_LOG_BIN=0`, so that is NOT replicated — which is why each replica must keep `MYSQL_DATABASE=ecommerce_dev` (creates the empty DB locally so the replicated `CREATE TABLE … ecommerce_dev.x` DDL has its database). Only post-init application transactions (Hibernate DDL on the primary + seed INSERTs) replicate.
- **Ordering:** `make k8s-infra` runs `install.sh`, which applies infra manifests, waits for rollout, and runs **before** `k8s-apps` (services create tables on the primary) and the seed Jobs. Establishing replication there means all DDL + seed data replicate.
- **`--read-only=ON` (not `super-read-only`)** matches docker; the app connects as `root`, which bypasses `read-only`, so reads work and replication is unaffected.
- **Pod names:** the primary StatefulSet `mysql` → pod `mysql-0`; the new `mysql-replica` StatefulSet → pods `mysql-replica-0`, `mysql-replica-1`. The bootstrap addresses them by name via `kubectl exec`.
- **Validation without a cluster:** these manifests are applied via `kubectl apply -f` (not kustomize). Use `kubectl apply --dry-run=client -f <file>` for schema validation; if no kube context is available, fall back to `python3 -c "import yaml; list(yaml.safe_load_all(open('<file>')))"`. Shell: `bash -n` / `shellcheck`.

---

## File Structure

| File | Responsibility |
|---|---|
| `k8s/infra/manifests/mysql.yaml` *(modify)* | Primary: add GTID/binlog server flags; add `MYSQL_REPL_USER`/`MYSQL_REPL_PASSWORD` to the `mysql-credentials` Secret. |
| `k8s/infra/manifests/mysql-replica.yaml` *(new)* | Headless Service `mysql-replica-headless` + `mysql-replica` StatefulSet (`replicas:2`, GTID, read-only, per-pod `server-id` via initContainer, PVC each). |
| `k8s/infra/manifests/mysql-replica-service.yaml` *(modify)* | Flip the read Service selector `component: primary` → `replica`. |
| `k8s/infra/install.sh` *(modify)* | Apply the replica manifest; wait for its rollout; establish + verify GTID replication (idempotent), mirroring `init-mysql.sh`. |

---

## Task 1: Primary GTID/binlog config + replication creds

**Files:**
- Modify: `k8s/infra/manifests/mysql.yaml`

- [ ] **Step 1: Add replication creds to the `mysql-credentials` Secret**

In the `Secret` `stringData:` block, find:
```yaml
stringData:
  MYSQL_ROOT_PASSWORD: root
  MYSQL_DATABASE: ecommerce_dev
  MYSQL_USER: ecommerce
  MYSQL_PASSWORD: ecommerce
```
Replace with (adds two keys; matches `docker/.env` defaults):
```yaml
stringData:
  MYSQL_ROOT_PASSWORD: root
  MYSQL_DATABASE: ecommerce_dev
  MYSQL_USER: ecommerce
  MYSQL_PASSWORD: ecommerce
  MYSQL_REPL_USER: repl_user
  MYSQL_REPL_PASSWORD: replica_ecommerce
```

- [ ] **Step 2: Add GTID/binlog server flags to the primary container**

In the primary StatefulSet's container, find:
```yaml
          args:
            - --default-authentication-plugin=mysql_native_password
```
Replace with (server-id=1 marks this as the replication source):
```yaml
          args:
            - --server-id=1
            - --log-bin=mysql-bin
            - --binlog-format=row
            - --gtid-mode=ON
            - --enforce-gtid-consistency=ON
            - --default-authentication-plugin=mysql_native_password
```

- [ ] **Step 3: Update the primary's header comment (optional but accurate)**

Find the comment line near the top:
```yaml
# Topology: ONE pod. The app's core-routing-db wires master + slave1/slave2
# datasources, but the slaves resolve via the `mysql-replica` Service which
# (today) selects this same pod — no real replication locally. The `mysql`
# Service (writes) and `mysql-replica` Service (reads, in
# mysql-replica-service.yaml) both target the label
# app.kubernetes.io/name=mysql,component=primary below.
```
Replace with:
```yaml
# Topology: PRIMARY of a 1-primary/2-replica GTID setup. server-id=1 + log-bin
# + gtid-mode make this the replication source; replicas live in
# mysql-replica.yaml and replicate via SOURCE_AUTO_POSITION=1 (configured by
# install.sh). The `mysql` Service (writes) selects this component=primary pod;
# the `mysql-replica` Service (reads, mysql-replica-service.yaml) selects the
# component=replica pods.
```

- [ ] **Step 4: Validate the manifest**

Run: `kubectl apply --dry-run=client -f k8s/infra/manifests/mysql.yaml -o name 2>&1 || python3 -c "import yaml; list(yaml.safe_load_all(open('k8s/infra/manifests/mysql.yaml'))); print('YAML OK')"`
Expected: prints the resource names (secret/mysql-credentials, service/mysql, statefulset/mysql) — or `YAML OK` offline.

- [ ] **Step 5: Confirm the flags are present**

Run: `grep -nE "server-id=1|gtid-mode=ON|MYSQL_REPL_USER" k8s/infra/manifests/mysql.yaml`
Expected: three matches (the server-id, gtid-mode, and the repl user secret key).

- [ ] **Step 6: Commit**

```bash
git add k8s/infra/manifests/mysql.yaml
git commit -m "feat(k8s): primary MySQL GTID/binlog config + replication creds

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Replica StatefulSet + headless Service

**Files:**
- Create: `k8s/infra/manifests/mysql-replica.yaml`

- [ ] **Step 1: Create the manifest**

```yaml
# MySQL read replicas — 2 pods replicating from the primary (mysql.yaml) via
# GTID auto-position. Brings the kind cluster in line with docker/mysql.yml's
# 1-master/2-slave topology. Replication is established by k8s/infra/install.sh
# after both StatefulSets are Ready (mirrors docker/scripts/init-mysql.sh).
#
# The read Service `mysql-replica` (mysql-replica-service.yaml) selects these
# component=replica pods and load-balances reads across them. This headless
# Service is the StatefulSet's governing service for stable per-pod identity.
#
# LOCAL-DEV ONLY: same plaintext creds as the primary (mysql-credentials). The
# AWS overlay replaces MySQL with RDS, so this file is local-only.
---
apiVersion: v1
kind: Service
metadata:
  name: mysql-replica-headless
  namespace: infra
  labels:
    app.kubernetes.io/name: mysql
    app.kubernetes.io/component: replica
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: mysql
    app.kubernetes.io/component: replica
  ports:
    - name: mysql
      port: 3306
      targetPort: mysql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql-replica
  namespace: infra
  labels:
    app.kubernetes.io/name: mysql
    app.kubernetes.io/component: replica
spec:
  serviceName: mysql-replica-headless
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: mysql
      app.kubernetes.io/component: replica
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mysql
        app.kubernetes.io/component: replica
    spec:
      initContainers:
        # Derive a unique server-id per replica from the StatefulSet pod ordinal
        # (mysql-replica-0 -> 100, mysql-replica-1 -> 101). Copy the image's
        # default conf.d (keeps docker.cnf: skip-host-cache/skip-name-resolve)
        # into the shared volume, then append our server-id snippet. The official
        # image !includedir's /etc/mysql/conf.d, so it is picked up at boot.
        - name: server-id
          image: mysql:8.0.40
          command:
            - sh
            - -c
            - |
              cp -a /etc/mysql/conf.d/. /mnt/conf/ 2>/dev/null || true
              ORD="${HOSTNAME##*-}"
              printf '[mysqld]\nserver-id=%s\n' "$((100 + ORD))" > /mnt/conf/server-id.cnf
              echo "wrote server-id=$((100 + ORD))"
          volumeMounts:
            - name: conf
              mountPath: /mnt/conf
      containers:
        - name: mysql
          image: mysql:8.0.40
          ports:
            - name: mysql
              containerPort: 3306
          # ONLY root password + database — NOT MYSQL_USER/MYSQL_PASSWORD. The
          # mysql entrypoint binlogs a non-idempotent `CREATE USER '<MYSQL_USER>'`
          # (outside its SET SQL_LOG_BIN=0 block); if the replica creates that
          # user locally too, replaying the primary's CREATE USER stops the SQL
          # thread. The app user arrives via replication; app reads as root.
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: MYSQL_ROOT_PASSWORD
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: MYSQL_DATABASE
          # No --server-id here: it comes from /etc/mysql/conf.d/server-id.cnf
          # written per-pod by the initContainer. --skip-slave-start: install.sh
          # configures CHANGE REPLICATION SOURCE then START REPLICA explicitly.
          args:
            - --log-bin=mysql-bin
            - --binlog-format=row
            - --gtid-mode=ON
            - --enforce-gtid-consistency=ON
            - --default-authentication-plugin=mysql_native_password
            - --skip-slave-start=1
            - --read-only=ON
            - --replica-parallel-workers=4
            - --replica-parallel-type=LOGICAL_CLOCK
            - --replica-preserve-commit-order=ON
          volumeMounts:
            - name: data
              mountPath: /var/lib/mysql
            - name: conf
              mountPath: /etc/mysql/conf.d
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { cpu: 1000m, memory: 1Gi }
          livenessProbe:
            exec:
              command: ["mysqladmin", "ping", "-uroot", "-proot"]
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            exec:
              command: ["mysqladmin", "ping", "-uroot", "-proot"]
            initialDelaySeconds: 15
            periodSeconds: 5
            timeoutSeconds: 3
      volumes:
        - name: conf
          emptyDir: {}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 4Gi
```

- [ ] **Step 2: Validate the manifest**

Run: `kubectl apply --dry-run=client -f k8s/infra/manifests/mysql-replica.yaml -o name 2>&1 || python3 -c "import yaml; list(yaml.safe_load_all(open('k8s/infra/manifests/mysql-replica.yaml'))); print('YAML OK')"`
Expected: prints `service/mysql-replica-headless` and `statefulset/mysql-replica` — or `YAML OK` offline.

- [ ] **Step 3: Confirm label/selector consistency**

Run: `grep -nE "component: replica|serviceName: mysql-replica-headless|replicas: 2|skip-slave-start|read-only=ON" k8s/infra/manifests/mysql-replica.yaml`
Expected: matches for the replica component label, the headless governing service, `replicas: 2`, `--skip-slave-start=1`, and `--read-only=ON`.

- [ ] **Step 4: Commit**

```bash
git add k8s/infra/manifests/mysql-replica.yaml
git commit -m "feat(k8s): mysql-replica StatefulSet (2 replicas) + headless service

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Flip the read Service to the replicas

**Files:**
- Modify: `k8s/infra/manifests/mysql-replica-service.yaml`

- [ ] **Step 1: Repoint the selector**

Find:
```yaml
# Aliased Service so app DSNs use mysql-primary (writes) and mysql-replica (reads).
# Today both point at the same Pod. When we add a true replica, we change the
# selector on this Service without touching app config.
apiVersion: v1
kind: Service
metadata:
  name: mysql-replica
  namespace: infra
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mysql
    app.kubernetes.io/component: primary
  ports:
    - name: mysql
      port: 3306
      targetPort: mysql
```
Replace with (only the comment + the `component` selector change):
```yaml
# Read Service: app slave1/slave2 DSNs resolve here (see vault-seed). Selects the
# component=replica pods (mysql-replica.yaml) and load-balances reads across the
# 2 replicas. Writes go to the separate `mysql` Service (component=primary).
apiVersion: v1
kind: Service
metadata:
  name: mysql-replica
  namespace: infra
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mysql
    app.kubernetes.io/component: replica
  ports:
    - name: mysql
      port: 3306
      targetPort: mysql
```

- [ ] **Step 2: Validate**

Run: `grep -n "component: replica" k8s/infra/manifests/mysql-replica-service.yaml && kubectl apply --dry-run=client -f k8s/infra/manifests/mysql-replica-service.yaml -o name 2>&1 || python3 -c "import yaml; yaml.safe_load(open('k8s/infra/manifests/mysql-replica-service.yaml')); print('YAML OK')"`
Expected: the `component: replica` line matches; dry-run prints `service/mysql-replica` (or `YAML OK` offline).

- [ ] **Step 3: Commit**

```bash
git add k8s/infra/manifests/mysql-replica-service.yaml
git commit -m "feat(k8s): point mysql-replica read Service at the replica pods

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Apply replicas + establish replication in install.sh

**Files:**
- Modify: `k8s/infra/install.sh`

- [ ] **Step 1: Apply the replica manifest alongside the others**

Find the `kubectl apply` block:
```bash
kubectl apply \
  -f "$MANIFESTS/mysql.yaml" \
  -f "$MANIFESTS/mysql-replica-service.yaml" \
  -f "$MANIFESTS/mongodb.yaml" \
```
Replace with (adds the replica StatefulSet manifest):
```bash
kubectl apply \
  -f "$MANIFESTS/mysql.yaml" \
  -f "$MANIFESTS/mysql-replica-service.yaml" \
  -f "$MANIFESTS/mysql-replica.yaml" \
  -f "$MANIFESTS/mongodb.yaml" \
```

- [ ] **Step 2: Wait for the replica StatefulSet rollout**

Find:
```bash
kubectl -n infra rollout status statefulset/mysql   --timeout=5m
kubectl -n infra rollout status statefulset/mongodb --timeout=5m
```
Replace with (adds the replica wait right after the primary):
```bash
kubectl -n infra rollout status statefulset/mysql         --timeout=5m
kubectl -n infra rollout status statefulset/mysql-replica --timeout=5m
kubectl -n infra rollout status statefulset/mongodb       --timeout=5m
```

- [ ] **Step 3: Add the replication setup block**

Immediately AFTER the five `rollout status` lines (i.e. after the `statefulset/kafka` rollout line) and BEFORE the `helm upgrade --install vault` line, insert:

```bash
# ── MySQL replication: 1 primary + 2 replicas (GTID auto-position) ────────────
# Mirrors docker/scripts/init-mysql.sh, idempotent. The repl user is created on
# the primary AFTER init (so it replicates); replicas use SOURCE_AUTO_POSITION=1
# to pull the full binlog from empty (no clone needed). This runs before the JVM
# services (k8s-apps) and the seed Jobs, so all table DDL + seed rows replicate.
REPL_USER=repl_user
REPL_PASS=replica_ecommerce
PRIMARY_HOST=mysql.infra.svc.cluster.local

echo "configuring replication user on primary (mysql-0)"
kubectl -n infra exec mysql-0 -- mysql -uroot -proot -e "
  CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${REPL_PASS}';
  GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
  FLUSH PRIVILEGES;"

for rep in mysql-replica-0 mysql-replica-1; do
  running=$(kubectl -n infra exec "$rep" -- mysql -uroot -proot -N -e \
    "SELECT COUNT(*) FROM performance_schema.replication_connection_status WHERE SERVICE_STATE='ON';" 2>/dev/null || echo 0)
  if [ "${running:-0}" -ge 1 ]; then
    echo "$rep already replicating; skipping"
    continue
  fi
  echo "starting replication on $rep"
  kubectl -n infra exec "$rep" -- mysql -uroot -proot -e "
    STOP REPLICA;
    CHANGE REPLICATION SOURCE TO
      SOURCE_HOST='${PRIMARY_HOST}',
      SOURCE_USER='${REPL_USER}',
      SOURCE_PASSWORD='${REPL_PASS}',
      SOURCE_AUTO_POSITION=1,
      GET_SOURCE_PUBLIC_KEY=1;
    START REPLICA;"
done

# Verify both replicas are actually replicating; fail the install if not (don't
# seed onto a broken topology).
sleep 5
for rep in mysql-replica-0 mysql-replica-1; do
  status=$(kubectl -n infra exec "$rep" -- mysql -uroot -proot -e "SHOW REPLICA STATUS\G")
  if echo "$status" | grep -q "Replica_IO_Running: Yes" && echo "$status" | grep -q "Replica_SQL_Running: Yes"; then
    echo "$rep replication OK"
  else
    echo "ERROR: $rep replication not running:"
    echo "$status" | grep -E "Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:"
    exit 1
  fi
done
echo "MySQL replication ready (1 primary + 2 replicas)"
```

- [ ] **Step 4: Validate the script parses**

Run: `bash -n k8s/infra/install.sh && echo PARSE_OK`
Expected: `PARSE_OK`. (If `shellcheck` is available, also run `shellcheck k8s/infra/install.sh` — pre-existing warnings are fine; ensure no new errors in the added block.)

- [ ] **Step 5: Confirm the wiring**

Run: `grep -nE "mysql-replica.yaml|rollout status statefulset/mysql-replica|CHANGE REPLICATION SOURCE|Replica_IO_Running" k8s/infra/install.sh`
Expected: matches for the apply line, the replica rollout wait, the CHANGE REPLICATION SOURCE, and the verify grep.

- [ ] **Step 6: Commit**

```bash
git add k8s/infra/install.sh
git commit -m "feat(k8s): establish + verify MySQL GTID replication in install.sh

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Live verification (interactive — run on the cluster)

This task runs on the kind cluster. If the cluster is already up, `make k8s-infra`
re-runs `install.sh` (idempotent) to apply the replicas + establish replication;
otherwise a full `make k8s-bootstrap` exercises the whole flow. If a step fails,
switch to `superpowers:systematic-debugging`, fix at the failing layer, commit,
and re-run.

- [ ] **Step 1: Apply infra (or full bootstrap)**

Run: `make k8s-infra`  (or `make k8s-bootstrap` from a clean cluster)
Expected: ends with `MySQL replication ready (1 primary + 2 replicas)` then `infra install complete`.

- [ ] **Step 2: All three MySQL pods Ready**

Run: `kubectl -n infra get pods -l app.kubernetes.io/name=mysql`
Expected: `mysql-0`, `mysql-replica-0`, `mysql-replica-1` all `Running` / `1/1`.

- [ ] **Step 3: Replication healthy on both replicas**

Run:
```bash
for r in mysql-replica-0 mysql-replica-1; do
  echo "== $r =="
  kubectl -n infra exec "$r" -- mysql -uroot -proot -e "SHOW REPLICA STATUS\G" \
    | grep -E "Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_Error:"
done
```
Expected: each shows `Replica_IO_Running: Yes`, `Replica_SQL_Running: Yes`, `Seconds_Behind_Source: 0`, empty `Last_Error`.

- [ ] **Step 4: Read Service has 2 endpoints**

Run: `kubectl -n infra get endpoints mysql-replica`
Expected: the `ENDPOINTS` column lists **two** `:3306` pod IPs (the 2 replicas).

- [ ] **Step 5: Data replicated (after a full bootstrap with seeds)**

Run:
```bash
echo "primary:"; kubectl -n infra exec mysql-0 -- mysql -uroot -proot -N -e "SELECT COUNT(*) FROM ecommerce_dev.account;"
echo "replica0:"; kubectl -n infra exec mysql-replica-0 -- mysql -uroot -proot -N -e "SELECT COUNT(*) FROM ecommerce_dev.account;"
echo "replica1:"; kubectl -n infra exec mysql-replica-1 -- mysql -uroot -proot -N -e "SELECT COUNT(*) FROM ecommerce_dev.account;"
```
Expected: all three counts equal (DDL + seed rows replicated). If you only ran `make k8s-infra` (no apps/seeds yet), the tables may not exist yet — run the full `make k8s-bootstrap` first, or re-check after apps + seeds.

- [ ] **Step 6: Spot-check live replication**

Run:
```bash
kubectl -n infra exec mysql-0 -- mysql -uroot -proot -e \
  "CREATE TABLE IF NOT EXISTS ecommerce_dev._repl_probe(id INT PRIMARY KEY); INSERT INTO ecommerce_dev._repl_probe VALUES (1);"
sleep 2
kubectl -n infra exec mysql-replica-0 -- mysql -uroot -proot -N -e \
  "SELECT COUNT(*) FROM ecommerce_dev._repl_probe;"
kubectl -n infra exec mysql-0 -- mysql -uroot -proot -e "DROP TABLE ecommerce_dev._repl_probe;"
```
Expected: the replica returns `1` (the write propagated), then the probe table is dropped (the DROP also replicates). This proves writes on the primary reach the replicas.

*(No commit — verification only. Commit any defect fix at the layer it was found.)*

---

## Self-Review notes (already applied)

- **Spec coverage:** primary GTID config + repl creds (T1) ✓; replica StatefulSet + headless svc + per-pod server-id + read-only (T2) ✓; read-Service selector flip (T3) ✓; install.sh apply + rollout wait + idempotent replication setup + verify (T4) ✓; live acceptance incl. row-count parity + live-probe (T5) ✓. No app/Vault change (spec "out of scope") — honored.
- **No placeholders:** every file change shows full literal content; every step has a command + expected output.
- **Consistency:** labels `app.kubernetes.io/name: mysql` + `component: replica` match across the replica StatefulSet, headless service, and the flipped read Service. `server-id`: primary `1`, replicas `100/101` (initContainer, ordinal-derived) — unique. Repl creds (`repl_user`/`replica_ecommerce`) match between the Secret (T1) and the `CHANGE REPLICATION SOURCE` in install.sh (T4). Pod names (`mysql-0`, `mysql-replica-0/1`) match the StatefulSet names. `SOURCE_HOST=mysql.infra.svc.cluster.local` = the primary write Service.
