# Cleanup Cut-over — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** finish the k8s Helm cut-over, then delete the duplicate paths it unlocks.

**Architecture:** cut over first, verify live, delete last — in separate commits, because this is the one phase that cannot roll back with "don't call the new target."

**Design spec:** `docs/superpowers/specs/2026-08-14-cleanup-cutover-design.md`. Read it before Task 1, especially §7 Stop conditions.

## Global Constraints

- **Never `git push`.** A pre-push hook owns pushing and it is the human's job.
- **NOTHING THAT COSTS MONEY.** No `aws-*` target, no `terraform apply`, no `deploy ENV=aws` for real. **`scripts/aws/up-all.sh` has no confirmation prompt.**
- **DELETE NOTHING until the task that authorises it.** Tasks 1-4 are additive and reversible. Task 5 is not.
- **`aws/` stays** (spec D2). Do not move or delete it.
- **Never print a credential value.**
- **A live cluster exists** — minikube profile `microecom`, context `microecom`, 10/10 app pods healthy, rebuilt for this phase. **Never run `make k8s-nuke`.** If you break the cluster, say so immediately; rebuilding costs ~35 minutes.
- Every task ends with a commit, after running the tests it names.

## Stop conditions (spec §7) — these override everything below

- Helm apps do not come up cleanly → **stop, delete nothing**, report.
- Compose bootstrap fails after repointing → **revert the chain**, delete nothing.
- Any suite regresses → stop before the next deletion.

**Ending after Task 1 or 2 with nothing deleted is a GOOD outcome.** A half-deleted tree is not.

---

## Task 1: The Helm k8s cut-over — the phase's one real risk

**Files:** `Makefile`

Phase 3's Helm apps path failed on two blockers. **Phase 6's `5b57c4b` already fixed the first** (namespace ownership stamps on all three chart-rendered namespaces). Only the second remains:

`k8s-apps-helm` sets `apps.enabled=true` but never `infra.enabled=false`, so it renders the umbrella's infra subchart — which vendors grafana — and collides with the standalone `grafana` release that `k8s-platform` installed.

- [ ] **Step 1: Reproduce the collision**

Run `make k8s-apps-helm` and capture the failure. Expect an ownership error naming a grafana resource. **This confirms the blocker still exists before you change anything.**

- [ ] **Step 2: Fix it**

Add `--set infra.enabled=false` to `k8s-apps-helm`, mirroring what `deploy/scripts/aws-deploy.sh` already does. Smallest change; do not restructure the chart.

- [ ] **Step 3: Deploy for real and verify the stack SERVES**

```
make k8s-apps-down      # remove the kustomize-managed apps first — the two paths
                        # are mutually exclusive on one cluster
make k8s-apps-helm
```

Then: all app pods Ready, and the catalog returns products through the gateway (port-forward `svc/gateway`; expect 30 products). **Rendering is not deploying — this step is the point of the whole task.**

- [ ] **Step 4: Repoint the verbs**

`VERB_deploy_k8s := k8s-apps-helm` and `VERB_bootstrap_k8s` at the Helm-based chain. **`verb-equivalence-test.sh` will fail** — its baselines pin the old targets. Update the baselines *for these two mappings only*, using `FORCE=1` deliberately, and **never touch `baseline/bootstrap.txt` or `baseline/status.txt`** (frozen Phase 6 evidence).

- [ ] **Step 5: If Helm deployment fails, STOP**

Restore with `make k8s-apps`, confirm the stack serves again, report what failed, and **do not proceed to any later task**. This path has been mis-assessed twice; a third surprise is entirely possible and is a finding, not a failure.

- [ ] **Step 6: Commit** (cut-over only, no deletions)

---

## Task 2: The compose cut-over

**Files:** `Makefile`

`bootstrap-compose` still chains `vault-import` (reads `docker/vault-configs/`) and `seed-data` (reads `scripts/seed/`). Both must repoint before their sources can be deleted.

- [ ] **Step 1: Repoint the chain**

`vault-import` → `secrets-seed ENV=compose`; `seed-data` → the `seed ENV=compose` stages. Preserve the prerequisite ORDER — `svc-start` must still precede seeding, because `ecommerce.sql` is data-only and Hibernate creates the schema at service boot.

- [ ] **Step 2: Verify live, end to end**

```
make infra-up && make bootstrap ENV=compose
```

Compose is the daily driver. Confirm the stack serves and the Redis `productAvailable:*` counters are rebuilt (Phase 5's reconcile). **Do not infer this from the expansion — run it.**

- [ ] **Step 3: If it fails, revert the chain and STOP**

- [ ] **Step 4: Commit**

---

## Task 3: Move the k6 stress harness

**Files:** `k8s/apps/base/k6-stress/` → `deploy/`, plus `Makefile`

Spec D5. Six tracked files, referencing `docker/*.json`.

- [ ] **Step 1: Move and repoint**

Relocate under `deploy/`, repoint the seed references at `deploy/seed/`, update the four Makefile targets (`k8s-payment-stress`, `k8s-storefront-{smoke,soak,stress}`).

- [ ] **Step 2: Verify by rendering, not running**

`kubectl kustomize` (or the equivalent) on the moved manifests must build, and the Makefile targets must resolve via `make -n`. **A full stress run is out of scope** — this task proves the move is structurally sound, not that the tests still find bugs.

- [ ] **Step 3: Commit**

---

## Task 4: Freeze the oracles, migrate the scars

**Files:** the four oracle capture scripts; `k8s/CLAUDE.md` → `deploy/CLAUDE.md`

**Still no deletions.** This task makes deletion survivable.

- [ ] **Step 1: Freeze all four oracles**

Secrets goldens, seed goldens, AWS oracle, make baselines. Each capture script gets a header stating **the source is gone and it must never be regenerated**, and refuses to run without `FORCE=1` — the treatment `capture-baseline.sh` already has. Copy that pattern.

- [ ] **Step 2: Migrate the 19 scars**

`k8s/CLAUDE.md` holds 19 `### SCAR` sections — the XA self-deadlock, the Bitnami migration, Confluent `enableServiceLinks`, the tunnel diagnostics, the kustomize out-of-tree restriction, and more. **Move them to `deploy/CLAUDE.md` verbatim.** Losing them would cost more than this refactor saved.

Where a scar refers to something being deleted, keep the scar and note that the referenced path is gone — the *lesson* outlives the code.

- [ ] **Step 3: Verify the count**

`grep -c '^### SCAR' deploy/CLAUDE.md` must equal what `k8s/CLAUDE.md` had. **Report the number.**

- [ ] **Step 4: Commit**

---

## Task 5: Delete — the irreversible task

**Only proceed if Tasks 1-4 all succeeded and every suite passes.**

Delete in **separate commits, smallest blast radius first**, running the full suite after each:

- [ ] **Step 1:** `docker/vault-configs/` + `scripts/vault/import-secrets.sh`
- [ ] **Step 2:** `scripts/seed/` + `scripts/aws/seed-*.sh`
- [ ] **Step 3:** `docker/ecommerce.sql`, `docker/*.json`
- [ ] **Step 4:** `k8s/`

After **each** step: `git grep` the removed path. It must return nothing outside docs and frozen fixtures. **A dangling reference that only fires at runtime is the characteristic failure of this work.**

- [ ] **Step 5: Verify live again after the last deletion**

The cluster and compose must both still work. Deleting a file that something read at runtime does not show up in a test suite.

---

## Task 6: Docs and close-out

**Files:** `deploy/README.md`, root `CLAUDE.md`

- [ ] **Step 1: Update the docs to the new reality**

One path per concern. Remove references to deleted trees. State what `aws/` still is and why it stayed.

- [ ] **Step 2: Verification status**

What is proven live (k8s Helm apps, compose bootstrap), what is proven offline, and what remains unexercised — **`ENV=aws` has still never been deployed**, and that must be said plainly, as the three existing Verification status sections do.

- [ ] **Step 3: Final full verification**

Every suite, plus both live paths. **Report the numbers, do not assert them.**

- [ ] **Step 4: Commit**

## Verification summary

| Gate | Where | Criterion |
|---|---|---|
| Helm apps deploy AND serve | live k8s | pods Ready, catalog returns 30 products |
| compose bootstrap | live compose | stack serves, Redis counters rebuilt |
| all offline suites | anywhere | render 268, aws-diff 31-12-0, verb-equivalence, seed, secrets |
| post-deletion sweep | after each deletion | `git grep` clean outside docs/fixtures |
| scars preserved | `deploy/CLAUDE.md` | count matches the 19 in `k8s/CLAUDE.md` |
