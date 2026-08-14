# Cleanup Cut-over — Design

**Phase 8** — the final phase of the deploy refactor
(`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`).

**Goal:** finish the k8s Helm cut-over the refactor has deferred since Phase 3, then
delete the duplicate paths it unlocks.

---

## 1. Why this is not "cleanup"

The parent spec frames Phase 8 as deletion. It cannot be, because **one blocker holds up
every deletion**:

```
deploy ENV=k8s  →  k8s-apps  →  k8s/apps/overlays/local
                                  ↑
        k8s/ also reads docker/*.json and docker/ecommerce.sql
                                  ↑
        so the seed data cannot go, so scripts/seed/ cannot go
```

`VERB_deploy_k8s := k8s-apps` and `VERB_bootstrap_k8s := k8s-bootstrap` both run out of
`k8s/`, alongside 28 other Makefile references. Delete `k8s/` and local development
stops working.

### The duplication this leaves

Four concerns, each with two working implementations:

| concern | old | new |
|---|---|---|
| secrets | `docker/vault-configs/` + `make vault-import` | `deploy/secrets/` + `make secrets-seed` |
| seed data | `scripts/seed/*` + `make seed-data` | `deploy/scripts/seed.sh` + `make seed` |
| k8s apps | `k8s/apps/overlays/` + `make k8s-apps` | Helm chart + `make k8s-apps-helm` |
| commands | `k8s-*` / `aws-*` / bare targets | `make <verb> ENV=<env>` |

Someone landing in this repo cannot tell which is authoritative. That is the cost the
refactor set out to remove and has so far only deferred.

## 2. The blocker is smaller than previously assessed

Phase 3's Helm apps path failed on two things:

1. **Namespace ownership metadata** — Helm refuses to adopt pre-existing objects lacking
   `app.kubernetes.io/managed-by=Helm` and the two `meta.helm.sh/release-*` annotations.
   **Already fixed:** Phase 6's `5b57c4b` stamps all three chart-rendered namespaces.
2. **Vendored grafana vs the standalone release** — `k8s-apps-helm` sets
   `apps.enabled=true` but never `infra.enabled=false`, so it renders the umbrella's
   infra subchart, which vendors grafana, and collides with the standalone `grafana`
   release installed by `k8s-platform`.

Only (2) remains, and it is the same shape `deploy/scripts/aws-deploy.sh` already
handles. What it needs is a **live cluster**, because adoption conflicts exist only in
cluster state — which is why this phase begins with one.

---

## 3. Decisions

### D1 — Cut over first, delete second, in separate commits

Every prior phase could roll back with "don't call the new target." **This one cannot.**
So deletion happens only after live verification, and in its own commits, so a revert is
surgical rather than wholesale.

### D2 — `aws/` stays

The parent spec moves `aws/` → `deploy/terraform/`. That is 58 referencing files of pure
churn, no verification is available for it, and nothing depends on it happening now.
Out of scope; recorded rather than silently skipped.

### D3 — All four oracles freeze as fixtures

Deleting the old trees destroys the source of the secrets goldens, the seed goldens and
the AWS oracle. The Phase 6 make baselines are already frozen.

Each gets a header stating **the source is gone and it must never be regenerated** —
the treatment `capture-baseline.sh` received in Phase 7. The suites keep catching
regressions against the last known-good old behaviour; they simply stop being able to
re-derive it.

*Rejected:* deleting the suites with their sources (discards regression coverage that
catches real drift), and retargeting them at the new path (a snapshot of yourself
catches change but never incorrectness — and that distinction would stop being visible).

### D4 — Scars migrate before their file dies

`k8s/CLAUDE.md` holds **19** hard-won scars (counted `^### SCAR`): the XA self-deadlock across
master/slave EMFs, the Bitnami image deletion migration, Confluent images needing
`enableServiceLinks: false`, the tunnel-health diagnostics, the kustomize
out-of-tree-file restriction. **These move to `deploy/CLAUDE.md` before deletion.**
Losing them would cost more than the refactor saved.

---

## 4. Scope

**In:**
1. Fix the grafana collision; repoint `VERB_deploy_k8s` and `VERB_bootstrap_k8s` at Helm
2. **Verify live on the cluster** — apps deploy via Helm and the stack serves
3. Repoint `bootstrap-compose`: `vault-import` → `secrets-seed ENV=compose`,
   `seed-data` → `seed ENV=compose`
4. **Verify live on compose** — it is the daily driver
5. Freeze the four oracles
6. Migrate the scars to `deploy/CLAUDE.md`
7. Delete: `k8s/`, `docker/vault-configs/`, `docker/*.sql|json`, `scripts/seed/`,
   `scripts/vault/import-secrets.sh`, `scripts/aws/seed-*.sh`

**Out:** `aws/` and the `deploy/terraform/` move (D2); any change to application code.

### D5 — the k6 stress harness moves into `deploy/`

The stress manifests live in `k8s/apps/base/k6-stress/` (6 tracked files) and reference
`docker/*.json`, so they are entangled with two things being deleted. **Human decision:
relocate them under `deploy/` and repoint their seed references at `deploy/seed/`**, so
`make k8s-payment-stress` and the three `k8s-storefront-*` targets keep working.

Justification: this harness produced several of the project's most valuable findings —
the Atomikos pool exhaustion under load, the inventory oversell race, and the replica-lag
measurements at peak. Rebuilding that capability from scratch would cost far more than
the migration.

*Rejected:* carving out a residual `k8s/` containing only the harness (leaves a directory
whose name no longer means what it says), and deleting it with the tree (git remembers,
but the capability would need rebuilding to use again).

---

## 5. Verification

**Live, k8s — what Phase 3 never proved.** Apps deploy via Helm; pods ready; the catalog
returns products through the gateway. Adoption conflicts exist only in cluster state, so
nothing offline substitutes.

**Live, compose — the daily driver.** `bootstrap-compose` loses `vault-import` and
`seed-data`. Verified end to end, not inferred.

**Offline — everything must still pass:** `render-test` 268, `aws-diff-test` 31-12-0,
`verb-equivalence` 21, plus the seed and secrets suites. The new paths do not change, so
a failure here means a deletion took something live.

**Post-deletion sweep.** After each deletion, `git grep` for the removed path must return
nothing outside docs and frozen fixtures. A dangling reference that only fires at runtime
is the characteristic failure of this work.

---

## 6. Risks

- **Helm adoption may fail for a reason nobody has seen.** This path has been
  mis-assessed twice. If it fails, the phase stops at the cut-over — see §7.
- **Deleting `k8s/` removes the AWS oracle's source** (`k8s/apps/overlays/aws`). Freeze
  before delete, in that order.
- **`k8s/CLAUDE.md`'s scars** (D4). Migrate before deletion or lose them permanently.
- **The k6 manifests** move under `deploy/` (D5) and their seed references repoint. If
  the move is wrong, the failure surfaces only when someone next runs a stress test —
  long after this phase merges.
- **Compose is the daily driver.** A wrong repointed chain is felt immediately, on every
  run.
- **Deletion is irreversible in practice.** Git remembers, but a half-deleted tree
  discovered a week later is far more expensive than a deferred deletion.

## 7. Stop conditions

Explicit, because this phase cannot roll back:

- Helm apps do not come up cleanly → **stop, delete nothing**, report.
- Compose bootstrap fails after repointing → **revert the chain**, delete nothing.
- Any suite regresses → stop before the next deletion.

**The phase is allowed to end having done only the cut-over.** That is a good outcome. A
half-deleted tree is not.

## 8. Findings raised, not fixed

- `scripts/aws/up-all.sh` still has no confirmation prompt before a real EKS apply.
- The old kustomize AWS overlay leaves stale `VAULT_TOKEN`/`SPRING_CLOUD_VAULT_URI` env
  in 8 Deployments. It dies with `k8s/`, so this resolves itself — noted so the
  disappearance is expected rather than surprising.
