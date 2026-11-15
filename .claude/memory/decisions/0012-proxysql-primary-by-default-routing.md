---
name: 0012-proxysql-primary-by-default-routing
description: Replace package-based master/slave + Atomikos XA with one datasource → ProxySQL; primary by default, replica only via @ReplicaRead
metadata: { type: decision, date: 2026-10-11 }
---
MySQL read/write routing moves out of the services and into **ProxySQL**:

- **One datasource per service:** one HikariCP datasource → ProxySQL, one EntityManagerFactory, `JpaTransactionManager`.
- **Deleted:** Atomikos/XA, the `repository/master` + `repository/slave` split, `ReadOnlySlaveInterceptor`, `SlaveDatasourceRouting`, `core-routing-db`.
- **Primary by default.** A read goes to a replica only when its method carries `@ReplicaRead`, meaning it passed the checklist:
  - its result never decides a write;
  - it is not load→mutate→save;
  - it is not a read right after the same user's write;
  - it is not about money, stock, or security.
- **Hint path:**
  - An aspect sets a thread-local flag.
  - A Hibernate `StatementInspector` prefixes `/* replica */` to each SELECT.
  - A ProxySQL query rule sends tagged SELECTs to the replica hostgroup (20); everything else goes to the writer hostgroup (10).
  - `@ReplicaRead` inside a read-write transaction **throws**.
- **Replica reads at launch:**
  - inventory `list`, for display only (checkout uses a new primary `listForCheckout` gRPC method);
  - order `list`, with its N+1 fixed;
  - auth `filter`;
  - auth `validateRoleList`.
- **ProxySQL itself:**
  - Central, in `infra`: 2 replicas, cluster-synced. A single container in compose.
  - `max_replication_lag` = 5 s; the primary sits in the reader group at low weight as a fallback.
  - `transaction_persistent=1`.
  - Config is generated from the canonical secrets pipeline.
  - Metrics: hostgroup traffic, lag and shunned replicas in VictoriaMetrics + Grafana, with an alert when lag > 5 s.
- **Out of scope:** primary failover (CLAUDE.md's "automatic failover" claim was never true and gets corrected), and any cache.

**Why:**
- Routing by Java package forced XA, because one `@Transactional` spanned two EMFs. That in turn forced the interceptor and the pool tuning.
- It also made stale reads easy to write: four services still had live read-after-write bugs (auth activate, inventory double insert, order cancel/get, payment status) after half a dozen one-off fixes.
- Primary-by-default removes that bug class by construction. Replica reads become a deliberate, greppable choice.
- A cache for lag was rejected: it is a third copy with its own invalidation bugs (cf. the Redis-index inventory bug, PR #81). Routing fixes the cause.
- Mapping performance: the primary-routed reads are PK or unique-index lookups. The real load is the inventory stock sums and order history, which go to replicas.

**How to apply:**
- Rollout is one PR per step:
  1. ProxySQL infra + the `@ReplicaRead` core;
  2. payment;
  3. inventory;
  4. order;
  5. auth;
  6. delete `core-routing-db`/Atomikos + fix CLAUDE.md.
- Prove each step with `make db-lag-proof`: 10 s `SOURCE_DELAY` on the shared replicas, time-boxed and restored by a `trap`. Expect FAIL on old images and PASS on new ones, plus ProxySQL hostgroup stats.
- Coworking split: the user writes the routing core and the payment migration; Claude does the infra, the proof and the other services, for review.
- Related: [[0009-kafka-consumer-scaling-design]], [[0011-devbox-local-gitops-platform]].
