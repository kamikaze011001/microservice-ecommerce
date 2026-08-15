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

`VERB_deploy_k8s := k8s-apps-helm` and `VERB_bootstrap_k8s` at the Helm-based chain. **`verb-equivalence-test.sh` will fail** — it will resolve the verb to a target with no baseline.

**Do NOT use `FORCE=1`.** `capture-baseline.sh` skips existing files by design, so simply *add the new target(s)* to its `TARGETS` list and run it normally: only the missing baselines are captured, every existing one is left untouched. `FORCE=1` would regenerate all of them against current state — exactly the hazard Phase 7 guarded against, and it would silently destroy frozen evidence.

**Never touch `baseline/bootstrap.txt` or `baseline/status.txt`** under any circumstances (frozen Phase 6 pre-conversion evidence).

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

## AMENDMENT (2026-08-15) — the deletion list was not unblocked

A controller reference sweep before dispatching the old Task 5 found **four live callers**
still reading the trees it deletes. Task 2 repointed the *compose bootstrap* only; `make up`
and the entire *k8s bootstrap* leg were never repointed.

| Live caller | Reads | Note |
|---|---|---|
| `make up` → `mongo-seed-ensure` (Makefile:99,248) | `scripts/seed/mongo-roles.sh` | the daily driver |
| `k8s-bootstrap-helm` → `k8s-seed` (Makefile:389-405) | `docker/*.json`, 4 Jobs in `k8s/infra/jobs/` | the target Task 1 cut over to |
| `k8s-bootstrap-helm` → `k8s-seed-{mysql,images,inventory,perftest}` | `docker/ecommerce.sql`, `scripts/seed/k8s-*.sh`, `k8s/infra/jobs/{01,06}` | same |
| `scripts/aws/up-all.sh:105-184` | 5× `scripts/aws/seed-*.sh` | `aws/` stays; no test covers it |

**Why it hid:** `k8s-bootstrap-helm` was assembled in Task 1 but never run end-to-end. Task 1
verified the *apps* leg (`k8s-apps-helm`). `k8s/` is two unrelated things under one directory
name — an apps layer Helm genuinely replaced, and an infra-bootstrap layer nothing replaced,
because the chart ported the StatefulSets but not the Jobs that initialise them.

**Human decision (2026-08-15): full cut-over — repoint everything, then delete `k8s/`
entirely.** Old Task 5 → **Task 8**; old Task 6 → **Task 9**.

### Replacement status of the six bootstrap Jobs

| Job | Replacement | State |
|---|---|---|
| `01-mysql-seed` | `seed.sh --env k8s --stage post-apps` | exists, unused |
| `02-mongo-seed` | `seed.sh --env k8s --stage pre-apps` | exists, unused |
| `03-vault-seed` | `secrets-seed --env k8s` | exists, **verified live** (PR #55) |
| `05-minio-bootstrap` | `deploy/scripts/seed.sh:324-325` (`mc mb` + anonymous download) | exists, unused |
| `04-kafka-connect-register` | none | **relocate** (113 lines, self-contained) |
| `06-perftest-seed` | none | **relocate** (178 lines, self-contained) |

---

## Task 5: Relocate the `k8s/` assets that must survive

**Files:** `k8s/images/`, `k8s/k9s/`, `k8s/infra/jobs/04-kafka-connect-register/`,
`k8s/infra/jobs/06-perftest-seed/` → `deploy/`; plus `Makefile`

Pure moves — the same shape as Task 3's k6 relocation, which used `git mv` to preserve
history. **No deletions and no behaviour changes in this task.**

These four are depended on by targets that survive the phase and have **no replacement
anywhere in `deploy/`**. `k8s/images/build.sh` is the sharpest: `k8s-bootstrap-helm` depends
on `k8s-build-reuse`, which runs it.

- [ ] **Step 1: Move the image builder**

`k8s/images/` → `deploy/images/`. Repoint Makefile lines 315, 320, 324 (`k8s-build`,
`k8s-build-reuse`, `k8s-build-one`). The script computes paths relative to the repo root —
**read it before moving and fix any path that assumed `k8s/`.**

- [ ] **Step 2: Move the two Jobs**

`k8s/infra/jobs/04-kafka-connect-register/` and `06-perftest-seed/` → under `deploy/`
(mirror Task 3's `deploy/k6-stress/` placement, e.g. `deploy/k8s-jobs/<name>/`). Repoint
Makefile lines 402 and 447. Both are self-contained kustomize dirs.

- [ ] **Step 3: Move the k9s config**

`k8s/k9s/` → `deploy/k9s/`; repoint Makefile line 674.

- [ ] **Step 4: Verify by rendering**

`kubectl apply -k <new job path> --dry-run=client` must succeed for both moved Jobs, and
`make -n k8s-build-reuse k8s-seed-perftest k9s` must resolve to the new paths. **A full
build is out of scope here** — Task 7 runs the real thing.

- [ ] **Step 5: Commit**

---

## Task 6: Repoint every remaining caller onto the canonical paths

**Files:** `Makefile`, `scripts/aws/up-all.sh`

Nothing is deleted here either. After this task the old trees are **unreferenced**, which is
what makes Task 8 safe.

- [ ] **Step 1: `make up` — preserve its semantics exactly**

`mongo-seed-ensure` (Makefile:248) runs on **every `make up`** and is deliberately narrow:
`mongo-roles.sh` only, because `mongo-products.sh` DROPs its collection and would wipe local
product data on every start (the comment at Makefile:245-247 says so).

`deploy/scripts/seed.sh` already encodes this: **the Mongo DROP is gated behind `--replace`**
(see its header, lines 32-39). So `seed --env compose --stage pre-apps` without `--replace`
is non-destructive.

**But it is not equivalent** — it also imports products/quantity-history and uploads 30
images on every `make up`. Preserve the *fast, non-destructive* semantics. If that needs a
narrower entry point into `seed.sh`, add one; **do not** make `make up` heavier, and **do
not** leave it reading `scripts/seed/`.

- [ ] **Step 2: Repoint the k8s bootstrap chain**

Rewire `k8s-bootstrap-helm` onto the canonical paths, preserving ORDER (secrets before apps;
pre-apps seed before apps; mysql/inventory seed after apps, because `ecommerce.sql` is
data-only and Hibernate `ddl-auto` creates the schema at service boot):

```
k8s-cluster-up → k8s-infra-helm → k8s-build-reuse
  → secrets-seed ENV=k8s          (replaces 03-vault-seed)
  → seed ENV=k8s STAGE=pre-apps   (replaces 02-mongo-seed, 05-minio-bootstrap, k8s-seed-images)
  → <relocated kafka-connect-register>
  → k8s-apps-helm
  → seed ENV=k8s STAGE=post-apps  (replaces 01-mysql-seed, k8s-seed-inventory)
  → <relocated perftest-seed>
```

`seed.sh` and `secrets-seed.sh` both **require an explicit kubectl context** for `--env k8s`
(`--context NAME` or `KUBE_CONTEXT`) — see `seed.sh:106-108`. Wire it; do not let these
inherit an ambient context.

- [ ] **Step 3: Repoint `up-all.sh`'s five seed calls**

Lines 105, 109, 162, 166, 184 call `scripts/aws/seed-{mongo,secrets,rds,inventory,images}.sh`.
Repoint onto `secrets-seed --env aws` and `seed.sh --env aws` at the equivalent stages.

**This is justified by evidence, not assumption:** Phase 5's seed goldens were captured *from
these very scripts*, and `deploy/seed/tests/equivalence-test.sh` reports **13 matched, 2
declared-different, 0 unexplained** — and both declared differences are `compose/*`, so the
**aws leg matches exactly**.

**Do not run `up-all.sh`.** It has no confirmation prompt and costs money.

- [ ] **Step 4: Retire the orphaned targets**

`vault-import` (Makefile:147) and `seed-data`/`seed-mysql`/`seed-mongo` (236-242) are now
referenced only by the help text at lines 33-34. Remove the targets and fix the help text.

- [ ] **Step 5: Verify offline**

`make -n bootstrap ENV=k8s`, `make -n up`, `make -n bootstrap ENV=compose` resolve with **no
reference to `scripts/seed/`, `scripts/vault/import-secrets.sh`, `docker/vault-configs/`, or
`docker/*.json`**. Assert the expansion is non-empty before concluding it is clean — an empty
expansion trivially satisfies "no references".

Then `git grep` each old path: everything left must be inside `docs/`, `.claude/`, frozen
fixtures, or the trees being deleted in Task 8.

- [ ] **Step 6: Commit**

---

## Task 7: Live end-to-end verification — THE GATE

**No files.** This task produces evidence, not code. **Nothing may be deleted until it passes.**

- [ ] **Step 1: Full `k8s-bootstrap-helm` from scratch**

This has **never been run end-to-end**. It costs ~35 minutes and requires tearing the cluster
down first. **Confirm with the human before starting** — it is the expensive step they agreed
to, but they should choose when it runs.

Gate: exit 0, all app pods Ready, and the catalog returns **30 products** through the gateway.

- [ ] **Step 2: Compose, still green**

`make up` (fast, non-destructive — verify it did NOT drop products) and a full
`make bootstrap ENV=compose`. Gate: 30 products, and Redis `productAvailable:*` counters
rebuilt (Task 2 measured **27 keys summing to 578**).

- [ ] **Step 3: If either fails, STOP**

Report and delete nothing. Per spec §7 this is a good outcome.

- [ ] **Step 4: Record the evidence in the ledger** — numbers, not assertions.

---

## Task 8: Delete — the irreversible task

**Only proceed if Tasks 1-7 all succeeded, every suite passes, and Task 7's live gate is
green.**

Delete in **separate commits, smallest blast radius first**, running the full suite after each:

- [ ] **Step 1:** `docker/vault-configs/` + `scripts/vault/import-secrets.sh`
- [ ] **Step 2:** `scripts/seed/` + `scripts/aws/seed-*.sh`
- [ ] **Step 3:** `docker/ecommerce.sql` and the **three top-level** `docker/*.json`
- [ ] **Step 4:** `k8s/`

### Hazards specific to these paths — read before touching anything

- **`docker/vault-config/` (SINGULAR) MUST SURVIVE.** It holds `vault-config.hcl`, mounted by
  `docker/vault.yml:11`. It differs from the doomed `docker/vault-configs/` by one letter. A
  glob like `docker/vault-config*` destroys the Vault server's own config.
- **`docker/*.json` means the THREE top-level files only** — `api_role.json`, `product.json`,
  `product-quantity-history.json`. A *recursive* glob also matches
  `docker/connectors-plugin/mongodb-kafka-connect-mongodb/manifest.json`, which must survive.
- **`docker/seed-images/` MUST SURVIVE** (31 files). `deploy/scripts/seed.sh:198` reads it.
- **NEVER `rm -rf k8s/`.** `k8s/.env` is gitignored and holds the human's real mail and PayPal
  credentials. Use `git rm -r`, which leaves untracked files alone, and tell the human that
  `k8s/.env` survives as an untracked leftover they must relocate for `k8s-app-secrets`.
- **A basename `git grep` is useless here.** The canonical replacements have the *same
  filenames* (`deploy/seed/product.json`). Grep **path-qualified** (`docker/product\.json`)
  or you will match the new path and conclude a live reference exists when it does not.

After **each** step: path-qualified `git grep` for the removed path. It must return nothing
outside `docs/`, `.claude/`, and frozen fixtures. **A dangling reference that only fires at
runtime is the characteristic failure of this work.**

- [ ] **Step 5: Verify live again after the last deletion**

Cluster and compose must both still serve. Deleting a file something read at runtime does not
show up in a test suite.

---

## Task 9: Docs and close-out

**Files:** `deploy/README.md`, root `CLAUDE.md`

- [ ] **Step 1: Update the docs to the new reality**

One path per concern. Remove references to deleted trees. State what `aws/` still is and why it stayed. Root `CLAUDE.md` documents `make bootstrap`/`make up` and the service-port table — check every path it names still exists.

- [ ] **Step 2: Verification status**

What is proven live (k8s Helm apps AND the full `k8s-bootstrap-helm` chain, compose bootstrap), what is proven offline, and what remains unexercised — **`ENV=aws` has still never been deployed**, and that must be said plainly, as the three existing Verification status sections do.

Also record that `up-all.sh`'s seed calls were repointed on the strength of the seed
equivalence suite's aws leg, **without ever executing them**.

- [ ] **Step 3: Note the `k8s/.env` leftover**

`git rm -r k8s/` leaves the human's gitignored `k8s/.env` behind as an untracked file. Say where it must move for `k8s-app-secrets` to keep working.

- [ ] **Step 4: Final full verification**

Every suite, plus both live paths. **Report the numbers, do not assert them.**

- [ ] **Step 5: Commit**

## Verification summary

| Gate | Where | Criterion |
|---|---|---|
| Helm apps deploy AND serve | live k8s | pods Ready, catalog returns 30 products |
| **full `k8s-bootstrap-helm`** | **live k8s, from scratch** | **exit 0, pods Ready, 30 products — never run before** |
| `make up` stays fast and non-destructive | live compose | products NOT dropped, no `scripts/seed/` reference |
| compose bootstrap | live compose | stack serves, Redis counters rebuilt (27 keys / 578) |
| all offline suites | anywhere | render 268, aws-diff 31-12-0, verb-equivalence, seed, secrets |
| relocated assets resolve | offline | `make -n` names the `deploy/` paths; both moved Jobs dry-run clean |
| post-deletion sweep | after each deletion | **path-qualified** `git grep` clean outside docs/fixtures |
| scars preserved | `deploy/CLAUDE.md` | 19, matching `k8s/CLAUDE.md` (done — Task 4) |
