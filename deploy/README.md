# deploy/ deployment structure

This directory consolidates deployment artifacts for three target environments:
**docker-compose** (fast inner loop), **minikube** (local Kubernetes), and
**AWS EKS** (cloud).

## Status

**The cut-over is complete.** As of Phase 8 (2026-08-14/15), `deploy/` is the
**only** path for each concern below — the duplicate trees it replaced
(`docker/vault-configs/`, `scripts/vault/import-secrets.sh`, `scripts/seed/`,
`scripts/aws/seed-*.sh`, `docker/ecommerce.sql`, the three top-level
`docker/*.json`, and all of `k8s/`, 155 files across 4 commits) are deleted,
not merely superseded. See "Verification status" below for exactly what that
means was proven live versus offline versus never run, and "Losses and
leftovers" for what the deletion took with it. Design history:
`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md` through
`docs/superpowers/specs/2026-08-14-cleanup-cutover-design.md`.

`aws/` (Terraform, repo root) is the one tree this refactor deliberately did
**not** fold in — see "What `aws/` still is" below.

## Target layout

```text
deploy/
├── charts/microecom/   # Helm umbrella chart (infra + apps subcharts)
├── compose/            # docker-compose files
├── terraform/          # empty placeholder (.gitkeep only) — real AWS Terraform
│                        # lives at repo-root aws/, deliberately not moved here
│                        # (D2 — see "What aws/ still is" below)
├── secrets/            # canonical secret definitions and contexts
├── seed/               # canonical seed data
├── scripts/            # environment-aware deployment scripts
├── images/             # image build definitions (k8s/aws image builds)
├── k8s-jobs/            # standalone Jobs with no chart equivalent (kafka-connect
│                        # register, perftest seed) — relocated from k8s/, Task 5
├── k6-stress/           # k6 load-test scripts + Job manifests — relocated from
│                        # k8s/apps/base/k6-stress/, Task 3
├── k9s/                 # k9s monitor config for `make k9s`
├── platform-values/     # values for THIRD-PARTY platform charts (ingress-nginx),
│                        # installed by scripts/platform.sh — not part of the
│                        # umbrella chart. Sole input to `make k8s-platform`.
├── aws-infra/           # manifests + chart values + dashboards that
│                        # scripts/aws/infra-up.sh applies on EKS. Sole input to
│                        # `make aws-infra-up`. Recovered from k8s/infra/ in
│                        # Phase 8 — deliberately NOT folded into the umbrella
│                        # chart, because the chart's infra subchart would land
│                        # under release `microecom`, which aws-deploy.sh's next
│                        # upgrade (infra disabled) would delete. That
│                        # consolidation needs a release-name decision and a
│                        # phase that can test it on real AWS.
└── .env                # gitignored — k8s/aws user credentials (mail, etc.);
                         # moved from the deleted k8s/.env, see below
```

## What `aws/` still is

Repo-root `aws/` (Terraform: `aws/bootstrap`, `aws/main`, `aws/manifests`) is
the one tree this refactor deliberately left in place — spec D2 named it
explicitly out of scope, not silently skipped. Why: 58 files reference it
(`scripts/aws/RUNBOOK.md`, `up-all.sh`, `aws-deploy.sh`, `secrets.tf`, …),
so moving it is pure churn with no functional gain — it is already
env-scoped and already touched only by `aws-*` targets. The harder reason:
there is no way to verify a Terraform move without a real `terraform plan`
/`apply` against it, and this refactor's AWS leg has never been allowed to
touch real infrastructure (see "Verification status" below). Moving
state-bearing Terraform on faith, with no plan/apply to confirm nothing
broke, was judged a worse risk than leaving one tree outside the `deploy/`
umbrella. `deploy/terraform/` (see "Target layout" above) exists only as a
placeholder for a hypothetical future move.

## Losses and leftovers (Phase 8, 2026-08-14/15)

- **No replacement for `fetch-seed-images.sh`.** The script that originally
  generated `docker/seed-images/`'s 31 product JPEGs from
  `scripts/seed/products-manifest.json` was deleted with `scripts/seed/`
  and never ported. The 31 images are still committed at
  `docker/seed-images/<category>/<slug>.jpg` and are consumed fine by
  `deploy/scripts/seed.sh`'s image-upload leg — only *regeneration* is
  gone. `docker/seed-images/README.md` already documents the by-hand
  replacement procedure (pick/crop/compress an image per missing slug);
  this file doesn't repeat it, just confirms it's still the only way.
- **`k8s/.env` moved to `deploy/.env`.** Real credentials (mail, etc.),
  gitignored, never opened by anyone working on this refactor. Anyone with
  an old checkout who still has `k8s/.env` on disk (it was gitignored, so
  `git rm -r k8s/` never touched it) needs to move it to `deploy/.env` by
  hand — `k8s-app-secrets` and every `ENV=k8s`/`ENV=aws` script now read
  from there, not from the deleted path.
- **Four frozen oracles that cannot regenerate, ever, by design:**
  1. **Secrets goldens** (`deploy/secrets/tests/golden/`) — captured
     against a live Vault seeded by the now-deleted
     `docker/vault-configs/*.json` + `import-secrets.sh`.
  2. **Seed goldens** (`deploy/seed/tests/golden/`) — captured against the
     now-deleted old seed paths.
  3. **The AWS oracle**
     (`deploy/charts/microecom/tests/aws-oracle/oracle.yaml`) — a composed
     capture of the now-deleted `k8s/apps/overlays/aws` kustomize build.
  4. **`deploy/seed/tests/golden/docker-product.json`** — a byte-for-byte
     capture of the now-deleted `docker/product.json`, proving the seed
     renderer reproduces it exactly.

  All four are **committed evidence, not caches.** Their capture scripts
  refuse to re-run (see each test directory's own guard) because there is
  nothing left to re-capture *from* — the source tree is gone. A future
  failure in any of these suites means the chart, renderer, or resolver
  **changed** — never that the fixture went stale, because the fixture's
  source can no longer drift out from under it.

## Known gaps carried forward (raised, not fixed, in this phase)

*(none currently — see "Resolved since this section was written" below;
this heading stays in case a future task adds one)*

### Resolved since this section was written

**Resolved (2026-08-16): `make down` used to never stop MinIO.**
`scripts/infra/down.sh` used to list `vault/kafka/mongodb/redis/mysql.yml`
but omit `minio.yml`, so `make down && make up` could not produce a genuine
cold start of the whole stack. Fixed by adding `minio.yml` to `down.sh`'s
stop list. These are independent compose files with no cross-file
`depends_on`, so stop order is inert — it doesn't need to mirror `up.sh`.

**Resolved (2026-08-16): `scripts/aws/up-all.sh` had no confirmation
prompt** before a real, billed EKS `terraform apply` — anyone running it
fat-fingered straight into real spend. Fixed by adding a `Continue? [y/N]`
guard (mirroring `make nuke`, `Makefile:111`) immediately after the
script's `set -euo pipefail`/`ROOT=` lines, before anything else executes.
Non-TTY stdin **refuses** rather than proceeding — the absence of a human
is not consent — and `--yes` opts in for deliberate non-interactive runs
(see `scripts/aws/up-all.sh`'s usage comment and this repo's
`RUNBOOK.md`). This closes the fat-finger gap; it does not make the script
safe to run casually — it still creates real, billed infrastructure once
confirmed.

**Partially resolved (2026-08-16): `make bootstrap`/`make up` now detect and
heal the specific stale-registration scenario this bullet used to describe
as unhandled — but still deliberately never force-restart everything.**
`scripts/services/start.sh`'s `start_one()` (via `svc-start`, which both
`make bootstrap` and `make up` run) now checks, for every already-running
service, whether its Eureka registration's `ipAddr` still matches the
current host IP (`scripts/lib/eureka.sh`'s `eureka_staleness()`). On a
mismatch — the "new wifi network / VPN toggle leaves a stale registration"
case — it kills and restarts *just that service*; everything else stays on
the fast "already running, skip" path. Any ambiguous signal (Eureka
unreachable, host IP undeterminable, no matching instance) is treated as
"not stale," never as "restart everything" — the fail-safe direction is
always toward skipping, not toward surprise restarts.

The bullet's original headline is still literally true: `make bootstrap` /
`make up` still never *unconditionally* force-restart already-running
services, and that remains deliberate — `make svc-restart` is still the
tool for "restart regardless." Two things this check does **not** cover:
it only compares against Eureka's record, so services that never register
with Eureka (`eureka-server`, `orchestrator-service`,
`mock-paypal-service`, the `frontend` SPA) are never touched by it and
always take the "already running" fast path, host IP change or not; and it
only fires on the narrow stale-*registration* symptom, not on other reasons
a running process might be unhealthy.

## Unified verbs (`make <verb> ENV=<env>`)

Phase 6 adds one command dialect on top of the three that already exist
(compose's bare targets, `k8s-*`, `aws-*`) — thin wrappers, nothing removed
or moved. See
`docs/superpowers/specs/2026-08-09-unified-make-verbs-design.md`.

Only the verbs that are genuinely the same concept across more than one
environment are unified. Env-specific targets (`k8s-tunnel`, `k8s-ctx`,
`k9s`, the k6/observability targets, …) keep their old names — see the
design doc §2/§7 for what was deliberately left alone.

| verb | compose | k8s | aws |
|---|---|---|---|
| `bootstrap` | `bootstrap-compose` | `k8s-bootstrap-helm` | `aws-all` |
| `deploy` | `svc-start` | `k8s-apps-helm` | `aws-deploy-apps` (Phase 7) |
| `seed` | ✅ (Phase 5, `deploy/seed/`) | ✅ | ✅ |
| `secrets-seed` | ✅ (Phase 4, `deploy/secrets/`) | ✅ | ✅ |
| `status` | `status-compose` | `k8s-status` | *(unmapped, fails)* |
| `teardown` | `down` | `k8s-down` | `aws-down` |
| `rebuild` | `svc-restart` | `k8s-rebuild` | *(unmapped, fails)* |
| `image-build` | *(unmapped — fails by construction)* | `k8s-build` | `aws-push` |

```bash
make deploy ENV=compose        # -> svc-start
make status ENV=k8s            # -> k8s-status
make rebuild ENV=compose svc=mock-paypal-service   # -> svc-restart svc=...
make bootstrap ENV=aws         # -> aws-all (spends real money — see below)
```

**The `ENV=` default is `compose`, but it is not global.** There is no
`ENV ?= compose` anywhere in the Makefile — that was tried in Task 2 and
reverted because it silently overrode the *other* `$(or $(ENV),…)` defaults
that `k9s`, `k8s-use`, `k8s-platform`, `k8s-infra-helm` and `k8s-apps-helm`
already had (`local` / `local-k8s`). Instead the `compose` default is scoped
to just the six verbs above, via `$(or $(ENV),compose)` inside the
`dispatch` macro itself. `make deploy` with no `ENV=` behaves exactly like
`make deploy ENV=compose`; it says nothing about what any other bare-`$(ENV)`
target defaults to.

**`bootstrap` and `status` are dispatchers, not new targets.** Both names
already existed as compose target names before Phase 6. Rather than rename
20+ years of muscle memory, their original recipes (and, for `bootstrap`,
its nine load-bearing prerequisites, in the same order) were moved verbatim
to `bootstrap-compose` / `status-compose`, and `bootstrap` / `status` became
dispatchers like the other four verbs. `make bootstrap` and `make status`
with no `ENV=` expand **identically** to what they expanded to before this
phase — proven against the baselines captured before the change (see
Verification status below).

**`image-build ENV=compose` fails on purpose, exit non-zero.** Compose runs
every service as a JVM process launched from a Maven artifact — it builds no
container images at all, so there is nothing for the verb to do. An empty
success would be indistinguishable from a real one, so the dispatch table
simply has no compose mapping for `image-build`, and the generic
"unmapped pair" guard fires:

```
$ make image-build ENV=compose
make image-build: not applicable for ENV=compose — compose builds no container
images (services run as JVM processes from Maven artifacts — see `make build`)
make: *** [image-build] Error 1
```

`make build` (plain Maven install, env-invariant) is unrelated and unchanged
by any of this — see the design doc's "`build` is not a deployment verb".

### Test suites (`deploy/scripts/tests/`)

```bash
make verb-test-equivalence   # Layer A — offline, all three envs, any cwd
make verb-live-test          # Layer B — live compose run (deploy/seed/status/rebuild)
```

`verb-test-equivalence` runs `deploy/scripts/tests/verb-equivalence-test.sh`:
for every mapped (verb, env) pair it resolves the dispatch target and diffs
its `make -n` expansion against a captured baseline of the old target, plus
asserts the declared `image-build ENV=compose` failure and that the five
pre-existing bare-`$(ENV)` targets still resolve their own defaults. No
backend, no credentials, no cluster.

`verb-live-test` runs `deploy/scripts/tests/verb-live-test.sh`: the real
compose verb set — `deploy` → `seed` → `status` → `rebuild` — against a
running stack, each asserted to exit 0, with an HTTP check through the
gateway before and after. It deliberately does **not** run
`teardown ENV=compose`, because that would stop the stack other work in this
repo depends on; `teardown`'s dispatch mapping is proven by the offline
suite instead.

**`deploy/scripts/tests/capture-baseline.sh` is the oracle behind
`verb-test-equivalence`, and it refuses to overwrite what it already
captured.** A bare re-run only fills in a baseline file that doesn't exist
yet; skip `FORCE=1` and it leaves every existing `baseline/*.txt` untouched.
`baseline/bootstrap.txt` and `baseline/status.txt` specifically are **frozen,
pre-conversion evidence** — captured *before* Task 3 of the unified-verbs
work turned `bootstrap`/`status` into dispatchers, from when those names
still held their real recipe. They are the only proof the move was verbatim,
so they are never regenerated, not even with `FORCE=1` — the ongoing targets
are `bootstrap-compose`/`status-compose` instead. This guard exists because
an earlier bare re-run silently overwrote both files with the dispatcher's
one-line expansion instead of the original recipe (see task-4-report.md) —
the fourth instance in this project of an oracle that can be invalidated by
regenerating it (Phase 4's secrets goldens, Phase 5's seed goldens, and the
AWS oracle below are the others).

### Verification status

**Proven live, compose only.** `make verb-live-test`
(`deploy/scripts/tests/verb-live-test.sh`) ran the real sequence against the
running dev stack: `make deploy ENV=compose` (all 11 services already up,
resolved as a no-op start), `make seed ENV=compose` (pre-apps stage: 40
`api_role` docs + 30 `product` docs + 30 `productQuantityHistory` docs + 30
objects, all re-imported clean), `make status ENV=compose` (11/11 running),
and `make rebuild ENV=compose svc=mock-paypal-service` (stop + cold start,
back up in two 5s poll cycles). All four exited 0. The gateway→product-service
storefront route (`GET /product-service/v1/products`) returned `200` both
before and after the run, and mock-paypal-service's own actuator health
returned `200` after its rebuild. `teardown ENV=compose` was **not** run
live — see "Test suites" above for why; its expansion is covered by the
offline suite below.

**Proven offline, all three envs.** `make verb-test-equivalence`
(`deploy/scripts/tests/verb-equivalence-test.sh`): **21 checks, 21 passed, 0
failed** — 15 verb×env dispatch mappings (every cell in the table above that
isn't `✅`/unmapped, including Phase 7's `deploy`/`aws` → `aws-deploy-apps`,
added when `VERB_deploy_aws` was filled in), the declared `image-build
ENV=compose` failure, and the 5 bare-`$(ENV)` default resolutions (`k9s`,
`k8s-use`, `k8s-platform`, `k8s-infra-helm`, `k8s-apps-helm`). No backend, no
credentials, no cluster; runs from any cwd.

**Proven live, k8s (Phase 8, superseding the "NOT proven" verdict earlier
phases left here).** A minikube cluster (profile `microecom`) was rebuilt for
Phase 8 and `deploy ENV=k8s` (→ `k8s-apps-helm`) deployed successfully —
10/10 app pods Running, 0 restarts, catalog returning 30 products through the
gateway. **`bootstrap ENV=k8s` (→ `k8s-bootstrap-helm`) was run end-to-end
from a torn-down cluster exactly once**, uninterrupted, ~25 minutes,
`make` exit 0, helm release `deployed` at revision 2 (infra install + apps
upgrade), all 10 app pods Running with 0 restarts, catalog 30/30 products
with `image_url` populated. Getting there took three release-breaking bugs
found and fixed by that same from-scratch run (a `progressDeadlineSeconds`
too low for a cold Confluent image pull, `k8s-apps-helm` deleting the whole
infra release out from under itself, and an HPA/`spec.replicas` ownership
conflict) — see `deploy/CLAUDE.md` migration note and the SDD ledger
(`.superpowers/sdd/progress.md`, Task 7) for the full account. `status
ENV=k8s`, `rebuild ENV=k8s`, `image-build ENV=k8s` remain verified only by
Layer A's offline expansion diff — the live gate exercised `deploy` and
`bootstrap`, not every k8s-mapped verb individually.

**NOT proven: `ENV=aws` has still never been deployed, full stop.** No EKS
cluster has ever been created, `terraform apply` has never run against
`aws/main`, and every aws-mapped verb — `deploy ENV=aws` (Phase 7,
`aws-deploy-apps`), `bootstrap ENV=aws` (`aws-all`), `teardown ENV=aws`
(`aws-down`) — is verified only by an offline `helm template` render diffed
against a composed oracle (see "AWS cut-over" below), never by a real apply.
**This is the fifth consecutive phase of this refactor to ship an
unexercised AWS transport** (Phases 1, 3, 4, and 7 each shipped one before
it). `status ENV=aws` and `rebuild ENV=aws` remain deliberately **unmapped**
and fail by design, the same way `image-build ENV=compose` does, just
without a `_WHY` message yet. Deciding whether to spend the money on a real
`aws-all` run is explicitly out of scope here (spec D2) — don't read more
into the evidence above than what it actually measured, the same caveat
every earlier phase of this refactor needed.

Also unproven live, but by construction rather than by omission:
`scripts/aws/up-all.sh`'s seed calls (Step 4/5/7/8/9) and its apps-deploy
step (Step 6) were repointed in Phase 8 Task 6 onto the canonical
`deploy/scripts/seed.sh` / `secrets-seed.sh` / `aws-deploy.sh` **without
ever executing `up-all.sh` itself** — the repoint is justified by the seed
equivalence suite's `aws` leg matching exactly (13 matched / 2
declared-different, both compose-only — see "Canonical seed data" below),
not by a real run of the script that calls it.

## Canonical secrets (`deploy/secrets/`)

`deploy/secrets/<service>.yaml` plus `deploy/secrets/contexts/<env>.yaml` are
the single source of truth for the ~90 Spring config keys previously hand-kept
in sync across `docker/vault-configs/*.json`, `k8s/infra/jobs/03-vault-seed/`,
and `scripts/aws/seed-secrets.sh`. Three targets operate on this tree:

```bash
make secrets-validate              # consistency checks only — no backend,
                                    # no credentials, safe to run anywhere
make secrets-render ENV=compose    # resolve only — writes
                                    # deploy/.run/secrets-<env>.json (mode 600),
                                    # touches no backend
make secrets-seed ENV=compose      # resolve, then push to the env's backend
```

`ENV` is one of `compose`, `k8s`, `aws` (default `compose`).

Each env that delivers user-owned credentials by env file
(`userCredDelivery: envfrom` — `compose` and `k8s`) must document every
`owner: user` variable in **its own** `.env.example`: `docker/.env.example` for
compose, `deploy/.env.example` for k8s. `secrets-validate.sh` check 3 enforces
this per-env rather than against the union of both files, because a variable
documented in only one of them is not documented for the other — that union is
what let the mail credentials ship missing from `docker/.env.example`. `aws` is
exempt: `userCredDelivery: backend` means the value reaches the pod through AWS
Secrets Manager and no env file is involved.

A `<file:…>` reference (used by `application.jwk`) must point inside
`deploy/secrets/`, and its **trailing newlines are stripped**. That is
deliberate: the gateway caches JWKS by `kid`, so a single newline appended by
an editor-on-save would invalidate every token in the system — and it would do
so in all three envs at once, which is exactly the case `secrets-validate.sh`
check 4 (envs compared against each other) cannot see.

**`secrets-seed` always overwrites.** This is a deliberate design decision,
not an oversight: the canonical file is authoritative, so a value hand-edited
directly in Vault or AWS Secrets Manager does **not** survive the next seed —
it is silently replaced by whatever `deploy/secrets/` currently resolves to.
If you need a value to persist, put it in the canonical file, not the
backend. There is no "skip if exists" mode.

Per-env specifics:

- **`ENV=compose`** pushes to the local Vault (`VAULT_ADDR`, default
  `http://localhost:8200`) over its HTTP API. It needs `VAULT_TOKEN` in the
  environment — run `make vault-login` first, or export it yourself.
- **`ENV=k8s`** opens a temporary `kubectl -n infra port-forward svc/vault
  18200:8200` for the duration of the push and tears it down on exit
  (success, failure, or interrupt). The in-cluster Vault runs in dev mode
  with the fixed root token `root`, so no token lookup is needed unless you
  override `VAULT_TOKEN` yourself.

  **You must name the target cluster.** Seeding writes to whatever cluster
  kubectl points at, and an ambient `current-context` left over from
  unrelated work is a real hazard — during this branch's own verification it
  happened to be a production-adjacent managed cluster. So the context is
  never inferred: pass `--context NAME` or set `KUBE_CONTEXT`, and if it does
  not match `kubectl config current-context` the seed refuses and exits
  non-zero before touching anything. There is no default — no context name
  this repo could assume would be safe. The same name is passed to
  `kubectl port-forward`, so the context checked and the context written to
  cannot diverge.

  ```bash
  make secrets-seed ENV=k8s KUBE_CONTEXT=microecom
  # or
  bash deploy/scripts/secrets-seed.sh --env k8s --context microecom
  ```

  `--dry-run` (`make secrets-render ENV=k8s`) touches no cluster and is
  exempt.
- **`ENV=aws`** reads `deploy/.run/terraform-outputs.json`, a cached copy of
  `terraform output -json` from `aws/main` (which keeps its real state in an
  S3 remote backend — there is no local file whose mtime can be trusted
  automatically). The cache is generated on first use and warned about once
  it is over 24h old, but never auto-refreshed — an implicit `terraform`
  call mid-seed is exactly the coupling this design removes. The Makefile
  target does not expose `--refresh-tf`; call the script directly to force a
  refresh:
  ```bash
  bash deploy/scripts/secrets-seed.sh --env aws --refresh-tf
  ```
  Any resolve against `ENV=aws` — including `--dry-run` — needs terraform
  outputs from somewhere: pass `--tf-outputs FILE` to point at one directly
  and skip the cache (and terraform) entirely, which is how an offline or CI
  run avoids touching terraform at all:
  ```bash
  bash deploy/scripts/secrets-seed.sh --env aws --dry-run \
    --tf-outputs deploy/secrets/tests/fixtures/terraform-outputs.json
  ```

The old paths — `make vault-import`, the `03-vault-seed` Job, and
`scripts/aws/seed-secrets.sh` — coexisted with `secrets-seed` through Phases
4-7 while both were proven equivalent against a live backend. Phase 8
(2026-08-14/15) deleted them: the `vault-import` Make target, `scripts/vault/
import-secrets.sh`, `docker/vault-configs/`, `k8s/infra/jobs/03-vault-seed/`
(with the rest of `k8s/`), and `scripts/aws/seed-secrets.sh` are all gone
from the working tree. `secrets-seed` is now the **only** path — not merely
the recommended one.

### Verification status

**Offline, all three envs — equivalence proven.** `equivalence-test.sh`
resolves every service in every env and diffs it against a capture of what
each old path would write, taken by running the real old scripts with fake
`vault` / `aws` / `terraform` binaries on `PATH`. 33 passed, 0 failed,
0 pending. This covers `aws` too, which cannot otherwise be exercised
without an account.

**Live, compose — transport and content proven end to end.** Seeded with
`make secrets-seed ENV=compose` against a running dev Vault, then every path
read back over the HTTP API and compared:

- all 11 paths byte-identical to the golden capture (90 keys);
- and, because Vault KV v2 keeps versions, a direct comparison of what the
  **old** `make vault-import` actually wrote (v1) against what the **new**
  seeder wrote (v2) on the same live backend: **zero value differences, zero
  keys added, exactly four keys removed** — `_comment`,
  `_comment_mail_creds`, `_comment_mock_paypal`, `_comment_paypal_creds`.

Those four are inert JSON pseudo-comments. `docker/vault-configs/*.json` has
no comment syntax, so documentation was written as `_comment`-prefixed keys,
and `import-secrets.sh` POSTs the file verbatim — so they have always been
seeded into Vault as properties nothing reads. The canonical YAML carries
that documentation as real YAML comments instead. This is the one intended
behavioural difference in the whole phase.

**Not yet proven, deliberately:**

- **`make up` after a compose seed** was not run. The seeded bytes are
  identical to the old path's apart from four properties no code reads, so
  service startup cannot differ — but that is an inference, not a
  measurement.
- **The k8s transport** (`make secrets-seed ENV=k8s`, which port-forwards to
  the in-cluster Vault) has not been run against a live cluster.
- **The aws transport** has never written to AWS Secrets Manager. It is
  verified only against fixture terraform outputs with a shimmed `aws` CLI.
  Live AWS seeding is Phase 7.

## Canonical seed data (`deploy/seed/`)

`deploy/seed/{api_role,product,product-quantity-history}.json` plus
`deploy/seed/ecommerce.sql` are the single source of truth for the seed data
previously hand-kept in sync across `docker/*.{sql,json}`,
`k8s/infra/jobs/{01-mysql-seed,02-mongo-seed}/`, `scripts/seed/k8s-inventory.sh`,
and their aws counterparts. Two targets operate on this tree, mirroring the
canonical-secrets shape above:

```bash
make seed-render ENV=compose STAGE=pre-apps    # resolve only, touches no backend
make seed ENV=compose STAGE=pre-apps           # resolve, then push
```

`ENV` is one of `compose`, `k8s`, `aws`; `STAGE` is `pre-apps` or `post-apps`.
Both default to `compose`/`pre-apps`.

### The two stages

- **`pre-apps`** — mongo (`api_role`, `product`, `productQuantityHistory`)
  plus product images (object storage: MinIO on compose/k8s, S3 on aws). Must
  run **before** the apps start: product-service / inventory-service need
  data to react to.
- **`post-apps`** — `ecommerce.sql` (`account`/`account_role`/`role`/`user`),
  then the derived `inventory_product`/`product_quantity_history` rows, then
  a **reconcile** that restarts inventory-service so `AvailableStockSeeder`
  rebuilds the Redis `productAvailable:*` counters from the ledger just
  written. Must run **after** the apps: `ecommerce.sql` is data-only (0
  `CREATE TABLE` — its only `localhost` is an inert `mysqldump` header
  comment) because the schema comes from Hibernate `ddl-auto` at service
  boot. Seeding first fails partway through with `ERROR 1146` — the failure
  mode `k8s/CLAUDE.md` documents. `post-apps` therefore opens with a
  precondition that checks every table any `INSERT` targets against
  `information_schema.tables` and refuses to write a single row if any is
  missing, naming the first missing one.

### `post-apps` is safe to re-run

`make seed ENV=… STAGE=post-apps` is idempotent. `account`, `inventory_product`,
and `product_quantity_history` are each gated on their **own** row-count check
(`SELECT COUNT(*) FROM <table>`) and the import for that table is skipped with
a warning if it already holds rows — a re-run never double-inserts. The three
gates are deliberately **per-table**, not one shared gate: an earlier version
of this script gated `inventory_product` and `product_quantity_history`
together, which had a silent-failure window — if the connection dropped after
`inventory_product` committed but before `product_quantity_history` did, a
retry would see `inventory_product` already populated, skip **both** imports,
and leave the ledger permanently half-empty while every command up to and
including the reconcile still reported success. Splitting the gate closes that
window: a retry after a partial failure imports exactly the table that's still
missing.

### `--replace`

`deploy/scripts/seed.sh --replace` (a `pre-apps`-only concept) opts into the
**OLD compose path's** behaviour of DROPPING the `product` and
`productQuantityHistory` Mongo collections before import. The default
everywhere is `mongoimport --mode upsert` (matches on `_id`, never drops the
collection), so a plain re-run never silently wipes a locally-added product.
Only compose's old seed scripts ever dropped these collections — the old k8s
and aws paths never did — so `--replace` restores a **compose-specific** old
behaviour; offering the same flag for k8s/aws is a genuinely new capability
there, not a restoration.

### k8s context requirement

Same rule as `secrets-seed`: `ENV=k8s` (and `ENV=aws`'s mongo leg in
`pre-apps` and mysql leg in `post-apps`, both of which go through `kubectl`)
require **naming the target cluster** — pass `--context NAME` or set
`KUBE_CONTEXT`. There is no default; seeding writes to whatever cluster
`kubectl` happens to point at, and an ambient `current-context` left over
from unrelated work is a real hazard (see the canonical-secrets section
above — it happened once, mid-refactor, against a production-adjacent
cluster). `--dry-run` (`make seed-render`) touches no cluster and is exempt.
aws's image leg (`aws s3 cp`) never touches `kubectl` and is exempt too.

```bash
make seed ENV=k8s STAGE=pre-apps KUBE_CONTEXT=microecom
# or
bash deploy/scripts/seed.sh --env k8s --stage pre-apps --context microecom
```

### `ENV=aws` and `--tf-outputs`

Same mechanism as `secrets-seed.sh`: `ENV=aws` resolves against a cached
`terraform output -json` from `aws/main` (`deploy/.run/terraform-outputs.json`
by default, generated on first use). Pass `--tf-outputs FILE` to point at a
different outputs file directly — the Makefile target doesn't expose this
flag, so call the script itself:

```bash
bash deploy/scripts/seed.sh --env aws --stage pre-apps --dry-run \
  --tf-outputs deploy/secrets/tests/fixtures/terraform-outputs.json
```

This is how the offline equivalence suite exercises `aws` without touching
real terraform state, and how a CI run would too.

### Reconcile

`seed_render.py`'s reconcile signal is a single env-invariant token
(`restart:inventory-service`); `seed.sh`'s `post-apps` stage maps it to a
per-env action: `kubectl rollout restart deploy/inventory-service` (+
`rollout status`) on k8s/aws, and `scripts/services/stop.sh` +
`start.sh inventory-service` on compose. Compose has no `restart.sh` and
none is added — inventory-service there is a JVM process under
`scripts/services/*`, not a container, so there is nothing for a
`docker restart`-style command to target.

**Skip vs. failure — these are different outcomes, not the same "nothing
happened":**

- **Skipped (a warning, exit 0 as far as this step is concerned):** the
  inventory-service workload genuinely isn't there yet — no k8s/aws
  Deployment, or (compose) no pidfile *and* `lsof` confirms nothing is
  listening on `:6969`. This is the expected shape of running `post-apps`
  standalone before the apps exist, and is not treated as an error.
- **Failure (`FAIL=1`, `make seed` exits non-zero):** the restart/rollout
  itself fails or times out. `kubectl rollout restart` + `rollout status
  --timeout=300s` on k8s/aws, or `stop.sh` + `start.sh inventory-service` on
  compose — either leg's exit code is checked, and a failure there prints
  the actual consequence: *"Redis productAvailable:\* counters were NOT
  rebuilt; every order will fail 'Insufficient available stock' until this
  is fixed and the seed is re-run."* The precondition/import steps ahead of
  the reconcile can all have succeeded; only the reconcile itself failed.
- **Failure, compose only — status genuinely unknown:** if there's no
  pidfile *and* `lsof` isn't installed, compose has no way to tell running
  from not-running. Rather than guess (and risk silently skipping a real
  reconcile that was needed), this case also sets `FAIL=1` and prints
  "install lsof, or ensure logs/pids/inventory-service.pid is current, then
  re-run" — a deliberately loud refusal, not folded into the ordinary skip
  path above.

In every failure case, re-running `post-apps` is the fix: the precondition
and the per-table import gates (above) make it safe to retry, and a
successful retry's reconcile rebuilds the counters from the ledger that's
already there.

### Test suites

Three suites cover this tree, each named by full path — `deploy/seed/tests/`
has its own `equivalence-test.sh`, and `deploy/secrets/tests/` (Canonical
Secrets, above) has a **different, unrelated** suite with the same basename;
always disambiguate by path, never say "run equivalence-test.sh" alone.

```bash
make seed-test-render        # renderer unit tests + the compose/product.json
                              # byte-for-byte invariant. No backend, no
                              # credentials, no cluster.
make seed-test-equivalence   # Layer A — offline equivalence across all three
                              # envs against captured goldens. No backend, no
                              # credentials, no cluster; the only verification
                              # `aws` gets.
# make seed-live-verify        # RETIRED in Phase 8 — always exits 2 now.
                              # It was a live old-way-vs-new-way state diff, and
                              # Phase 8 deleted the old way, so there is nothing
                              # left to diff against. The script refuses rather
                              # than run, because diffing the new path against an
                              # empty snapshot would report a FALSE MATCH. The
                              # goldens it produced live on in seed-test-*.
```

### Verification status

**Proven live on compose — both stages end to end.** `make seed ENV=compose
STAGE=pre-apps` then `make seed ENV=compose STAGE=post-apps` against a
running dev stack, and independently via `make seed-live-verify ENV=compose`
(`deploy/seed/tests/live-verify.sh`), which reseeds old-way vs new-way and
diffs live content. The headline fix was measured directly, not inferred, and
it has **two** manifestations, both asserted as declared asymmetries:

- **Redis `productAvailable:*` counters** — absent under the old path
  (compose never restarts inventory-service); after flushing Redis and
  re-running `post-apps`, 27 keys landed, summing to **578** — exactly
  matching `SELECT SUM(quantity) FROM product_quantity_history`.
- **`inventory_product.stock`** — `NULL` for every row under the old path
  (the column has no `DEFAULT` and the seed `INSERT` never mentions it); the
  same inventory-service restart that rebuilds the Redis counters also
  backfills this column via `AvailableStockSeeder`
  (`GREATEST(0, SUM(product_quantity_history.quantity))`), verified to match
  the ledger for all 30 rows on live compose.

**Proven offline for all three envs.** `make seed-test-equivalence`
(`deploy/seed/tests/equivalence-test.sh`) resolves every env and diffs it
against a capture of what the three OLD seed paths actually wrote — it has no
stage concept of its own; the equivalence is keyed on the rendered artifact
set, and both stages' artifacts (mongo/objects for pre-apps; mysql for
post-apps) are covered because `render_all()` produces all of them together
in one pass: **13 matched, 2 declared-different, 0 unexplained**. The two
declared differences are both compose-only and both intentional (the
`--replace`-gated drop behaviour and the new reconcile step, neither of which
the old compose scripts had) — this suite needs no backend, no credentials,
and no cluster, and is the only verification `aws` gets at all.

**NOT proven, and this is stated plainly rather than left to be inferred:
the k8s and aws transports have never been executed.** The minikube cluster
used earlier in this phase was destroyed mid-phase, and no cluster exists as
of this writing — every `kubectl exec` / `kubectl run` leg for k8s and aws
is code-reviewed only, never run against a live cluster. `aws` has never
written to a real RDS, S3, or EKS at all; its correctness rests entirely on
the offline equivalence suite against fixture terraform outputs. Phases 1, 3,
and 4 of this refactor each shipped with an unexercised transport leg — don't
read more into the evidence above than what it actually measured.

## Current minikube workflow

```bash
make bootstrap ENV=k8s   # -> k8s-bootstrap-helm (cluster + infra + images + seed + apps)
make k8s-tunnel
make k8s-status
make k8s-down
```

`k8s-bootstrap-helm` is the **only** k8s bring-up path — Helm, not
kustomize. The old kustomize path (`k8s-bootstrap`, `k8s-infra`, `k8s-apps`,
`k8s-apps-down`, and the `k8s/` tree they drove) was deleted in Phase 8
alongside the rest of the cleanup; see "Helm umbrella chart" and "Helm apps
subchart" below for what it replaced and why the two paths could never
coexist on one cluster while both existed.

Host image builds push through `localhost:5001`; minikube nodes pull those
repositories through the registry addon's `localhost:5000` proxy.

## Helm umbrella chart (Phase 2 path)

`deploy/charts/microecom` is a Helm umbrella chart that renders every
infrastructure workload previously brought up by the now-deleted
`k8s/infra/install.sh` (MySQL + replicas, MongoDB, Redis, Kafka + Schema
Registry + Connect + exporters, MinIO, VictoriaMetrics, Grafana, Vault) via
an `infra` subchart, plus a post-install replication hook Job, a dashboards
ConfigMap, and AWS-gated resources.

```bash
make k8s-platform     # cluster-wide platform charts (ingress-nginx, metrics-server)
                      # + vendors the infra subchart's Helm dependencies
make k8s-infra-helm   # brings up infra via the umbrella chart (runs k8s-platform first)
```

**`k8s-infra-helm` is the only infra bring-up path.** Through Phases 2-7 it
ran *alongside* the older kustomize path, `k8s-infra` (`k8s/infra/
install.sh`, plain `kubectl apply -f`) — the two were never safe to run
against the same already-provisioned cluster (Helm 3+ refuses to adopt
kustomize-created objects that carry none of its ownership annotations), so
picking one path per cluster was an operational rule throughout that
window. Phase 8 deleted `k8s-infra` and the `k8s/` tree it drove, which
removed the alternative rather than the rule — there is now nothing left to
pick between.

### `--dry-run` / `helm template` keyfile hazard

`lookup` returns empty during `helm template` and any `--dry-run`, so a dry
run always renders a **fresh** `mongodb-keyfile`. Rendering to *read* the
output is fine. Piping a dry-run render into a live cluster is not:
`helm template … | kubectl apply -f -` rotates the keyfile and breaks an
already-initialized MongoDB replica set. Only `helm upgrade --install`
(no `--dry-run`) is safe to actually apply.

### Dependency vendoring

`helm dependency update` does **not** recurse into subcharts — it must be run
directly against `deploy/charts/microecom/charts/infra`, using `build` (not
`update`) so `Chart.lock` stays authoritative. `platform.sh` does this, which
is why `k8s-infra-helm` depends on `k8s-platform`. The resulting
`charts/infra/charts/*.tgz` files are gitignored and rebuilt from
`Chart.lock` on demand — never commit them.

### `--wait` timeouts

`k8s-infra-helm` uses `--timeout 30m`, not the more obvious `15m` or `20m`.
The `mysql-replication` post-install hook Job carries its own **derived**
`activeDeadlineSeconds` — `(mysqlReplica.replicas + 1) * mysqlReplica.waitTimeout
+ 60`, which at the defaults (`replicas: 2`, `waitTimeout: 300`) renders to
**960s (16m)**. The layering has to put the *inner, more specific* bound
first: the Job's own deadline should fire and emit its readable
`ERROR: <host> unreachable after 300s` diagnostic before Helm's `--timeout`
gives up.

These two windows are **additive, not independent**: Helm's sequence is
`create resources -> wait for readiness (--wait) -> post-install hooks`, so
the post-install `mysql-replication` hook is not even created until *every
other* resource is Ready — including schema-registry/kafka-connect, whose
cold Confluent image pull (~1.8 GB combined) alone takes ~5.5 minutes (~330s).
Worst case: `330s` (cold-pull wait phase) `+ 960s` (hook's own deadline)
`≈ 1290s (~21.5m)`. `15m` (900s) and even `20m` (1200s) are both tighter than
that compound worst case — Helm would abandon the wait *before* the hook
could ever emit its own diagnostic, the exact inversion this timeout exists
to prevent. `30m` = the 960s hook deadline + ~330s cold-pull + headroom.
`deploy/charts/microecom/tests/render-test.sh` asserts that the Makefile's
`--timeout` (parsed from the recipe) stays `>= activeDeadlineSeconds + 330s`
(parsed from the rendered hook Job), so a future change to either
`mysqlReplica.replicas`/`waitTimeout` or the Makefile literal that lets them
drift apart fails the render-test suite instead of failing silently on a
cold cluster.

### `global:` keys collide with upstream charts

Helm merges the umbrella's `global:` block into **every** subchart, vendored
upstream dependencies included. Several `global.*` paths are de-facto upstream
conventions, so picking one for our own use silently rewrites a third-party
chart's behaviour.

Our app-image registry therefore lives at **`global.appImage.registry`**, not
`global.image.registry`. victoria-metrics-common's `vm.internal.image` falls
back to `global.image.registry` whenever the per-app `image.registry` is empty,
so under the natural name `vmsingle` rendered as
`localhost:5000/victoriametrics/victoria-metrics:v1.144.0` and sat in
`ImagePullBackOff`. Because `helm --wait` waits for **every** resource to be
Ready before running post-install hooks, that one unpullable pod meant the
`mysql-replication` hook Job was never created and the release hung at
`pending-install` until the timeout — a failure mode with no obvious link to
its cause.

Known reserved spellings to avoid: `global.image.*` (victoria-metrics family),
`global.imageRegistry` and `global.imagePullSecrets` (grafana, bitnami),
`global.storageClass` (bitnami). When adding a `global.*` key, grep the
vendored charts for it first:

```bash
for t in deploy/charts/microecom/charts/infra/charts/*.tgz; do
  tar -xzOf "$t" --wildcards '*/templates/*' '*/values.yaml' | grep -o 'global\.[A-Za-z.]*'
done | sort -u
```

`render-test.sh` asserts no infra image carries the local registry, which is
what locks this in.

### Docker Hub rate limiting looks like a chart failure

A fresh 4-node cluster pulls ~10 upstream images in parallel and can exhaust
Docker Hub's anonymous quota. Hub answers an exhausted quota with **401
`unauthorized: authentication required`**, not the 429 `toomanyrequests` you
would expect, so the pod event reads like a credentials problem. It is
per-IP — the host's own `docker pull` fails identically, and
`~/.docker/config.json` holds no Hub login on either side.

Downstream, the old kustomize `k8s/infra/install.sh` (deleted in Phase 8)
used to abort at its `kubectl wait` with a bare `error: timed out waiting
for the condition`, and every stage *after* that wait was never applied.
The cluster then looked "mostly up" while schema-registry, kafka-connect,
vault, VictoriaMetrics and Grafana were simply absent. Re-running was
idempotent and resumed — one bring-up needed three invocations of
`make k8s-infra` (today: `make k8s-infra-helm`) to get through. The same
Docker Hub exhaustion hazard applies to `k8s-infra-helm` today; it also
retries idempotently.

It is transient and self-healing: kubelet backoff eventually lands every
image. Waiting is the correct first response. To skip Hub entirely, pre-load
from the host cache before installing:

```bash
for img in $(grep -rhoE 'image: *"?[a-z0-9][^ "]*' \
               deploy/charts/microecom/charts/infra/templates/ \
             | sed 's/image: *"*//' | sort -u); do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
  minikube -p microecom image load "$img"
done
```

This only works for tags the host actually has, so it is worth doing right
after `make k8s-cluster-up`. Bumping a pinned tag that the local cache does
not carry converts a soft dependency on Docker Hub into a hard one — a stale
cache holding `cp-kafka-connect:7.7.1` does nothing for a chart pinned to
`7.6.1`. With all ten images pre-loaded, `make k8s-infra-helm` completes in
about 4 minutes instead of stalling on pulls.

### Fast check — no cluster required

`deploy/charts/microecom/tests/render-test.sh` renders the chart with `helm
template` and asserts on the output; it needs no cluster and no network. Run
it after any chart change:

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

**Prerequisite: vendor the dependencies first**, or this "fast check" gives a
false green. `helm template` does **not** error on a missing vendored
dependency (see "Dependency vendoring" above) — it exits 0 and silently omits
every object from any subchart that isn't vendored yet. On a fresh clone (or
CI) that has never run `make k8s-platform` / `helm dependency build`, the
render-test assertions for vault/grafana/vmsingle/kube-state-metrics fail
loudly (not silently) for the "chart not vendored" reason, which a first-time
reader could mistake for a real regression rather than a missing setup step:

```bash
helm dependency build deploy/charts/microecom/charts/infra
```

## Helm apps subchart (Phase 3 path)

`deploy/charts/microecom/charts/apps` renders the ten application workloads
previously brought up by the now-deleted `kubectl apply -k
k8s/apps/overlays/local`: nine JVM services plus the storefront SPA, with
their Services, five HPAs, the gateway's discovery RBAC, the nginx
Ingresses, and — on AWS — the ExternalSecrets, `app-config` configtree
mounts and S3 IRSA ServiceAccounts.

```bash
make k8s-apps-helm   # the only apps path now (ENV=aws selects envs/aws.yaml)
```

The subchart is gated `apps.enabled: false` in the umbrella `values.yaml`, so
`make k8s-infra-helm` renders exactly what it rendered in Phase 2.
`k8s-apps-helm` passes `--set apps.enabled=true`.

### The apps paths WERE alternatives too — same rule, different reason (historical)

Through Phases 3-7, `k8s-apps-helm` ran alongside the older kustomize path,
`k8s-apps` (`kubectl apply -k k8s/apps/overlays/local`) — for a sharper
reason than the infra rule above: the base manifests used a bare
`app: <name>` as their `spec.selector.matchLabels`, the chart uses
`app.kubernetes.io/name`, and **`spec.selector` is immutable on a
Deployment**. Neither could be installed over the other; a cluster had to be
torn down to switch between them. Phase 8 deleted `k8s-apps`, `k8s-apps-down`,
and the `k8s/apps/` tree they drove, so there is nothing left to switch
between — `k8s-apps-helm` is simply the apps path now.

### One shared template, variation in values

Per-service blocks under `apps:` are merged over a chart-level `defaults:` block.
Three rules are load-bearing, and breaking any of them fails quietly:

1. **`deepCopy` before every merge.** Sprig's `mergeOverwrite` wraps mergo's
   in-place API and mutates its destination. Without `deepCopy`, the first
   service's overrides contaminate `.Values.defaults` permanently, and because
   `range` over a map iterates in sorted key order, every service sorting after
   it inherits them — `gateway` sorts 4th of 10, so its `initialDelaySeconds: 45`
   leaks into the six after it. `render-test.sh` asserts order-service still gets
   60.
2. **`enabled` is read from the raw values block, before the merge.** Mergo
   treats falsy values as absent, so `enabled: false` cannot survive a merge
   against a default of `true`.
3. **`env` is merged outside mergo, key by key.** For the same reason: mergo
   skips nil source values, so a per-key `null` could not unset an inherited
   variable. `env` is a map rather than a list because YAML lists cannot merge
   element-wise; the list-of-`{name,value}` shape appears only at render time,
   emitted by a sorted `range`.

### `managementPort` is listed, never derived

Seven of the nine JVM services put Actuator on `port + 10000`. Two do not:
authorization-server is `6666 → 19091` and gateway is `6868 → 19093` (fossils of
an older shared-9091 scheme, later prefixed with `1`). Both probes target the
management port by name, so deriving it would render correctly for seven
services and point two at dead ports — permanent readiness failure with a
values file that looks clean.

General rule: derive a value only when the relationship is *enforced*, not
merely *observed*. The ALB service prefixes (§ below) are safe to derive because
the gateway's `Path=/<service-name>/**` routing convention enforces them.

### The ALB service prefixes are derived from the service list

The hand-written `k8s/apps/overlays/aws/ingress-gateway.yaml` lists eight
`/<service>` paths by hand. Adding a service and forgetting that list gave you a
service that worked locally and was invisible on AWS. The chart ranges the
service list, skips `gateway` and `frontend`, and emits the rest — the
divergence is no longer representable.

## AWS cut-over (Phase 7 path)

Phase 7 (`docs/superpowers/specs/2026-08-12-aws-cutover-design.md`) is
**not** a porting task — the apps subchart already produced the right AWS
objects, built during Phase 3 above. What Phase 7 closes: nothing had ever
compared the chart's whole aws render to the old kustomize path
object-by-object (only individual properties), the three deploy-time inputs
were still assembled by hand, and `make deploy ENV=aws` was deliberately
left unmapped by Phase 6. Read the design doc's §1 CORRECTION before
anything else here — an earlier draft of that section claimed the chart's
aws path was broken (a 4-object render); that was a measurement error
(missing `--set apps.enabled=true`, not `--namespace infra`) and the claim
is withdrawn.

### The three deploy-time inputs

`make deploy ENV=aws` now resolves its own inputs instead of an operator
assembling them by hand as

```bash
make k8s-apps-helm ENV=aws \
  HELM_EXTRA='--set apps.irsa.s3RoleArn=$(terraform output -raw s3_irsa_role_arn)'
```

(and separately supplying the ECR registry + image tag, which
`envs/aws.yaml` deliberately leaves empty). `deploy/scripts/aws-deploy.sh`
resolves all three and invokes the chart:

| input | source, in order |
|---|---|
| `s3_irsa_role_arn` | `AWS_TF_OUTPUTS_JSON=<fixture>` (offline), else `terraform -chdir=aws/main output -raw s3_irsa_role_arn` |
| ECR registry | `AWS_TF_OUTPUTS_JSON=<fixture>` (offline), else `terraform -chdir=aws/bootstrap output -raw ecr_registry` |
| image tag | `TAG` env var, else the current commit's short SHA (`git rev-parse --short HEAD`) |

```bash
make deploy ENV=aws                          # real deploy — COSTS MONEY
AWS_TF_OUTPUTS_JSON=deploy/charts/microecom/tests/fixtures/aws-tf-outputs.json \
  TAG=testsha deploy/scripts/aws-deploy.sh --render -- --set infra.enabled=false
                                              # offline render only, free
```

**Offline use:** `AWS_TF_OUTPUTS_JSON=<path>` substitutes a JSON file shaped
like `terraform output -json` for real terraform outputs — this is what lets
`aws-deploy.sh`, and `make deploy ENV=aws` through it, be verified without an
AWS account. **Never point it at real state.** Real terraform is untouched
unless the env var is unset.

A missing input now fails loud and names which one and where it comes from,
at two layers:

- `aws-deploy.sh`'s own `fail()` guards catch an empty `s3_irsa_role_arn`,
  `ecr_registry`, or image tag before invoking Helm at all.
- `charts/apps/templates/_helpers.tpl` wraps `global.appImage.registry` and
  `.tag` in Helm's `required`, mirroring the pre-existing
  `apps.irsa.s3RoleArn` guard — a missing registry/tag now fails with a named
  message (`global.appImage.registry must be set (the ECR registry) --
  stamped by the deploy script ...`) instead of the previous opaque
  `YAML parse error … mapping values are not allowed in this context`.

**Two flags are load-bearing for any hand render, and both were gotten wrong
at least once during this phase:**

- **`--set apps.enabled=true`.** The apps subchart is gated on it and
  defaults to `false`, so omitting it silently yields 3 objects that look
  like a successful render — this was the exact shape of the design doc's
  own withdrawn "4-object" premise.
- **`--set-string`, never `--set`, for the registry/role-arn/tag.** Helm's
  `--set` treats dots as path separators, so an ECR hostname like
  `583178372344.dkr.ecr.ap-southeast-1.amazonaws.com` silently becomes
  nested keys instead of a string. Both `aws-deploy.sh` and
  `aws-diff-test.sh` use `--set-string` for all three inputs; a hand render
  that disagrees with either should be treated as the hand render being
  wrong until proven otherwise.

### The oracle is composed from two sources

The old kustomize AWS path — the oracle this phase proves the chart against
— is not just `kubectl kustomize k8s/apps/overlays/aws` (39 objects). It is
that **plus** `k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml` (2 more
ServiceAccounts), which is **not referenced in the overlay's
`kustomization.yaml`**. `scripts/aws/up-all.sh:127-137` reads
`terraform output -raw s3_irsa_role_arn`, substitutes it into that file with
a plain `sed`, and pipes the result to `kubectl apply -f -` — out-of-band,
after the kustomize build. Diffing against `kustomize build` alone would
make the chart's IRSA ServiceAccounts look like an invented addition, when
in fact AWS already gets them today, just via a second, separate step.

`deploy/charts/microecom/tests/aws-oracle/capture.sh` reproduces both halves
offline (`kubectl kustomize` is a pure local build — no cluster contact —
and the IRSA half is templated with a fixture ARN, never applied) and
concatenates them into `deploy/charts/microecom/tests/aws-oracle/oracle.yaml`,
the file `aws-diff-test.sh` diffs the chart's render against. **This capture
is not a cache — re-run it any time `k8s/apps/overlays/aws` changes**, since
it is what keeps the oracle from silently drifting out from under the diff
suite (`oracle.yaml` is committed, so a stale re-capture shows up as a normal
`git diff`).

### Test suites

```bash
make aws-oracle-capture   # rebuild tests/aws-oracle/oracle.yaml (offline, no cluster)
make aws-diff-test        # Layer A — chart aws render vs. the composed oracle
```

`aws-diff-test` groups both sides by `(kind, name)`, guards both sides
non-empty and every required per-kind count exact **before** diffing at all
(a chart that collapsed to 3-4 objects must fail loudly here, never diff
against a near-empty stream — this is the class of defect the design doc's
§4 "non-negotiable guards" section calls out, and the exact shape of the
withdrawn 4-object premise above), then reports every remaining difference
as either a whole object on one side only, a shared object differing in a
specific declared way, or an unexplained `FAIL`.

### Verification status

**Proven offline.** The chart's aws render (`helm template ... -f
envs/aws.yaml --set apps.enabled=true --set-string ...`) matches the
composed oracle object-by-object: **31 matched, 12 declared-different, 0
unexplained.** The 12 are 2 chart-only `Namespace`s (`bootstrap`,
`monitoring` — the umbrella's `namespaces.yaml` rendering all 3 non-infra
namespaces regardless of env, pre-existing and unrelated to AWS) plus 10
content differences on shared objects, **two of which are the chart being
MORE correct than the overlay, not merely different:**

- **8 Deployments carry stale `VAULT_TOKEN`/`SPRING_CLOUD_VAULT_URI` env in
  the oracle that AWS has no use for.** They are leftovers in the shared
  local-dev base manifest (`k8s/apps/base/*/deployment.yaml`) that the aws
  overlay never strips. AWS has no in-cluster Vault (secrets come from ESO),
  so the chart's `envs/aws.yaml` explicitly nulls both keys and correctly
  omits them — a real residue in the *old* path, not a chart gap.
- **The overlay's `ingress-gateway.yaml` references the frontend backend
  Service port by number (`number: 80`) where every other backend in the
  same hand-authored file uses the port name (`name: http`).** Same
  Service, same port — the chart uses `name: http` consistently for every
  backend including frontend; the inconsistency is in the old file.

The one remaining content difference (`Deployment/frontend`'s explicit probe
`failureThreshold`, liveness=4/readiness=6 vs. the oracle's implicit k8s
default of 3) is a deliberate inherited value, documented in
`charts/apps/values.yaml`'s `frontend.probes` comment — neither side is
"more correct," it's just different by design.

**NOT proven: no AWS deployment has ever been executed — still true as of
Phase 8.** No EKS cluster was created, `terraform apply` never ran, and
fixture outputs (`AWS_TF_OUTPUTS_JSON`) stood in for real ones throughout —
the same offline-only shape Phases 1, 3 and 4 of this refactor each shipped
with. **This is now the fifth consecutive phase shipping an unexercised
transport** (this cleanup phase included — it repointed `up-all.sh` onto
the canonical seed/secrets/deploy scripts and never ran it either; see the
top-level Verification status section above). `deploy ENV=aws` is mapped
and its offline render is proven byte-for-byte against ground truth, but
nobody has watched a real pod come up on a real EKS cluster wired this way.
Deciding whether to spend money on that live run is explicitly deferred
(design doc D2) — closing the offline gaps was free, a billed run is a
decision for whoever picks this up next.

### Finding from Phase 7, closed by Phase 8's deletion

The VAULT env leftover above (8 Deployments' oracle-only `VAULT_TOKEN` /
`SPRING_CLOUD_VAULT_URI`) was harmless on AWS — the chart already omitted
both keys, and nothing read them from the overlay-deployed pods either,
since AWS had no in-cluster Vault to reach. It was a genuine, real gap in
the *old* kustomize path (`k8s/apps/base/*/deployment.yaml` /
`k8s/apps/overlays/aws`), out of scope to fix while `k8s/` had to stay
byte-identical for the Phase 7 diff. Phase 8 deleted `k8s/` entirely, which
closes this finding by removing the file the residue lived in — the
`aws-diff-test.sh` comparison above still shows the difference because its
oracle (`deploy/charts/microecom/tests/aws-oracle/oracle.yaml`) is a frozen
**capture** of that now-deleted overlay, taken before deletion — see
"Losses and leftovers" near the top of this file for why that capture is
never regenerated.

