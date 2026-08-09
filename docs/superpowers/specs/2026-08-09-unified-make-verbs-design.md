# Unified Make Verbs — Design

**Phase 6** of the deploy refactor (`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`).
Follows Phase 5 (canonical seed), whose additive-migration discipline this reuses.

**Goal:** one command dialect — `make <verb> ENV=<env>` — replacing three, without
removing or moving anything.

---

## 1. The problem, measured

The Makefile is **654 lines, 76 targets**, in three dialects:

| dialect | targets | example |
|---|---|---|
| k8s | 39 | `make k8s-bootstrap`, `make k8s-apps` |
| compose | 11 | `make bootstrap`, `make up` |
| aws | 7 | `make aws-all`, `make aws-down` |

A newcomer has to learn which prefix applies to which environment before they can do
anything, and the same concept has three names.

But **only some of those 76 targets are the same concept in three costumes.** The 39
`k8s-*` targets split three ways:

| kind | examples | cross-env analogue? |
|---|---|---|
| lifecycle | `k8s-bootstrap`, `k8s-apps`, `k8s-status`, `k8s-down`, `k8s-build` | **yes** — these are the verbs |
| env-specific infra | `k8s-tunnel`, `k8s-registry-forward`, `k8s-cluster-up`, `k8s-ctx`, `k8s-stop/start` | **no** — minikube-only concepts |
| testing / observability | `k8s-payment-stress`, `k8s-storefront-*`, `k9s`, `k8s-mysql-status` | orthogonal to deployment |

`make tunnel ENV=compose` is not a missing feature; it is a category error.

---

## 2. Decisions

Each with the alternative rejected.

### D1 — No file moves; Phase 6 is purely additive

The parent spec's Phase 6 steps 3-5 move three trees (`aws/` → `deploy/terraform/`,
`docker/*.yml` → `deploy/compose/`, `k8s/images/` → `deploy/images/`). **Deferred to
Phase 8.**

Measured: those moves touch **98 distinct files** (58 referencing the aws trees, 28
`k8s/images`, 26 `docker/*.yml`). The parent spec rates Phase 6 "low risk — this is
rewiring the entry points", which is true of the Makefile work and false of the moves.

*Rejected:* moving now. It would end the property that made Phases 1-5 safe to ship
partly-verified — nothing deleted, nothing moved, rollback is "don't call the new
target". Phase 8 already lists all three trees and is already labelled "the final
irreversible step"; doing move+delete there as one atomic relocation avoids touching
98 files twice.

### D2 — Core lifecycle verbs only

Unify the verbs that genuinely exist in more than one env. Leave env-specific and
testing targets under their current names.

*Rejected:* unifying everything with "not applicable" no-ops for impossible
combinations (invents verbs for single-env concepts and grows a matrix nobody runs),
and a namespaced escape hatch like `make k8s:tunnel` (renames ~20 working targets,
every doc and every operator's muscle memory, for no functional gain).

### D3 — `deploy ENV=k8s` wraps kustomize, not Helm

`make deploy ENV=k8s` invokes `k8s-apps` (kubectl/kustomize) — the path that
demonstrably works.

The two app-deploy paths are **mutually exclusive on one cluster**: `k8s-apps-helm`
aborts on namespace ownership metadata, and past that on the umbrella vendoring
grafana while `k8s-platform` has already installed grafana as its own standalone
release. It has 268 passing render tests and has never successfully deployed.
See `.claude/memory/conventions/helm-and-kubectl-deploy-paths-are-exclusive.md`.

*Rejected:* pointing the verb at Helm now. No cluster exists, so it would ship a
headline verb that has never once succeeded — the exact pattern Phases 1, 3 and 4
established and this workstream has been unwinding. Phase 7 must make the chart work
for aws anyway and will have a cluster; the verb then repoints in **one** place
rather than at every call site.

*Also rejected:* a selectable `DEPLOY_PATH=helm|kustomize`. Making the fork permanent
and visible in the UX is not unification.

### D4 — Two verification layers

**Layer A** — `make -n` expansion equivalence, offline, all three envs, CI-able.
**Layer B** — the live verb set against compose.

*Rejected:* live-compose-only (k8s and aws get nothing, not even proof the verb
resolves to the right command) and expansion-only (proves the wrapper points
somewhere correct, never that the target still works through the new entry point).

---

## 3. The verb set

**Eight** verbs, each defined only where it has meaning. Two of them — `seed` and
`secrets-seed` — already exist and are already `ENV=`-parameterised (Phases 5 and 4),
so Phase 6 adds six:

| verb | compose | k8s | aws |
|---|---|---|---|
| `bootstrap` | `bootstrap` | `k8s-bootstrap` | `aws-all` |
| `deploy` | `svc-start` | `k8s-apps` | (Phase 7) |
| `seed` | ✅ Phase 5 | ✅ Phase 5 | ✅ Phase 5 |
| `secrets-seed` | ✅ Phase 4 | ✅ Phase 4 | ✅ Phase 4 |
| `status` | `status` | `k8s-status` | — |
| `teardown` | `down` | `k8s-down` | `aws-down` |
| `image-build` | **n/a — fails loudly** | `k8s-build` | `aws-push` |
| `rebuild` | `svc-restart` | `k8s-rebuild` | `aws-push svc=` |

### `image-build ENV=compose` must FAIL, not no-op

Compose runs services as **JVM processes from Maven artifacts** and builds no
container images at all. There is nothing for the verb to do.

An empty success is indistinguishable from a real one — the failure shape that
recurred five times in Phase 5. An operator who runs `make image-build ENV=compose`
and sees exit 0 will reasonably conclude images were built. It must say the verb does
not apply to this env and exit non-zero.

### `build` is not a deployment verb

`make build` runs `scripts/maven/install-modules.sh` — Maven JARs, env-invariant, and
a *different concept* from `k8s-build` (container images) despite the shared word.
It stays exactly as it is and gains no `ENV=`.

---

## 4. Verification

### Layer A — expansion equivalence (offline, all three envs)

For every (verb, env) pair, assert `make -n <verb> ENV=<env>` expands to the same
command sequence as `make -n <old-target>`. The old targets are the oracle and are
independent of the new wrappers — the property that made Phase 5's goldens
trustworthy.

Three requirements, each from a failure this workstream actually hit:

- **Never compare empty against empty.** If either expansion yields no commands, fail.
  Phase 5 produced five vacuous assertions, two of them *inside guards*.
- **Normalise before diffing.** `make -n` emits echo lines and comment noise that
  differ cosmetically.
- **Declared differences asserted directionally.** `image-build ENV=compose`
  legitimately differs from every old target, and the suite must fail if that
  difference ever disappears — an intended behaviour that silently reverts is a
  regression a plain exclusion list would pass.

**Stated limit:** this proves the wrapper points at the right command, not that the
command works. Layer B covers that for compose; k8s and aws remain offline-only.

### Layer B — live compose

The real verb set against the running stack: `deploy` → `seed` → `status` →
`teardown`, plus `rebuild`.

---

## 5. Risks

- **Recursive make.** `k8s-bootstrap` ends in `@$(MAKE) k8s-status`. GNU make still
  runs `$(MAKE)` lines under `-n` so the sub-make can print. Harmless, but the
  comparison must expect nested output rather than read it as a mismatch.
- **Prerequisite order is load-bearing.** `k8s-bootstrap` chains nine prerequisites,
  and Phase 5 proved the order matters — `k8s-seed-mysql` must run after `k8s-apps`
  or `ecommerce.sql` hits `ERROR 1146` against a schema Hibernate has not created yet.
  The unified `bootstrap` must preserve the sequence exactly; Layer A is what proves
  it did.
- **A wrapper can drift from its target.** Both exist until Phase 8, so they can
  diverge silently. Layer A is the guard, and it belongs in CI.

## 6. Migration and rollback

Purely additive. Every existing target keeps working; the new verbs are thin wrappers
alongside them. **Rollback is "ignore the new verbs."** Phase 8 removes the old names
and performs the three file moves as one atomic relocation.

## 7. Out of scope

File moves (D1), the Helm switch (D3), removing or renaming any existing target,
env-specific targets (`k8s-tunnel`, `k8s-ctx`, `k8s-registry-forward`,
`k8s-stop/start`, `k8s-cluster-*`), the k6 and observability targets, `k9s`, and
`make build` (Maven).
