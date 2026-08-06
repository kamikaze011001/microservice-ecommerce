# Canonical Secrets Consolidation — Deploy Refactor Phase 4

> Phase 4 of the deploy refactor. Predecessors: Phase 0 (scaffold), Phase 1
> (kind → minikube), Phase 2 (Helm infra subchart, PR #52), Phase 3 (Helm apps
> subchart, PR #53). Parent design:
> `docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`.

## Problem

The same per-service Spring configuration is maintained by hand in three
places, one per deployment environment:

| Source | Env | Shape |
|---|---|---|
| `docker/vault-configs/*.json` | docker-compose | 11 JSON files, imported into Vault |
| `k8s/infra/jobs/03-vault-seed/seed.sh` | local k8s (minikube) | 190-line shell script, `put_if_missing` into Vault |
| `scripts/aws/seed-secrets.sh` | EKS | 203-line shell script, `put` into AWS Secrets Manager |

All three are keyed by the exact dotted Spring property name, and roughly 55 of
the ~100 keys hold the *same literal value* in all three. Every one of those is
a copy that can drift, and drift here is not theoretical — `k8s/CLAUDE.md`
records at least three crashloops caused purely by the k8s copy falling behind
`docker/vault-configs/`:

- a missing `authorization-server` block → `Could not resolve placeholder
  'application.access-token.life-time'`
- a missing `spring.kafka.properties.schema.registry.url`
- a missing `spring.data.mongodb.database`

The sharpest case is `application.jwk`, the RSA signing key. The gateway caches
JWKS by `kid`, so a single differing byte invalidates every token in the
system. It is currently inline in `docker/vault-configs/authorization-server.json`
and inline again in `seed.sh`; the AWS script works around the problem by
reading `APPLICATION_JWK` from the environment, with a comment saying this
exists specifically "to avoid a second copy drifting". A hand-rolled mitigation
on one of three paths is evidence of the structural problem, not a solution to
it.

### Measured current state

Surveyed at `e4a9c4d`. All 11 services are defined in all three sources; no
service is missing anywhere.

Keys that exist in some envs but not others — **legitimate divergence, not
drift**:

| Keys | compose | k8s | aws |
|---|---|---|---|
| `eureka.client.service-url.defaultZone`, `eureka.instance.prefer-ip-address` | ✓ (`bff-service`) | — | — |
| `eureka.client.enabled: "false"` | — | ✓ | ✓ |
| `feign.client.{product,order,payment}-service.url` | — | ✓ | ✓ |
| `gateway.routes.*.uri` (7 keys) | — | ✓ | ✓ |
| `spring.data.redis.ssl.enabled` | — | — | ✓ |
| `spring.mail.username`, `spring.mail.password` | — | — | ✓ |
| `application.paypal.{tunnel-url,client-id,client-secret}` | — | — | ✓ |

Compose discovers services through **Eureka**; k8s and AWS disable Eureka and
use **Service DNS**, which requires ten explicit URL keys that compose does not
have and must not have. The envs therefore differ in *which keys exist*, not
only in values.

Verified non-findings (reported as suspected defects during the survey, checked
and dismissed):

- `spring.kafka.properties.schema.registry.url` is `localhost:8091` on compose
  and `…:8081` on k8s/aws. `docker/kafka.yml:46` maps `"8091:8081"` — compose
  reaches the service through a host port mapping. Correct and env-specific.
- `application.jwk` is byte-identical between compose and k8s (sha256 prefix
  `4fa8a3fe…`, 1673 bytes). The copies have **not** drifted; the risk is
  structural, not yet realised.

Genuine value differences that are env-specific by design, to be represented
faithfully rather than "fixed" in this phase:

- MySQL passwords: compose uses per-role literals
  (`ecommerce_master`/`slave1`/`slave2`), k8s normalises all three to `root`
  (matching the in-cluster MySQL chart), AWS reads `terraform output`.
- `spring.data.redis.password`: non-empty on compose, **empty on k8s**. A real
  security-posture gap; see Findings.

## Goals

1. One canonical definition per service, consumed by all three envs.
2. One seed script replacing three, selecting backend by `--env`.
3. A validation guard that turns the drift lesson into a build failure.
4. Byte-level evidence that the new path produces what the old three produce —
   for all three envs, including AWS, without spend.
5. Every step leaves a working deploy. The old paths stay until Phase 8.

## Non-goals

- Deleting `docker/vault-configs/`, `03-vault-seed/`, or
  `scripts/aws/seed-secrets.sh` — that is Phase 8, gated on both envs passing.
- Changing application code. Spring's configtree/Vault reading logic is
  untouched.
- Changing Plan 3's apps subchart. The `app-secrets` Secret and its `envFrom`
  mount stay exactly as merged.
- Closing the Redis-password gap, or any other behaviour change. This phase
  claims behavioural equivalence; changing behaviour would invalidate the
  equivalence proof that is its main evidence.
- Seeding real AWS Secrets Manager. AWS transport verification is Phase 7.

## Decisions

Six choices, each with the alternative rejected:

1. **All three envs in one script**, AWS verified offline — not compose+k8s
   only. Leaving `scripts/aws/seed-secrets.sh` alive would preserve a second
   source for another phase or more, which is the exact failure being removed.
2. **Always overwrite; the file is authoritative** — not `put_if_missing`.
   Skip-if-exists means editing a canonical value and re-seeding is a silent
   no-op: the file claims X, the backend serves Y, nothing reports it. That is
   a drift generator inside the anti-drift phase.
3. **Terraform outputs resolved from a cached JSON file** — not a live
   `terraform output` on every run. The cache is the seam that makes offline
   AWS verification possible; a live call would hard-couple the resolver to
   terraform state and AWS credentials. Refresh policy is explicit rather than
   automatic; see *Terraform output cache*.
4. **Non-universal keys declare `envs:` explicitly** — not a superset with
   drop-if-unresolved. The superset makes "deliberately absent here" and "you
   typo'd the context key" indistinguishable, reviving the silent-missing-value
   failure that caused the documented crashloops.
5. **User-owned credential delivery keeps today's split, declared once per
   env** — not unified into the backend. Unifying would touch the
   freshly-merged apps subchart and the compose path, growing Phase 4 by a
   chart change and a `make up` regression risk.
6. **Equivalence proved offline by shimming the backend**, transport proved
   separately by live runs — not the parent doc's "seed Vault and diff the
   result". See Verification.

## Architecture

```
deploy/secrets/
  <service>.yaml            11 files. Canonical keys and values.
  jwk.private.json          the RSA signing key — ONE copy
  contexts/
    compose.yaml            what {{ref}} means on docker-compose
    k8s.yaml                …on minikube
    aws.yaml                …on EKS; may hold <terraform:…> refs

deploy/scripts/
  secrets-seed.sh           resolve + push; --env selects context AND backend
  secrets-validate.sh       key-set/reference consistency; no backend, no network
  lib/secrets-resolve.sh    the shared resolver both scripts use
```

The load-bearing boundary is between **resolving** and **pushing**.
`lib/secrets-resolve.sh` turns (canonical file + context + environment) into a
flat, fully-resolved key→value map and touches no network.
`secrets-seed.sh` takes that map and writes it to a backend.

That split is what makes offline AWS verification possible: rendering the AWS
map needs only `contexts/aws.yaml` plus a `terraform-outputs.json` fixture — no
AWS account, no terraform state, no network. It also makes
`secrets-validate.sh` a pure function over files, so it can run in CI (Phase 9)
with zero credentials.

### Canonical file format

Keys are exact dotted Spring property names, unchanged from today. A value is a
plain scalar unless it needs to say more.

```yaml
# deploy/secrets/ecommerce.yaml → vault:secret/ecommerce | asm:microecom/app/ecommerce

# ── universal: ~85 of ~100 keys look exactly like this ──
spring.datasource.master.driver-class-name: com.mysql.cj.jdbc.Driver
spring.data.redis.port: "6379"
application.kafka.topics.order-created: order-created

# ── env-specific: placeholders resolved from the context ──
spring.datasource.master.url: "jdbc:mysql://{{mysql.master.host}}:{{mysql.master.port}}/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"
spring.datasource.master.username: "{{mysql.username}}"
spring.datasource.master.password: "{{mysql.password}}"
spring.kafka.properties.schema.registry.url: "http://{{schemaRegistry.host}}:{{schemaRegistry.port}}"

# ── conditional: expanded form, only where genuinely needed (~14 keys) ──
eureka.client.enabled:
  value: "false"
  envs: [k8s, aws]
```

```yaml
# deploy/secrets/payment-service.yaml
application.paypal.client-id:
  value: "${PAYPAL_CLIENT_ID}"
  owner: user
```

Three orthogonal ideas, each doing one job:

**`envs:`** — absent means universal. Present means the key resolves only in
those envs and is *absent* elsewhere, not empty.

**`owner: user`** — marks a genuine credential. It does not say where the value
goes; the context does. Default is `owner: config`.

**Resolution namespaces** are deliberately distinct rather than one generic
`{{}}`, so a failure message can name which kind of input is missing:

| Syntax | Resolved from | Valid in | Missing ⇒ |
|---|---|---|---|
| `{{mysql.master.host}}` | the env context file | canonical files | hard fail, naming the key and the context |
| `${PAYPAL_CLIENT_SECRET}` | process env / `.env` | canonical files | hard fail, naming the variable |
| `<file:jwk.private.json>` | a file under `deploy/secrets/` | canonical files | hard fail, naming the path |
| `<terraform:rds_primary_endpoint>` | cached `terraform-outputs.json` | **context files only** | hard fail, saying to run `terraform apply` |

`<terraform:…>` never appears in a canonical file. It appears only in
`contexts/aws.yaml`, as the *value* of a context key — so the canonical files
stay backend- and cloud-agnostic.

Conversely `<file:…>` is valid only in canonical files: it exists so a large
literal (the JWK) lives in one file on disk instead of being pasted into YAML.

### Context files

```yaml
# deploy/secrets/contexts/k8s.yaml
userCredDelivery: envfrom
mysql.master.host: mysql.infra.svc.cluster.local
mysql.master.port: "3306"
mysql.username: root
mysql.password: root
schemaRegistry.host: schema-registry.infra.svc.cluster.local
schemaRegistry.port: "8081"
redis.password: ""            # see Findings — k8s has no Redis auth today
```

```yaml
# deploy/secrets/contexts/aws.yaml
userCredDelivery: backend
mysql.master.host: <terraform:rds_primary_endpoint>
mysql.password:    <terraform:db_master_password>
schemaRegistry.host: schema-registry.infra.svc.cluster.local
schemaRegistry.port: "8081"
```

`userCredDelivery` expresses decision 5 once per env instead of four times per
key:

- `envfrom` (compose, k8s) — `owner: user` keys are **excluded** from the
  backend push and instead *asserted present* in `.env`. A missing PayPal
  secret then fails at seed time naming the variable, rather than at runtime as
  a PayPal `400 INVALID_PARAMETER_SYNTAX`.
- `backend` (aws) — `owner: user` keys are resolved and pushed like any other.

Infra passwords (`mysql.*.password`, `redis.password`) are ordinary `{{}}`
context values, not `owner: user`: compose supplies its per-role literals, k8s
supplies `root`, AWS supplies `<terraform:…>`.

### Terraform output cache

`aws/main` keeps its state in an **S3 remote backend**
(`aws/main/versions.tf:22`, bucket `microecom-tfstate-…`, DynamoDB lock). There
is therefore no local file whose mtime can be compared against the state, so
"refresh when stale" is not implementable without a network round-trip that
defeats the point of the cache. The policy is explicit instead:

- Cache file: `deploy/.run/terraform-outputs.json` (git-ignored, like the other
  `deploy/.run/` runtime artefacts).
- **Missing** → the resolver runs `terraform -chdir=aws/main output -json` once
  and writes the cache. This is the only implicit network call.
- **Present** → used as-is. No staleness check, no silent refresh.
- `--refresh-tf` forces regeneration. `make aws-up` regenerates it as its final
  step, so the normal AWS workflow never has to think about it.
- If the cache is older than 24h the resolver prints a **warning** naming the
  file and the flag. It warns, it does not refresh — an implicit `terraform`
  invocation mid-seed is exactly the coupling decision 3 removes.

The eight outputs consumed today, from `scripts/aws/seed-secrets.sh:42-57`:
`rds_primary_endpoint`, `rds_replica_endpoint`, `redis_primary_endpoint`,
`redis_auth_token`, `db_master_password`, `s3_bucket_name`,
`s3_public_base_url`, `shop_url`. Offline verification supplies these as a
fixture; `secrets-validate.sh` asserts `contexts/aws.yaml` references no
`<terraform:…>` name outside this set.

### The JWK

`deploy/secrets/jwk.private.json` holds the key once.
`authorization-server.yaml` and `gateway.yaml` reference it with a dedicated
`<file:jwk.private.json>` ref, so the bytes are read from disk rather than
duplicated into YAML. `secrets-validate.sh` asserts the resolved value is
identical across all three envs.

## The seed contract

```
secrets-seed.sh --env=compose|k8s|aws [--dry-run] [--service=NAME]
```

- Resolve → push. **Always overwrite**, per decision 2.
- Backend follows from `--env`: `vault kv put` for compose and k8s,
  `aws secretsmanager put-secret-value` for aws.
- `--dry-run` prints the fully-resolved map as canonical JSON (sorted keys,
  stable formatting) and touches no network. This is the artefact the
  equivalence proof diffs.
- `--service=NAME` limits to one service, for iteration.
- Any unresolved reference is a hard failure before *any* write. The script
  resolves everything first, then pushes — a partially-seeded backend is worse
  than an unseeded one.
- Secrets are never echoed. `--dry-run` output is the one place resolved values
  appear; it goes to a file the task report references by path and does not
  quote.

### Validation

`secrets-validate.sh` — pure function over files, no backend, no credentials.
Four checks, each corresponding to a bug class already seen:

1. Every `{{ref}}` in every canonical file resolves in all three contexts, or
   the key declares `envs:` excluding the ones where it does not. *This is the
   check that would have caught the missing `spring.data.mongodb.database`.*
2. Every context key is used by at least one canonical file — catches a renamed
   placeholder leaving a dead context entry.
3. Every `owner: user` key names a variable documented in the `.env.example`
   for each env where `userCredDelivery: envfrom` — `docker/.env.example` for
   compose, `k8s/.env.example` for k8s. (There is no repo-root `.env.example`;
   the two are separate files with separate contents.) Envs using
   `userCredDelivery: backend` are exempt, since the value reaches the pod
   through the secret backend rather than an env file.
4. `application.jwk` resolves to identical bytes for all three envs.

## Verification

The parent design proposes seeding Vault and diffing the result. That conflates
two independent questions — *is the content identical?* and *does the transport
work?* — into one test that needs a live cluster, cannot run in CI, and cannot
cover AWS at all. This phase splits them.

### Equivalence — offline, all three envs

Both old scripts are shaped to allow backend shimming: `seed.sh` writes through
`put_if_missing` → `vault`; `seed-secrets.sh` writes through `put()` → `aws
secretsmanager`, and reads endpoints via `tf_out()` → `terraform`.

Put fake `vault`, `aws` and `terraform` executables first on `PATH`, run the
old script, and capture the exact key→value map it *would* have written.
Run `secrets-seed.sh --dry-run` for the same env. Normalise both to sorted JSON
and diff.

This yields a byte-level equivalence assertion for compose, k8s **and AWS
alike** — including the path that cannot otherwise be exercised — with no
cluster, no AWS account, and no spend. Being deterministic, it lands as a
regression test rather than a one-time manual check.

**Expected non-empty diff.** The first run will not be clean, for two known
reasons, and each expected difference must be enumerated and justified in the
task report rather than waved past:

- `put_if_missing` skips already-seeded paths, so the old k8s capture reflects
  *intent* rather than what a live Vault holds.
- The AWS-only keys sourced from `terraform output` are compared against
  fixture values, not real infrastructure.

### Transport — live, compose and k8s only

- `make secrets-seed ENV=k8s` on minikube → services start clean, gateway
  routes resolve, tokens validate.
- `make secrets-seed ENV=compose` → `make up` reaches the same state as
  `make vault-import` does today.
- **AWS transport is explicitly unproven until Phase 7.** Stated in writing, in
  the phase report and the PR body.

## Migration and rollback

Everything lands alongside the old paths. `docker/vault-configs/`,
`k8s/infra/jobs/03-vault-seed/seed.sh` and `scripts/aws/seed-secrets.sh` are
**not modified and not deleted**. New Makefile targets are additive.

Rollback is therefore "do not call the new target" — a bad Phase 4 is a no-op.
Deletion of the old sources happens in Phase 8, gated on a full
`make bootstrap ENV=k8s` and `ENV=aws` pass.

## Risks

| Risk | Mitigation |
|---|---|
| A resolved value differs subtly from today's (whitespace, quoting, trailing slash) and a service misbehaves at runtime rather than failing at boot | The offline equivalence diff is byte-level and covers every key in every env; normalisation is applied identically to both sides |
| Overwrite semantics destroy a manual hotfix during an incident | Documented in `deploy/README.md`; the file is authoritative by design, and the fix is expected to land in the file |
| The terraform-outputs cache goes stale and seeds yesterday's endpoints | Real residual risk, accepted: remote S3 state makes automatic staleness detection impractical. Mitigated by `make aws-up` regenerating the cache, a 24h-age warning, and `--refresh-tf`. AWS transport is not exercised until Phase 7, so a stale cache cannot reach a live system during this phase |
| `secrets-validate.sh` produces false positives and gets disabled | Check 1 is defined against the *declared* `envs:` sets, so legitimate divergence never trips it; the 14 known-divergent keys are the acceptance test for this |
| Phase 4 breaks the everyday compose loop | Old path untouched; `make up` continues to call `make vault-import` until Phase 6 switches it |

## Findings raised, not fixed

These are recorded here so the consolidation represents reality faithfully and
the gaps do not disappear into a refactor:

1. **`spring.data.redis.password` is empty on k8s** while compose sets one. The
   in-cluster Redis accepts unauthenticated connections. Belongs to a security
   pass, not to a phase claiming behavioural equivalence.
2. **`payment-service` `application.frontend.base-url` is `""` on AWS** — an
   unresolved placeholder pending the Phase 5b domain work, carried forward
   as-is.
3. **`mock.public-base-url` is a bare path on AWS** (`/mock-paypal-service`)
   where compose and k8s use absolute URLs. Represented faithfully; the shape
   inconsistency is flagged for Phase 7.
4. **`ecommerce-common.json` seeds the path `ecommerce`**, not
   `ecommerce-common`. The canonical file is named `ecommerce.yaml` to match
   the path that services actually read.

## Open questions resolved by this spec

Parent design open question 3 (*AWS terraform output resolution*) is resolved:
cached `terraform-outputs.json`, auto-refreshed, per decision 3.
