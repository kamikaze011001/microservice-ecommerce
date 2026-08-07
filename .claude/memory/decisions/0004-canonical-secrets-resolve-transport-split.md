---
name: 0004-canonical-secrets-resolve-transport-split
description: One canonical secrets file per service + per-env contexts, split into a pure resolver and a separate transport, so every env can be verified offline without credentials
metadata: { type: decision, date: 2026-08-07 }
---
Phase 4 of the deploy refactor (PR #54). The ~90 Spring dotted properties that were maintained
by hand in three places — `docker/vault-configs/*.json`, `k8s/infra/jobs/03-vault-seed/seed.sh`,
`scripts/aws/seed-secrets.sh` — collapse into `deploy/secrets/<service>.yaml` (11 files) plus
`deploy/secrets/contexts/{compose,k8s,aws}.yaml`. Design:
`docs/superpowers/specs/2026-08-06-canonical-secrets-design.md`.

The load-bearing structural choice is a **resolve/transport split**:

- `deploy/scripts/lib/secrets_resolve.py` is a **pure function** from (canonical YAML + context +
  environment) to a flat map. No network, no backend, no cluster, no credentials.
- `deploy/scripts/secrets-seed.sh` is the only thing that talks to a backend, and it resolves
  **everything** before writing **anything**.
- `deploy/scripts/secrets-validate.sh` runs six checks against the resolver alone, so it needs no
  credentials (`--stub-env` substitutes `<stub:VAR>` for `${VAR}`) and can move into CI unchanged.

Four reference syntaxes are kept deliberately distinct so a failure names *which kind* of input is
missing: `{{ctx.ref}}`, `${ENV_VAR}`, `<file:name>`, `<terraform:name>` (contexts only).

The envs genuinely differ in **which keys exist** — compose discovers via Eureka; k8s/aws disable
it and use Service DNS, needing 10 URL keys compose must not have. That is modelled as
`envs: [...]` on the key, not as empty-value placeholders, because setting a key to "" in an env
where it is wrong is not the same as it being absent.

**Why:** the triplication had already shipped bugs — `k8s/CLAUDE.md` records 3+ startup
crashloops caused purely by the k8s copy drifting behind the compose one, and the AWS script
carried a hand-rolled `APPLICATION_JWK`-from-env workaround whose own comment says it exists "to
avoid a second copy drifting". The resolve/transport seam is what makes the **aws** leg verifiable
at all: it cannot be exercised without an account or spend, but its resolved output can be diffed
offline.

**How to apply:** `make secrets-validate` (no creds), `make secrets-render ENV=…` (dry run),
`make secrets-seed ENV=…`. Seeding is **always overwrite** — the canonical file is authoritative,
there is no merge. Equivalence against the old paths is proven by
`deploy/secrets/tests/equivalence-test.sh`, which captures each *old* script's intended write by
running the real script with **fake `vault`/`aws`/`terraform` binaries first on `PATH`** (the fake
`vault` fails every `kv get`, so `put_if_missing` never skips and the capture records full intent).
Reuse that shimming technique whenever an env cannot be run for real.

**Nothing was deleted** — all three old paths still work untouched; deletion is Phase 8, so
rollback is "don't call the new target". Note for Phase 8: deleting `k8s/` and `aws/` removes the
goldens' source, making `capture-golden.sh` unregenerable — freeze the goldens deliberately or the
equivalence suite quietly degrades into a snapshot test of itself.
Related: [[0003-deploy-refactor-helm-umbrella-three-envs]],
[[vault-config-comment-keys-are-really-seeded]],
[[cross-env-equality-checks-miss-shared-drift]].
