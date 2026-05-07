# core-routing-db

Master/slave MySQL routing. The mechanism behind every service that has separate `repository/master/` and `repository/slave/` packages.

## Layout
- `configuration/` — datasource routing logic, `@EnableRoutingDatasource` annotation, transaction manager wiring

## How it works
A service annotates its main class (or a config class) with `@EnableRoutingDatasource`. Two `EntityManagerFactory` beans get created:
- `MasterEntityFactoryConfiguration` — scans `repository/master/`, routes to master DB (writes)
- `SlaveEntityFactoryConfiguration` — scans `repository/slave/`, routes to slave DBs (reads)

**Repository placement is the routing signal.** A repo in `repository/master/` writes; in `repository/slave/` reads. Don't put both annotations on one repo, don't cross packages.

## Slaves
Two slave instances (3307, 3308) — load-balanced via Spring + GTID replication. Failover is handled at the datasource level.

## When NOT to use this module
- Mongo-backed services (product-service, parts of orchestrator) — Mongo handles its own replication.
- Services with no DB at all (gateway, eureka, bff-service, orchestrator HTTP layer).

## Reference services
authorization-server, inventory-service, order-service, payment-service all use this pattern. Mirror their layout when adding a new MySQL-backed service.
