# HANDOFF — microservice-ecommerce — 2026-07-24

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first — write it so anyone grasps "where we are, what's next" in 10 seconds.

## Current goal
**Deploy the full stack LIVE to AWS EKS and walk the saga end-to-end** at
`https://shop.microecom.click` (HTTPS + Route53 domain, Phase 5b). Branch:
`feat/aws-live-deploy` (cut off `main`, which already contains all AWS code — the repo
squash-merges so `git branch --merged` false-negatives; don't trust it).

Acct `583178372344` / `ap-southeast-1` / profile `microecom`. State bucket + 11 ECR repos persist
across teardown (`aws/bootstrap` stack). `microecom.click.` hosted zone is registered and live.

## Where we are RIGHT NOW (mid bring-up)
`make aws-all` got to **Step 3/9 and died** at `rollout status statefulset/mongodb` — root cause was
the **gp3 StorageClass gap** (see below), now fixed. Live cluster `microecom-eks` currently has:
- ESO (+ webhook + cert-controller) **Running**, ClusterSecretStore created
- `mongodb-0` **2/2**, `kafka-0` **1/1**, both PVCs **Bound on gp3** (gp2 demoted)
- **MISSING (Step 3 tail, script died before applying):** schema-registry, kafka-connect,
  VictoriaMetrics, Grafana, CDC connector
- **MISSING (Steps 4–9 never ran):** mongo seed, secrets seed, `apps` namespace (all 11 JVM apps),
  RDS account/inventory seed, S3 image seed

## In progress / Next steps
1. **RESUME THE BRING-UP — USER runs `make aws-all`** (billed; user runs all billed cmds himself).
   Fully idempotent: terraform=no-op, image push=skips existing, Step 3 mongo/kafka rollout passes
   instantly then applies the SR→Connect→VM→Grafana→CDC tail, then Steps 4–9 run first time.
   **Watch Step 6 (apps):** `rollout status deploy/{authorization-server,inventory-service}` @ 600s —
   cold ECR pulls on Graviton are slow. If it stalls THERE, get the output, don't re-run blind.
2. **Then open `https://shop.microecom.click`** and walk the full saga: browse → login → cart →
   checkout → mock-PayPal approve → payment captured → order COMPLETED. Fix any parity gaps vs local.
3. **Teardown when done:** `make aws-down` then `make aws-leak-check` (ALB/NAT/EIP/EBS/EKS).

## Done this session (settled, do not redo)
- **Durable fix — gp3 SC wired into `scripts/aws/infra-up.sh`** (after namespace creation, before any
  PVC). This is THE fix for the Step-3 stall; a fresh cluster will never hit it again. See
  [[eks-gp3-storageclass-must-precede-pvcs]]. Live cluster was also hot-patched (RetroactiveDefaultSC
  bound the pending PVCs).
- **`aws/main/rds.tf` replica fix persisted** (lines 127–128: `create_db_*_group = false`). Verified on
  disk — won't regress on next teardown/up. See [[rds-replica-inherits-source-parameter-groups]].
- **`aws/main/terraform.tfvars`** has `db_master_password` (was missing; up-all.sh Step 0 hard-fails
  without it). gitignored.

## Settled decisions + rationale
- **Resume with full `make aws-all`, not a partial step** — every step is idempotent, so one command
  is the safest resume with zero risk of running Steps 4–9 out of order.
- **`set -euo pipefail` + `rollout status --timeout` is correct fail-fast** — one stalled statefulset
  SHOULD abort the script. The bug was the missing SC, not the guard. Don't loosen the guard.
- Topology = "B+ Hybrid" (managed RDS/ElastiCache/S3/Secrets + self-hosted Kafka/Mongo/observability).
  Full rationale in `docs/superpowers/specs/2026-06-10-aws-deployment-design.md`.

## Context to Load (paths only, do NOT paste contents)
- `.claude/memory/conventions/eks-gp3-storageclass-must-precede-pvcs.md` — the Step-3 stall root cause + fix
- `.claude/memory/conventions/rds-replica-inherits-source-parameter-groups.md` — the RDS replica apply fix
- `scripts/aws/RUNBOOK.md` — the authoritative 9-step manual bring-up sequence + verify commands
- `scripts/aws/up-all.sh` — orchestrates all 9 steps (Step 0 preflight needs db_master_password)
- `scripts/aws/infra-up.sh` — Step 3; now carries the gp3 SC apply (lines ~37-48)
- `docs/superpowers/specs/2026-06-10-aws-deployment-design.md` — the whole AWS design + phased path

## Blocked / Needs user input
- Nothing blocking. Waiting on the user to run `make aws-all` to resume (Step 3 tail → Step 9).

## Uncommitted (working tree, branch feat/aws-live-deploy)
- `scripts/aws/infra-up.sh` (gp3 fix), `aws/main/rds.tf` (replica fix), `.claude/memory/HANDOFF.md`.
  User asked to decide commit-now vs after-saga — pending his call. `terraform.tfvars` is gitignored.
