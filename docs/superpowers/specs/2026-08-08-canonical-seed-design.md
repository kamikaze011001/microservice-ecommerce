# Canonical Seed Consolidation — Design

**Phase 5** of the deploy refactor (`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`).
Follows Phase 4 (canonical secrets), whose resolve/transport split this reuses.

**Goal:** one seed entry point — `deploy/scripts/seed.sh --env <env> --stage <stage>` — reading one
canonical copy of the seed data, replacing three hand-maintained implementations.

---

## 1. The problem, measured

Seeding is implemented three times. Excluding vault (Phase 4 already took it), the surface is
**1,392 lines** across 15 compose scripts, 4 AWS scripts and 6 k8s Job directories
(1,785 total less the 393 lines of `03-vault-seed/seed.sh` + `aws/seed-secrets.sh`).

The drift hazard is not hypothetical — it is already present in the same shape Phase 4 fixed. The
`image_url` host rewrite is implemented independently in **six** places:

```
scripts/seed/mysql-inventory-products.sh   scripts/aws/seed-mongo.sh
scripts/seed/k8s-inventory.sh              scripts/aws/seed-inventory.sh
scripts/seed/verify-products.sh            k8s/infra/jobs/02-mongo-seed/seed.sh
```

Worse, the three envs use three *different mechanisms* for one value:

| env | mechanism |
|---|---|
| compose | the literal `http://localhost:9000/ecommerce-media/...` baked into `docker/product.json` |
| k8s | post-hoc Mongo `updateOne` loop over docs matching `/^http:\/\/localhost:9000\//` |
| aws | `gsub` during SQL generation against a terraform output |

Compose is privileged as "the file". The k8s rewrite is a *post-hoc UPDATE*, so a document whose
URL does not match the regex keeps a wrong host silently. `k8s/CLAUDE.md` records this exact value
causing browser-side 404s, and — because order-service snapshots `inventory_product.image_url`
into `order_item` at order-create — a wrong host is persisted into saved orders.

### Transport matrix

| domain | compose | k8s | aws |
|---|---|---|---|
| MySQL | `docker exec` → mysql-master | in-cluster Job | ephemeral `kubectl run` pod → `mysql -h $RDS_HOST` |
| Mongo | `mongoimport` via docker | in-cluster Job | **reuses the k8s Job verbatim** |
| Images | `mc cp` → MinIO | `mc` → in-cluster MinIO | `aws s3 cp` direct from host |
| Inventory | generated SQL → docker exec | generated SQL → mysql-0 | generated SQL → ephemeral pod |

`scripts/aws/seed-mongo.sh` already sources `k8s/infra/jobs/02-mongo-seed/seed.sh`. One cell is
shared today — evidence the consolidation is tractable, not aspirational.

---

## 2. Decisions

Each with the alternative rejected.

### D1 — Scope is the four data domains

**In:** MySQL base data, Mongo documents, derived inventory rows, product image objects.
**Out:** perftest seed, kafka-connect registration.

*Rejected:* folding in everything currently named "seed". Connector registration is Kafka *config*,
env-invariant, and fails for entirely different reasons than a data import; coupling them means one
target with two unrelated failure modes.

### D2 — Env-varying values are context placeholders, rendered before write

`deploy/seed/product.json` carries `{{ctx.mediaBaseUrl}}`. Each `deploy/seed/contexts/<env>.yaml`
supplies the value. Rendering happens before anything is written.

*Rejected:* keeping literal compose values and centralising the three rewrites into one shared
function. That keeps compose privileged and keeps the rewrite a patch-after-the-fact — a row the
pattern misses still ends up with a wrong host. Rendering cannot miss a row, and a missing context
value fails loudly instead of leaving stale data.

### D3 — Two stages with a fail-fast precondition, and a post-seed reconcile

```
seed.sh --env <env> --stage pre-apps    # mongo documents, image objects
seed.sh --env <env> --stage post-apps   # ecommerce.sql, derived inventory rows,
                                        #   then the inventory-service reconcile
```

**The reconcile is load-bearing and is not data.** `AvailableStockSeeder` runs at
inventory-service *startup* and backfills the Redis `productAvailable:{productId}` reservation counters
from `SUM(product_quantity_history)`. Apps start *before* the inventory seed, so it backfills 0
rows and creates no counters — and the Lua reservation treats a missing key as 0, so every order
fails "Insufficient available stock". k8s (`scripts/seed/k8s-inventory.sh`) and aws
(`scripts/aws/up-all.sh` step 8) therefore restart inventory-service after seeding.

**Compose does not.** No restart exists anywhere in `scripts/seed/`. This is not an implementation
difference — it is a *behavioural* one, and it matches the documented compose symptom of carts
showing "0 available". Consolidating fixes compose for free, which is the strongest argument for
doing this phase at all: the drift has already produced a user-visible bug in one env.

The reconcile is idempotent (the seeder deletes-then-incrs each key), so a no-op costs one rollout.
It is skipped when the inventory-service workload is absent, so running the seed standalone before
apps stays valid.

`ecommerce.sql` is data-only (0 `CREATE TABLE`); the schema comes from Hibernate `ddl-auto` at
service boot. `post-apps` therefore opens by checking the tables it needs exist, and exits naming
the missing table rather than hitting `ERROR 1146` partway through an import.

*Rejected:* a self-gating single command that polls until the schema appears. It makes ordering
impossible to get wrong, but converts a real failure (apps never started) into a timeout, and adds
a duration to tune per env. The dependency is better visible than hidden — Phase 6 rewrites the
bring-up chain that expresses it.

### D4 — Canonical data alongside the old, with an equivalence invariant

`docker/*` stays **byte-identical**; all 20 existing consumers keep working. `deploy/seed/*` is the
new canonical source. A test asserts rendering the canonical `product.json` for **compose**
reproduces `docker/product.json` exactly.

*Rejected:* moving the files now and updating all 20 references — including both k6 stress job
manifests and the Helm infra chart. That breaks the "every phase leaves a working deploy, nothing
deleted before Phase 8" property that made Phases 1-4 trivially reversible.

The duplication is real but **checked**: edit either file alone and the invariant fails.

### D5 — Two verification layers

**Layer A, rendered-artifact equivalence** — offline, all three envs, credential-free, CI-able.
**Layer B, live state diff** — compose and k8s, comparing actual resulting data.

*Rejected:* live-only (aws gets no verification at all, and nothing runs in CI) and offline-only
(nothing proves the transports land the data — the precise gap that let Phases 1, 3 and 4 ship with
unexercised transports; see §7).

---

## 3. Layout

```
deploy/seed/
  ecommerce.sql                     # unchanged — 0 CREATE TABLE, no env-varying data.
                                    # Its only "localhost" is an inert mysqldump header
                                    # comment (`-- Host: localhost`) — do not "fix" it.
  api_role.json                     # unchanged — verified to contain no host references
  product.json                      # {{ctx.mediaBaseUrl}} replaces the literal host
  product-quantity-history.json
  contexts/{compose,k8s,aws}.yaml   # mediaBaseUrl + transport selector
  tests/
deploy/scripts/seed.sh              # one entry point
```

Contexts live under `deploy/seed/`, mirroring `deploy/secrets/contexts/` rather than sharing it:
the secrets contexts carry credentials and feed a different resolver. Two small files beat one file
with two audiences.

`make seed ENV=<env> STAGE=<stage>` wraps it, thin, consistent with the Phase 4 targets.

---

## 4. The render/transport split

A **pure render step** (canonical data + context → concrete SQL text, JSON documents and object
keys; no network, no backend) and a **separate transport step**. This is the same seam that made
Phase 4's AWS leg verifiable without an account, and it is what makes Layer A possible at all.

`aws` renders identically to the others; only its transport differs.

---

## 5. Verification

### Layer A — rendered-artifact equivalence (offline, all three envs)

Put fake `docker`, `kubectl`, `mc`, `aws`, `mysql` and `mongoimport` first on `PATH`; run each
**real** old script; capture what it would have written — SQL text, JSON documents, object keys.
Diff against the new renderer's output for the same env.

This is the Phase 4 shim technique. It is the only way `aws` is checkable: it cannot be run without
an account and spend.

### Layer B — live state diff (compose + k8s)

Seed old-way → snapshot; reset; seed new-way → snapshot; diff.

**Not row counts alone.** Per-table content hashes and object listings, because equal counts with a
wrong `image_url` host is exactly the bug this phase exists to eliminate. A count-only check would
pass on the very defect being fixed.

**And not MySQL alone.** Layer B must assert the Redis `productAvailable:{productId}` counters exist and
sum to the ledger, because the D3 reconcile is what makes the inventory seed *effective*. Every
row can be correct while checkout is broken — that is precisely the compose state today. A
verification that stops at the database would report success on it.

### The standing invariant

Rendering `deploy/seed/product.json` for compose reproduces `docker/product.json` byte-for-byte.
One assertion; it is what keeps D4's duplication honest.

---

## 6. Migration and rollback

Build alongside, delete nothing. Old targets, old scripts and all 20 consumers are untouched. The
new surface is purely additive. **Rollback is "don't call the new target."** Deletion is Phase 8.

**Inherited debt, named deliberately:** Phase 8 deleting the old seed scripts destroys Layer A's
capture source, making the equivalence suite unregenerable — exactly as it does for the Phase 4
secrets goldens. Two unregenerable suites is a pattern, not an accident. Phase 8 must decide
explicitly: freeze them as fixtures, or replace them with a different check. An equivalence suite
that can no longer regenerate its baseline degrades into a snapshot test of itself.

---

## 7. Risks

- **`mongo-products.sh` DROPs its collection before importing.** The Makefile already documents
  this as the reason it is excluded from `make up`. The new path must preserve that behaviour or
  put it behind an explicit flag. A seed that silently wipes local product edits is a bad default.
- **Existing k8s clusters hold already-rewritten documents.** The old path rewrote post-hoc; the
  new path renders directly. The two converge only on a clean collection, so Layer B must account
  for this or report a false difference.
- **Escaping in the derived inventory SQL.** The AWS generator does `gsub("\""; "\\\"")` inside a
  jq string concat, with a `NULL` branch for empty URLs. Quote and NULL handling must match exactly,
  or equivalence passes while the data differs.
- **Layer B needs a reset path.** "Seed both ways and compare" requires returning the DB to a known
  state between runs. On compose that is cheap; on k8s it means a scoped truncate, not `k8s-nuke`.

## 8. Out of scope

Perftest seed and kafka-connect registration (D1). Any application code change. Phase 6's unified
`make <verb> ENV=<env>` verbs — `seed.sh` is designed to be *called by* them, not to replace them.

## 9. Findings raised, not fixed

- **`k8s/CLAUDE.md` carries a stale OPEN ISSUE.** "mysql seed runs before any schema exists" was
  resolved by splitting `01-mysql-seed` out of `k8s-seed` into `k8s-seed-mysql`, which
  `k8s-bootstrap` runs after `k8s-apps`. Fixed as part of this phase — a resolved problem left
  marked open costs someone a debugging session.
- **`scripts/seed/` holds k8s-specific scripts** (`k8s-inventory.sh`, `k8s-product-images.sh`)
  despite the directory reading as compose-only. Phase 8 territory; noted so the naming is not
  mistaken for a guarantee.
