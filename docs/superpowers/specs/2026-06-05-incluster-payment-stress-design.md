# In-Cluster Payment-Flow Stress Test — Design

**Date:** 2026-06-05
**Status:** Approved
**Branch:** `feat/mock-paypal-service` (continuation — depends on the unmerged mock-paypal-service code)

## Goal

Run the k6 payment-saga stress test **inside the kind cluster** and prove the
system sustains a fixed SLO under load. Produce: a held throughput figure
(VUs / RPS), p95 latencies, error rate, the Grafana k6 dashboard populated, and
an HPA scale-up observation. Primary use: interview preparation — the numbers and
the run must be reliable and explainable.

**Locked SLO bar (calibrated down after one dry run if the laptop kind cluster
saturates):**

- Profile: ramp `0 → 50` VUs over `1m`, **hold 50 VUs for `3m`**, ramp down `30s`.
- Thresholds: `http_req_failed < 0.05`, `checks > 0.95`,
  `p95{name:create_payment} < 2000ms`, `p95{name:login} < 800ms`.
- The held, error-free VU level is the throughput figure to quote.

## Background / current state

Two k6 surfaces already exist for the payment flow:

- **Host:** `k6-tests/scenarios/*.js` → `tests/full-flow.js` against `localhost:6868`.
- **In-cluster (this spec):** k8s Job `k6-payment-stress` running
  `k8s/apps/base/k6-stress/payment-flow.js` against the gateway Service DNS, with
  results streamed to VictoriaMetrics.

Both drive the mock-paypal-service 90/5/5 approve/cancel/fail decision mix.

**Confirmed facts grounding this design:**

- The cluster is a local **kind** cluster (`make k8s-bootstrap`). No kube context
  is currently set → the cluster is torn down → **Phase 0 is a full bootstrap
  from scratch**, which also gives the never-run-live Java-25 mock-paypal k8s
  wiring its first real exercise.
- `k8s-infra` installs **VictoriaMetrics** (`vmsingle` in `monitoring` ns) +
  Grafana with a provisioned **k6 dashboard** (gnetId 19665). The payment Job's
  `experimental-prometheus-rw` sink is real.
- **HPA exists** for `order-service`, `inventory-service`, `product-service`,
  `gateway` — **but not `payment-service`**. The scaling story is: order +
  inventory autoscale under the payment-saga load; payment-service runs at fixed
  replicas (mock-paypal is single-replica by design).
- The `01-mysql-seed` Job connects to `mysql.infra.svc.cluster.local` as root —
  the pattern the new seed Job mirrors.

## The blocking gap

`payment-flow.js` `setup()` logs in `perftest_admin` + `perftest_user_N`. These
users are seeded **nowhere** in the k8s flow — the only occurrence of "perftest"
in the repo is `payment-flow.js` itself. `k6-tests/setup/seed-users.sql` exists
but is host-oriented and never wired into the k8s seed flow. So on first run,
`setup()` fails at admin login ("seed perftest users first").

Worse, `seed-users.sql` is **half wrong for this architecture**:

- **Users half (lines 11–99)** — `account` / `user` / `role` / `account_role`
  inserts. These are authorization-server MySQL tables and are **correct**.
- **Products half (lines 115–128)** — inserts into single-DB `product` +
  `inventory` tables. That is **monolith schema**. In this split architecture the
  catalog lives in **MongoDB** (product-service) and stock in **inventory-service**
  tables (`inventory_product` + `product_quantity_history`). These inserts target
  the wrong/nonexistent tables in-cluster.

**Resolution (decided):**

- **Users:** seed only the valid users-half, via a proper idempotent kustomize
  bootstrap Job (`06-perftest-seed`) wired into `make k8s-bootstrap` — mirroring
  `01-mysql-seed`. (Chosen over a host-side script for repeatability /
  demonstrability.)
- **Products:** do **not** seed test-product-1..3. Point `PRODUCT_IDS` at **real
  catalog products** already seeded from `docker/product.json` (Mongo) and already
  inventoried by `k8s-seed-inventory`. This deletes the schema-mismatch problem
  rather than solving it. Real IDs are resolved post-seed via the PERMIT_ALL
  product browse endpoint and baked into `payment-job.yaml`.

## Components (create / modify)

### Create

1. **`k8s/infra/jobs/06-perftest-seed/perftest-users.sql`** — the users-only
   slice of the old `seed-users.sql` (admin + 100 users + ADMIN/USER role
   assignments). Drops the monolith `product`/`inventory` inserts. Idempotent
   (`INSERT IGNORE` / `ON DUPLICATE KEY UPDATE`). Lives **in the Job dir** (not
   `k6-tests/`, which is deleted — see Cleanup) so it is in-tree and the
   kustomization generator can read it.

2. **`k8s/infra/jobs/06-perftest-seed/`** — `seed.sh` + `job.yaml` +
   `kustomization.yaml`, mirroring `01-mysql-seed` but simpler:
   - `seed.sh`: idempotency guard (skip if `perftest_admin` already present), then
     pipe `perftest-users.sql` into `mysql.infra.svc.cluster.local` as root using
     `MYSQL_ROOT_PASSWORD`.
   - `job.yaml`: namespace `bootstrap`, mounts the SQL + script configmaps.
   - `kustomization.yaml`: since both source files are **in-tree** (unlike
     `01-mysql-seed`, whose data is out-of-tree in `docker/`), the
     `configMapGenerator` reads them directly and the Makefile applies with plain
     `kubectl apply -k` — no imperative-configmap workaround needed.
   - Must run **after** the JPA schema exists (authorization-server has booted and
     `ddl-auto` created `account`/`user`/`role`/`account_role`) — i.e. **after
     `k8s-apps`**, in the same slot as `k8s-seed-mysql` / `k8s-seed-inventory`.

### Modify

3. **`Makefile`**
   - Add `k8s-seed-perftest` target (`kubectl apply -k k8s/infra/jobs/06-perftest-seed`,
     wait for completion) and chain it into `k8s-bootstrap` after `k8s-seed-inventory`.
   - Add `k8s-payment-stress` (delete `k6-payment-stress` Job if present, create the
     `k6-payment-script` configmap imperatively, then `kubectl apply -f payment-job.yaml`
     — **not** `apply -k`, to avoid the browse Job) and `k8s-payment-stress-logs`
     (tail `-l app=k6-payment-stress`). Re-runnable.
   - Remove the superseded `k8s-stress` / `k8s-stress-logs` targets (see Cleanup).

4. **`k8s/apps/base/k6-stress/payment-flow.js`** — replace the current modest
   ramp with the locked SLO `options` (profile + thresholds above); fix the stale
   `k6-tests/setup/seed-users.sql` reference in its header comment.

5. **`k8s/apps/base/k6-stress/payment-job.yaml`** — set `PRODUCT_IDS` to 3 real
   catalog IDs; confirm `BASE_URL=http://gateway.apps.svc.cluster.local:6868` and
   the VM remote-write URL.

### Delete (cleanup — per user request)

The host harness and the in-cluster browse stress are superseded by the
in-cluster payment flow:

6. **`k6-tests/`** (whole tree) — unused host harness: `run.sh`, `scenarios/*`,
   `tests/full-flow.js`, `config.js`, `helpers/*`, `setup/seed-users.sql`.
7. **`k8s/apps/base/k6-stress/script.js`** + **`job.yaml`** (the browse `k6-stress`
   Job) + **`kustomization.yaml`** (unused once the browse Job is gone and the
   payment target applies `payment-job.yaml` directly).
8. Doc/reference scrub in `k8s/README.md` + `mock-paypal-service/README.md`,
   pointing at the in-cluster equivalents.

## Data flow (one VU iteration)

`POST authorization-server/v1/auth:login` → access token →
`POST order-service/v1/orders` (order-service validates stock via gRPC to
inventory-service) → `POST payment-service/v1/payments?orderId=` → mock-paypal
approve link → `GET <approve>?decision=<approve|cancel|fail>` → 302 chain
(`api.microecom.local` rewritten to in-cluster gateway DNS at each hop) →
payment-service success/cancel callback → saga settles via Kafka/orchestrator.
`fail` → HTTP 422 at capture → `PaymentFailed` compensation path.

## Error handling / risks

- **Phase 0 is the real risk.** The Java-25 mock-paypal k8s wiring (overlay
  `base-url` switch, gateway route, vault seed, auth rule) has never run on a live
  cluster. After `make k8s-bootstrap`: verify mock-paypal pod Ready, payment-service
  env points at the mock, gateway route resolves, and **one manual payment saga
  goes green before any load**. Fix whatever surfaces here first.
- If 50 VUs saturates the kind cluster (messy first run), step the hold down to
  30 / 20 VUs. The held error-free number is what gets quoted.
- k6 `-o experimental-prometheus-rw` aborts if the VM endpoint is unreachable —
  verify `vmsingle.monitoring.svc.cluster.local:8428` resolves before the real run.
- Re-running an immutable completed Job errors — both make targets must
  delete-then-apply.

## Testing / acceptance

1. **Bootstrap green:** `make k8s-bootstrap` completes; `k8s-status` shows all
   apps Ready incl. mock-paypal; `06-perftest-seed` Job completes; perftest_admin
   + 100 users present in MySQL.
2. **Dry run:** a single VU iteration completes a full saga green (login →
   order → payment → approve → callback) in-cluster.
3. **SLO run:** thresholds pass at the held VU level; Grafana k6 dashboard shows
   the run; `kubectl -n apps get hpa` shows order/inventory scaling out under load.

## Out of scope

- Adding HPA to `payment-service` (it runs at fixed replicas by design; the
  scaling story comes from `order-service` / `inventory-service`).

> Note: the browse k6 Job's `:8080` `BASE_URL` mismatch and the host
> `k6-tests/scenarios/*` were originally listed out-of-scope; per the user's
> cleanup request they are now **deleted** (see the Delete/cleanup section), so
> the mismatch is moot.
- Adding HPA to payment-service.
