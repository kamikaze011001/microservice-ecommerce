# In-Cluster MySQL 1-Primary/2-Replica Replication — Design Spec

**Date:** 2026-06-06
**Branch:** `feat/mock-paypal-service` (implement here, per user)
**Status:** approved (design)

## Goal

Turn the kind cluster's single-pod MySQL into **1 primary + 2 replicas with real
GTID async replication**, matching the proven `docker/mysql.yml` topology — so
the app's existing read/write split (writes→`mysql`, reads→`mysql-replica`)
actually hits separate nodes. **Local kind only**; the AWS overlay keeps using
managed RDS (unchanged).

## Why this is small

The architecture already anticipates it:
- Two Services exist: `mysql` (writes, `component=primary`) and `mysql-replica`
  (reads) — the latter has a comment: *"when we add a true replica, change the
  selector."*
- Vault already wires `spring.datasource.master.url→mysql`,
  `slave1.url`/`slave2.url→mysql-replica` (`k8s/infra/jobs/03-vault-seed/seed.sh`).
  The app's `SlaveDatasourceRouting` already round-robins `slave1`/`slave2`.
- `docker/mysql.yml` + `docker/scripts/init-mysql.sh` are the proven recipe
  (GTID, `server-id` 1/2/3, `SOURCE_AUTO_POSITION=1`, `repl_user`).

So: **no app change, no Vault change.** Only infra manifests + `install.sh`.

## Approach (chosen: A — separate primary + replica StatefulSets)

Keep the existing `mysql` StatefulSet as the primary (`replicas:1`). Add a new
`mysql-replica` StatefulSet (`replicas:2`). Repoint the existing `mysql-replica`
read Service at the replica pods. Establish replication from inside
`install.sh` (it already applies the manifests and waits for rollout, and runs
*before* `k8s-apps`/seeds — the right ordering).

Rejected: **B** single `replicas:3` StatefulSet with ordinal roles (needs RBAC +
per-pod label patching so the read/write Services select correctly — reworks
existing labels for no benefit here); **C** a MySQL operator (heavy new
dependency for a local kind dev cluster; Bitnami was already removed for weight).

## Components (create / modify)

### Modify

1. **`k8s/infra/manifests/mysql.yaml`** (primary)
   - Add GTID/binlog server args (mirroring `docker/mysql.yml` master, trimmed to
     essentials): `--server-id=1 --log-bin=mysql-bin --binlog-format=row
     --gtid-mode=ON --enforce-gtid-consistency=ON` (keep the existing
     `--default-authentication-plugin=mysql_native_password`).
   - Add replication creds to the `mysql-credentials` Secret:
     `MYSQL_REPL_USER: repl_user`, `MYSQL_REPL_PASSWORD: replica_ecommerce`
     (matching `docker/.env` defaults). The `repl_user` itself is created on the
     primary by `install.sh` (post-init, so it replicates).

2. **`k8s/infra/manifests/mysql-replica-service.yaml`** (read Service)
   - Change selector `app.kubernetes.io/component: primary` → `replica`. This is
     the one-line "flip the selector" the existing comment describes. It now
     load-balances reads across the 2 replica pods.

3. **`k8s/infra/install.sh`**
   - Apply the new `mysql-replica.yaml`; wait
     `kubectl -n infra rollout status statefulset/mysql-replica`.
   - Establish replication (idempotent), mirroring `init-mysql.sh`:
     - On the primary: `CREATE USER IF NOT EXISTS repl_user ...; GRANT
       REPLICATION SLAVE; FLUSH PRIVILEGES` (via `kubectl exec` into `mysql-0`).
     - On each replica pod (`mysql-replica-0`, `mysql-replica-1`): if not already
       replicating, `CHANGE REPLICATION SOURCE TO
       SOURCE_HOST='mysql.infra.svc.cluster.local', SOURCE_USER='repl_user',
       SOURCE_PASSWORD='replica_ecommerce', SOURCE_AUTO_POSITION=1; START REPLICA;`
       then verify `Replica_IO_Running=Yes` & `Replica_SQL_Running=Yes` (fail the
       install if not).

### Create

4. **`k8s/infra/manifests/mysql-replica.yaml`**
   - **Headless Service** `mysql-replica-headless` (`clusterIP: None`,
     selector `component=replica`) — the StatefulSet's governing service for
     stable per-pod identity.
   - **StatefulSet** `mysql-replica` (`replicas:2`, `serviceName:
     mysql-replica-headless`, labels `app.kubernetes.io/name: mysql`,
     `component: replica`):
     - `image: mysql:8.0.40`; `envFrom: mysql-credentials` (same root password +
       `MYSQL_DATABASE=ecommerce_dev`, so the replicated `CREATE TABLE` DDL has
       its database — the entrypoint's DB/user creation is `SQL_LOG_BIN=0`, hence
       not replicated, so the replica must create the empty DB itself).
     - Server args: `--log-bin=mysql-bin --binlog-format=row --gtid-mode=ON
       --enforce-gtid-consistency=ON --default-authentication-plugin=mysql_native_password
       --skip-slave-start=1 --read-only=ON --replica-parallel-workers=4
       --replica-parallel-type=LOGICAL_CLOCK --replica-preserve-commit-order=ON`.
     - **`server-id` per pod**: an `initContainer` derives it from the pod ordinal
       (`server-id = 100 + ordinal`) and writes `/etc/mysql/conf.d/server-id.cnf`
       into a shared `emptyDir` mounted at `/etc/mysql/conf.d` (the official
       image `!includedir`s that dir).
     - liveness/readiness: `mysqladmin ping -uroot -proot` (as primary).
     - `volumeClaimTemplates`: `data` 4Gi `ReadWriteOnce` (one PVC per replica).
     - resources: requests `cpu 200m / mem 512Mi`, limits `cpu 1000m / mem 1Gi`
       (as primary).

## Data flow & bootstrap ordering

`make k8s-infra` → `install.sh`: apply manifests (primary + replicas) → wait both
StatefulSets Ready → create `repl_user` on primary → `CHANGE REPLICATION SOURCE` +
`START REPLICA` on both replicas (GTID auto-position from empty). This runs
**before** `k8s-apps` (services create tables on the primary) and before the seed
Jobs — so all table DDL and seed rows replicate to both replicas. Reads then flow
`mysql-replica` ClusterIP → round-robin the 2 replica pods.

Because replicas start empty with `SOURCE_AUTO_POSITION=1`, no xtrabackup/clone is
needed — the replicas pull the full binlog history (same approach as docker).

## Error handling / risks

- **Replication doesn't converge** → `install.sh` verifies `Replica_IO/SQL_Running`
  and exits non-zero with the failing `SHOW REPLICA STATUS` lines, failing
  `make k8s-infra` loudly (don't seed on a broken topology).
- **Re-run / existing data** (`make k8s-infra` on a live cluster): replication
  setup is idempotent — `CREATE USER IF NOT EXISTS`; skip `CHANGE SOURCE` if the
  replica already reports running. Replica config + relay logs persist across pod
  restarts; `START REPLICA` auto-resumes via GTID.
- **Read-only enforcement**: replicas run `--read-only=ON` (not
  `super-read-only`), matching docker — the app connects as `root`, which bypasses
  `read-only`, so reads keep working and replication is unaffected. If a service
  ever issued a *write* via its slave datasource it would now hit a real read-only
  node; today that's masked because slaves point at the primary. Surfacing it is
  arguably correct, but flagged.
- **Resources**: 3 MySQL pods ≈ 1.5Gi RAM requested + 12Gi PVC on the kind node.
  Acceptable on a dev laptop; noted.

## Testing / acceptance

1. `make k8s-infra` completes; `kubectl -n infra get pods` shows `mysql-0`,
   `mysql-replica-0`, `mysql-replica-1` all Ready.
2. On each replica: `SHOW REPLICA STATUS\G` → `Replica_IO_Running: Yes`,
   `Replica_SQL_Running: Yes`, `Seconds_Behind_Source: 0`.
3. After a full `make k8s-bootstrap`: row counts on a replica match the primary
   (e.g. `SELECT COUNT(*) FROM ecommerce_dev.account` equal on `mysql-0` and
   `mysql-replica-0`), proving DDL + seed data replicated.
4. The `mysql-replica` Service has 2 endpoints (`kubectl -n infra get endpoints
   mysql-replica` shows 2 pod IPs).

## Out of scope

- Automatic failover / primary promotion (no operator).
- The AWS overlay (RDS handles HA there).
- Any app code or Vault config change.
- Changing the primary StatefulSet's governing service to headless (pre-existing;
  works at `replicas:1`).
