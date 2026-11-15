# HANDOFF

**Updated:** 2026-10-21 · **Branch:** `main` (nothing open) · **Last merged:** PR #87 (volume pinning + request sizing)

## Current goal

Local k8s cluster hardening: DONE. #86 made node allocatable honest ([[a-capped-docker-node-reports-the-whole-vm]]);
#87 pinned all 9 hostpath volumes to their data node and sized MySQL/Kafka requests ([[minikube-hostpath-pvs-are-not-node-pinned]]).
Both are live on `microecom`. No task in progress.

## Done

- **#81:** Redis-loss stock-decrement fix. **#82:** devbox portal.
- **ProxySQL, ADR [[0012-proxysql-primary-by-default-routing]]:**
  - #83: one datasource → ProxySQL, `@ReplicaRead`, Atomikos and `core-routing-db` deleted.
  - #84: `make db-lag-proof`, which holds both replicas 10 s behind while read-your-writes flows run.
  - #85:
    - orchestrator moved to ProxySQL, and the dead master/slave Vault keys dropped;
    - Vault dev-mode limits raised to 512Mi;
    - compose replication init can be re-run;
    - `db-lag-proof env=compose`.
  - Proof 8/8 and Bruno pass on prod-like, preview-ui and compose. Compose is 21/22 on Bruno; the one miss is the env-specific PayPal sandbox link.
- **PR #86 (open):** `reserve_node_memory` in `deploy/scripts/cluster.sh` sets `systemReserved = (VM − cap) + 512Mi`. Result: allocatable and the kubepods cap are both 5632Mi per node; no pod restarted.

## In progress / Next

- Delete the merged local branches `fix/k8s-node-allocatable` and `fix/k8s-pin-volumes` (the user runs `-D`).
- **Optional follow-ups:**
  - m03 is at 90% of what pods can request (5100/5632Mi). Pod limits are still 178% of what m03 can hold; the kubepods cap contains a spike.
  - The Docker VM is nearly full: 4 × 6g of nodes + ~5.4Gi of compose containers on 29.4Gi. `make down` when compose isn't needed.
- **Product decision:** `PATCH /orders/{id}:cancel` only cancels the payment attempt. The order stays PROCESSING until the pending-order entry expires (~24 h).

## Settled decisions

- [[0012-proxysql-primary-by-default-routing]]: primary by default; a replica only via `@ReplicaRead`.
- [[0011-devbox-local-gitops-platform]]; the env repo is in local Gitea, cloned at `deploy/.run/env-config`.
- Only use `--context microecom`; never touch microecom-eks.
- First pushes are done by the user: husky's `core.hooksPath` hides the global gitleaks pre-push hook, so a hook blocks them for Claude.
- Ask before disruptive infra actions: node or kubelet restarts, Vault restarts, volume wipes.

## Context to Load (paths only)

- `deploy/scripts/cluster.sh`
- `deploy/scripts/pin-volumes.sh`
- `scripts/db/db-lag-proof.sh`
- `scripts/db/db-lag-proof.js`
- `deploy/secrets/contexts/k8s.yaml`
- `deploy/charts/microecom/charts/infra/values.yaml`
- `docker/scripts/init-mysql.sh`

## Blocked

- Nothing. Known open items:
  - Vault on k8s is in-memory dev mode: after a restart, run `make secrets-seed ENV=k8s CONTEXT=microecom`.
  - The perftest login users are a k8s-only fixture; compose needs `deploy/k8s-jobs/06-perftest-seed/perftest-users.sql` loaded by hand.
