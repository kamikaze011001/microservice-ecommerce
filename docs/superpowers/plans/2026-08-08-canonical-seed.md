# Canonical Seed Consolidation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One seed entry point — `deploy/scripts/seed.sh --env <env> --stage <stage>` — reading one canonical copy of the seed data, replacing three hand-maintained implementations without deleting any of them.

**Architecture:** Same two-layer shape Phase 4 proved. A **pure renderer** (`deploy/scripts/lib/seed_render.py`) turns canonical data + a per-env context into concrete artifacts — SQL text, Mongo documents, object keys — with no network and no backend. A separate **transport** layer writes those artifacts per env. The seam is what makes the `aws` leg verifiable offline and the whole suite runnable in CI without credentials.

**Tech Stack:** bash, python3 (+ pyyaml 6.0.3), jq. **`yq` is NOT installed. The `vault` CLI is NOT installed.** Tests are bash scripts printing `N passed, M failed`, matching `deploy/secrets/tests/*.sh`.

**Design spec:** `docs/superpowers/specs/2026-08-08-canonical-seed-design.md`. Read it before Task 1.

## Global Constraints

These bind **every** task. A task's requirements implicitly include this section.

- **Never `git push`.** A pre-push hook owns pushing and it is the human's job in this repo. Never bypass that hook.
- **Delete nothing.** `docker/*`, `scripts/seed/*`, `scripts/aws/seed-*.sh` and `k8s/infra/jobs/*` stay untouched and working. Deletion is Phase 8. The only permitted edit outside `deploy/` is Task 7's documentation fix.
- **`docker/product.json`, `docker/api_role.json`, `docker/product-quantity-history.json` and `docker/ecommerce.sql` must remain byte-identical.** 20 consumers depend on them, including both k6 stress job manifests and the Helm infra chart. Verify with `git diff --stat docker/` — it must be empty at every commit.
- **Never print a resolved credential value** to stdout, a log line, test output, or a commit message. Context files may carry hosts and bucket names; they must not carry passwords.
- **The renderer is pure.** No network, no subprocess to a backend, no cluster access in `seed_render.py`. If a task needs backend access, it belongs in `seed.sh`.
- **Env names are exactly** `compose`, `k8s`, `aws`.
- **`deploy/.run/` is already gitignored** (`.gitignore:28`). Render output goes there.
- Every task ends with a commit. Run the tests named in the task before committing.

## File Structure

| Path | Responsibility |
|---|---|
| `deploy/seed/ecommerce.sql` | Canonical MySQL data. Copy of `docker/ecommerce.sql`, unchanged. |
| `deploy/seed/api_role.json` | Canonical Mongo auth rules. Copy, unchanged. |
| `deploy/seed/product.json` | Canonical catalog. `{{ctx.mediaBaseUrl}}` replaces the literal host. |
| `deploy/seed/product-quantity-history.json` | Canonical stock ledger. Copy, unchanged. |
| `deploy/seed/contexts/{compose,k8s,aws}.yaml` | Per-env values: `mediaBaseUrl`, transport selector. |
| `deploy/scripts/lib/seed_render.py` | Pure renderer. Canonical + context → artifacts. |
| `deploy/scripts/seed.sh` | The one entry point. Stages + transports. |
| `deploy/seed/tests/shims/` | Fake `docker`/`kubectl`/`mc`/`aws`/`mysql`/`mongoimport`. |
| `deploy/seed/tests/capture-golden.sh` | Runs the real old scripts under shims. |
| `deploy/seed/tests/golden/{compose,k8s,aws}.json` | Captured old-path intent. |
| `deploy/seed/tests/render-test.sh` | Renderer unit tests. |
| `deploy/seed/tests/equivalence-test.sh` | Layer A: golden vs renderer, all three envs. |
| `deploy/seed/tests/live-verify.sh` | Layer B: live state diff, compose + k8s. |

---

## Task 1: Capture goldens from the three old paths

Nothing can be verified until we know what the old paths actually write. This task produces the oracle every later task is measured against.

**Files:**
- Create: `deploy/seed/tests/shims/{docker,kubectl,mc,aws,mysql,mongoimport}`
- Create: `deploy/seed/tests/capture-golden.sh`
- Create: `deploy/seed/tests/golden/{compose,k8s,aws}.json`

**Interfaces:**
- Produces: `golden/<env>.json`, shape:
  ```json
  {
    "mysql":     ["INSERT INTO ... ;", "..."],
    "mongo":     {"product": [ {...} ], "api_role": [ {...} ]},
    "objects":   ["products/<id>/<slug>.jpg", "..."],
    "reconcile": ["restart:inventory-service"]
  }
  ```
  Arrays are **sorted** before writing so ordering differences never masquerade as content differences.

- [ ] **Step 1: Write the shims**

Each shim records its argv and stdin to `$SEED_CAPTURE_DIR`, then exits 0. The `mysql` shim must exit 0 and produce empty output for reads, so scripts that branch on a query result take the "not yet seeded" path — that makes the capture record full *intent* rather than a partial re-run. This mirrors the Phase 4 fake `vault` failing every `kv get`.

```bash
#!/usr/bin/env bash
# deploy/seed/tests/shims/mysql
: "${SEED_CAPTURE_DIR:?}"
{ echo "ARGV: $*"; echo "--- stdin ---"; cat; } >> "$SEED_CAPTURE_DIR/mysql.log"
exit 0
```

The `kubectl` shim needs one special case: `kubectl -n apps get deploy inventory-service` must exit **0**, so `k8s-inventory.sh` reaches its reconcile branch and the capture records it. Everything else logs and exits 0.

- [ ] **Step 2: Run it and see the capture is non-empty**

Run: `bash deploy/seed/tests/capture-golden.sh`
Expected: three files under `golden/`, each with a non-empty `mysql` array. If `mysql` is empty for an env, the shim let a script take an early-exit branch — fix the shim, not the golden.

- [ ] **Step 3: Assert the counts match reality**

The canonical catalog has **30 products, all 30 carrying an `imageUrl`, all on host `localhost:9000`** (verified 2026-08-08). So each env's golden must contain **30** `inventory_product` INSERTs and **30** object keys.

```bash
python3 -c "
import json
for env in ('compose','k8s','aws'):
    g=json.load(open(f'deploy/seed/tests/golden/{env}.json'))
    n=len([s for s in g['mysql'] if 'inventory_product' in s])
    assert n==30, f'{env}: {n} inventory_product INSERTs, expected 30'
print('golden counts OK')"
```

- [ ] **Step 4: Assert the goldens disagree about the media host**

This is the whole reason the phase exists. If all three agree, the capture is wrong.

```bash
python3 -c "
import json,re
hosts={}
for env in ('compose','k8s','aws'):
    g=json.load(open(f'deploy/seed/tests/golden/{env}.json'))
    blob=' '.join(g['mysql'])
    hosts[env]=sorted(set(re.findall(r'http://([^/\"]+)/', blob)))
print(hosts)
assert hosts['compose']!=hosts['k8s'], 'compose and k8s should differ on media host'"
```

- [ ] **Step 5: Commit**

```bash
git add deploy/seed/tests
git commit -m "test(seed): capture golden artifacts from the three old seed paths"
```

---

## Task 2: Canonical seed data, contexts, and the compose invariant

**Files:**
- Create: `deploy/seed/{ecommerce.sql,api_role.json,product.json,product-quantity-history.json}`
- Create: `deploy/seed/contexts/{compose,k8s,aws}.yaml`
- Create: `deploy/seed/tests/render-test.sh` (invariant test only; renderer tests land in Task 3)

**Interfaces:**
- Produces: `deploy/seed/contexts/<env>.yaml` with at minimum:
  ```yaml
  mediaBaseUrl: http://localhost:9000      # compose
  mysqlTransport: docker-exec              # docker-exec | k8s-job | k8s-run
  objectTransport: mc                      # mc | aws-s3
  ```
  `aws` sets `mediaBaseUrl: <terraform:s3_public_base_url>` — the same `<terraform:...>` syntax `deploy/secrets/contexts/aws.yaml` already uses, so both resolvers read one convention.

- [ ] **Step 1: Write the failing invariant test**

```bash
# deploy/seed/tests/render-test.sh — the standing invariant from the spec
rendered=$(python3 deploy/scripts/lib/seed_render.py --env compose --only product.json)
if diff <(printf '%s' "$rendered") docker/product.json >/dev/null; then
  pass "compose render reproduces docker/product.json byte-for-byte"
else
  fail "compose render differs from docker/product.json"
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash deploy/seed/tests/render-test.sh`
Expected: FAIL — `seed_render.py` does not exist yet.

- [ ] **Step 3: Create the canonical data**

Copy all four files from `docker/`. Then in `deploy/seed/product.json` **only**, replace `http://localhost:9000` with `{{ctx.mediaBaseUrl}}` — 30 occurrences. Leave every other byte, including key order and indentation, exactly as-is: the invariant is byte-for-byte, so reformatting breaks it.

- [ ] **Step 4: Verify docker/ is untouched**

Run: `git diff --stat docker/`
Expected: **empty output.** Any change here violates a Global Constraint.

- [ ] **Step 5: Commit**

```bash
git add deploy/seed
git commit -m "feat(seed): canonical seed data and the three env contexts"
```

---

## Task 3: The pure renderer

**Files:**
- Create: `deploy/scripts/lib/seed_render.py`
- Modify: `deploy/seed/tests/render-test.sh` (add the unit tests below)

**Interfaces:**
- Consumes: `deploy/seed/contexts/<env>.yaml`, the four canonical files.
- Produces:
  ```python
  CTX_REF = re.compile(r"\{\{ctx\.([A-Za-z_][A-Za-z0-9_]*)\}\}")
  TF_REF  = re.compile(r"^<terraform:([^>]+)>$")
  ENVS    = ("compose", "k8s", "aws")

  def render_all(seed_dir, env, tf_outputs=None, only=None) -> dict:
      """Canonical data + context -> {"mysql": [...], "mongo": {...},
      "objects": [...], "reconcile": [...]}. Pure: no network, no backend."""
  ```
  Mirror `deploy/scripts/lib/secrets_resolve.py` deliberately — same `{{ctx.…}}` and `<terraform:…>` syntaxes, same "a failed render writes nothing to stdout" rule, same `--tf-outputs FILE` flag so the aws path needs no terraform binary.

- [ ] **Step 1: Write the failing unit tests**

Four behaviours, each matching a hazard the spec names:

```bash
# 1. every env renders 30 inventory_product rows
# 2. an unknown {{ctx.missingKey}} fails loudly and prints NOTHING to stdout
# 3. rendered SQL escapes embedded quotes the same way the goldens do
# 4. --only product.json emits exactly the file, no wrapper
```

Test 3 matters: the AWS generator does `gsub("\""; "\\\"")` inside a jq concat with a `NULL` branch for empty URLs. Assert against a product name containing a literal `"` and a product with no `imageUrl`, and compare to the golden's escaping. Quote handling that differs here passes every count-based check while corrupting data.

- [ ] **Step 2: Run to verify they fail**

Run: `bash deploy/seed/tests/render-test.sh`
Expected: FAIL on all five (four unit + the Task 2 invariant).

- [ ] **Step 3: Implement `seed_render.py`**

Keep it a pure function. Read YAML with `yaml.safe_load` (pyyaml is present; **`yq` is not installed** — do not shell out to it). Resolve `{{ctx.…}}` against the context map; a missing key raises with the key name and the file it appeared in.

- [ ] **Step 4: Run to verify they pass**

Run: `bash deploy/seed/tests/render-test.sh`
Expected: `5 passed, 0 failed` — including the byte-for-byte compose invariant.

- [ ] **Step 5: Commit**

```bash
git add deploy/scripts/lib/seed_render.py deploy/seed/tests/render-test.sh
git commit -m "feat(seed): pure renderer for canonical seed data"
```

---

## Task 4: Layer A — equivalence across all three envs

**Files:**
- Create: `deploy/seed/tests/equivalence-test.sh`

**Interfaces:**
- Consumes: `golden/<env>.json` (Task 1), `render_all()` (Task 3).

- [ ] **Step 1: Write the failing test**

For each env, for each of `mysql`, `mongo`, `objects`, `reconcile`: sort both sides, diff, report per-key. On mismatch print **which keys differ and how many**, never the full blob — a 30-row dump buries the signal.

- [ ] **Step 2: Run to verify it fails or reveals real differences**

Run: `bash deploy/seed/tests/equivalence-test.sh`
Expected: initially FAIL. **Investigate every difference before "fixing" the renderer.** A difference may be a real defect in an old script — the spec names the k8s post-hoc `updateOne` as one that can silently miss rows. If the renderer is right and the old path is wrong, say so in the task report rather than bending the renderer to match a bug.

- [ ] **Step 3: Reconcile until green**

Expected: `12 passed, 0 failed` (3 envs × 4 artifact kinds).

- [ ] **Step 4: Prove the test can fail**

Plant a wrong `mediaBaseUrl` in `contexts/k8s.yaml`, re-run, confirm it reports the `mysql` and `mongo` keys differing and names the host. Restore and re-run green. **A comparison that has never failed is not evidence** — this is the check that caught a vacuous suite in Phase 4.

- [ ] **Step 5: Commit**

```bash
git add deploy/seed/tests/equivalence-test.sh
git commit -m "test(seed): offline equivalence against all three old paths"
```

---

## Task 5: `seed.sh` — the pre-apps stage

**Files:**
- Create: `deploy/scripts/seed.sh`

**Interfaces:**
- Produces: `seed.sh --env <env> --stage pre-apps [--dry-run] [--context NAME] [--tf-outputs FILE]`
- Consumes: `render_all()`.

- [ ] **Step 1: Render everything before writing anything**

Same ordering rule as `secrets-seed.sh`: resolve the full artifact set first, then transport. A render failure must leave the backend untouched.

- [ ] **Step 2: Require an explicit kubectl context for `--env k8s`**

Copy the guard from `deploy/scripts/secrets-seed.sh` verbatim in spirit: refuse to run without `--context NAME` / `KUBE_CONTEXT`, verify it matches, and pass the **same** name to every `kubectl` call so check and action cannot diverge. During Phase 4's verification the ambient context was an unrelated live cluster.

- [ ] **Step 3: Implement the two pre-apps transports**

`mongo` and `objects` only. Per the context's `objectTransport`: `mc` for compose/k8s, `aws s3 cp` for aws.

**Preserve `mongo-products.sh`'s collection DROP behaviour, but behind an explicit `--replace` flag** (spec §7). Default must not silently wipe local product edits; the Makefile already documents this as why that script is excluded from `make up`.

- [ ] **Step 4: Verify against compose**

```bash
make infra-up
bash deploy/scripts/seed.sh --env compose --stage pre-apps --dry-run
```
Expected: dry-run prints the artifact counts (30 products, 30 objects) and touches nothing. Then run for real and confirm the Mongo collection has 30 documents.

- [ ] **Step 5: Commit**

```bash
git add deploy/scripts/seed.sh
git commit -m "feat(seed): seed.sh pre-apps stage — mongo documents and image objects"
```

---

## Task 6: `seed.sh` — the post-apps stage, precondition, and reconcile

**Files:**
- Modify: `deploy/scripts/seed.sh`

**Interfaces:**
- Produces: `seed.sh --env <env> --stage post-apps`

- [ ] **Step 1: Write the failing precondition test**

Against a database with no schema, `--stage post-apps` must exit non-zero naming the missing table, **before** issuing any INSERT.

```
Expected stderr: "post-apps: table 'account' does not exist — run the apps first
                  so Hibernate ddl-auto creates the schema"
```

- [ ] **Step 2: Run to verify it fails**

Expected: currently the run reaches MySQL and produces `ERROR 1146` mid-import — the exact failure mode `k8s/CLAUDE.md` documents.

- [ ] **Step 3: Implement the precondition, the transports, and the reconcile**

Precondition → `ecommerce.sql` → derived inventory rows → **reconcile**.

The reconcile restarts inventory-service so `AvailableStockSeeder` rebuilds the Redis `available:{productId}` counters from the now-populated ledger (spec D3). It is idempotent (delete-then-incr per key) and must be **skipped when the inventory-service workload is absent**, so running the seed standalone stays valid. Per env: `kubectl rollout restart` for k8s/aws, the compose equivalent for compose — **compose has no reconcile today, and adding it is the point.**

- [ ] **Step 4: Run to verify it passes**

Expected: precondition test passes; a full `post-apps` run against the live cluster completes and the reconcile reports the rollout.

- [ ] **Step 5: Commit**

```bash
git add deploy/scripts/seed.sh
git commit -m "feat(seed): post-apps stage with schema precondition and stock reconcile"
```

---

## Task 7: Make targets, docs, and one stale-doc fix

**Files:**
- Modify: `Makefile`
- Modify: `deploy/README.md`
- Modify: `k8s/CLAUDE.md`

- [ ] **Step 1: Add the targets**

```make
seed:
	@bash deploy/scripts/seed.sh --env $(or $(ENV),compose) --stage $(or $(STAGE),pre-apps)

seed-render:
	@bash deploy/scripts/seed.sh --env $(or $(ENV),compose) --stage $(or $(STAGE),pre-apps) --dry-run
```

- [ ] **Step 2: Document in `deploy/README.md`**

Cover both stages, the `--replace` flag, the k8s context requirement, and a **Verification status** section stating plainly what is and is not proven — the Phase 4 README does this and it is why nobody over-read that phase's evidence.

- [ ] **Step 3: Fix the stale OPEN ISSUE in `k8s/CLAUDE.md`**

The section "OPEN ISSUE (not yet resolved): mysql seed runs before any schema exists" **was resolved**: `k8s-seed` covers only `02-mongo-seed`, `03-vault-seed`, `05-minio-bootstrap`, `04-kafka-connect-register`, and `01-mysql-seed` was split into `k8s-seed-mysql`, which `k8s-bootstrap` runs after `k8s-apps`. Rewrite it as a resolved scar. This is the **only** permitted edit outside `deploy/`.

- [ ] **Step 4: Verify**

Run: `make -n seed ENV=k8s STAGE=post-apps` and confirm it resolves. Run `git diff --stat docker/` and confirm empty.

- [ ] **Step 5: Commit**

```bash
git add Makefile deploy/README.md k8s/CLAUDE.md
git commit -m "feat(seed): make targets, docs, and retire a resolved open issue"
```

---

## Task 8: Layer B — live state diff

**Files:**
- Create: `deploy/seed/tests/live-verify.sh`

**Context:** the minikube cluster `microecom` is up and healthy (10/10 app pods, 30 products served). Use it. Do **not** run `make k8s-nuke` — later phases need this cluster.

- [ ] **Step 1: Write the comparison**

Snapshot → reset → seed the other way → snapshot → diff. Per-table **content hashes**, not counts alone: equal counts with a wrong `image_url` host is the exact defect this phase removes.

**The reset must start from a clean collection, and this is not optional** (spec §7). The old k8s path rewrote the media host *post-hoc* with a Mongo `updateOne` loop, so a cluster that has already been seeded holds documents whose host was patched after import. The new path renders the host before writing. The two paths converge **only** on a clean collection — comparing against already-rewritten documents reports a difference that is an artifact of the reset, not a defect in either path.

Reset scope: drop the `product` and `api_role` collections and `TRUNCATE inventory_product`, `product_quantity_history`, plus the tables `ecommerce.sql` populates. **A scoped truncate, never `make k8s-nuke`** — later phases need this cluster.

- [ ] **Step 2: Assert the Redis counters, not just MySQL**

```
For every productId in product_quantity_history:
  redis available:{productId} EXISTS, and
  sum(available:*) == SUM(product_quantity_history.quantity)
```

Spec §5: every row can be correct while checkout is broken. A database-only check reports success on that state.

- [ ] **Step 3: Run on compose**

Expected: old and new paths produce identical MySQL/Mongo state **and** — for the new path only — present Redis counters. Compose has no reconcile today, so a counter difference here is the documented bug being fixed, not a regression. Record it explicitly in the task report.

- [ ] **Step 4: Run on k8s**

Run with `--context microecom`. Expected: identical state both ways, counters present in both.

- [ ] **Step 5: Commit**

```bash
git add deploy/seed/tests/live-verify.sh
git commit -m "test(seed): live state diff on compose and k8s, incl. stock counters"
```

---

## A note on derived content

Tasks 1, 5 and 6 deliberately carry **no transcription of the 1,392 lines of old shell**. That is not an omission. The equivalence suite from Task 4 is the precise, executable specification of correct behaviour — it compares against what the real old scripts actually do. Re-typing those scripts into this plan would create a third description to keep in sync, and a paraphrase that drifts from the goldens would be worse than no paraphrase at all.

Each task names the exact file it replaces. Read that file; make the goldens pass.

## Verification summary

| Layer | Scope | Gate |
|---|---|---|
| `render-test.sh` | renderer + the compose byte-for-byte invariant | `5 passed, 0 failed` |
| `equivalence-test.sh` | all three envs × 4 artifact kinds, offline | `12 passed, 0 failed` |
| `live-verify.sh` | compose + k8s actual state, incl. Redis counters | identical state, counters present |
| `git diff --stat docker/` | the frozen-tree constraint | empty, at every commit |
