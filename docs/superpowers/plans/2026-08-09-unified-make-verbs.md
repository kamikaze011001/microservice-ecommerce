# Unified Make Verbs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** one command dialect — `make <verb> ENV=<env>` — replacing three, without removing or moving anything.

**Architecture:** a **data-driven dispatch table** in the Makefile. Each verb is a thin target that looks up `VERB_<verb>_<env>` and delegates to the existing target via `$(MAKE)`. An unmapped (verb, env) pair fails loudly *by construction* — no special-casing needed for combinations that have no meaning.

**Tech Stack:** GNU make, bash, python3. Tests are bash scripts printing `N passed, M failed`, matching `deploy/seed/tests/*.sh`.

**Design spec:** `docs/superpowers/specs/2026-08-09-unified-make-verbs-design.md`. Read it before Task 1.

## Global Constraints

These bind **every** task.

- **Never `git push`.** A pre-push hook owns pushing and it is the human's job in this repo. Never bypass it.
- **Purely additive.** No existing target may be renamed, removed, or have its recipe changed. No files move. Rollback is "ignore the new verbs." Verify with `git diff` that every Makefile change is an *addition*.
- **Nothing outside `Makefile`, `deploy/`, and `docs/`.** `docker/`, `scripts/`, `k8s/` stay byte-identical — check `git diff --stat docker/ scripts/ k8s/` is empty at every commit.
- **Never print a credential value.**
- Env names are exactly `compose`, `k8s`, `aws`.
- **An unmapped verb/env must exit non-zero with a specific message**, never succeed silently. Five vacuous-success defects surfaced in Phase 5; this is the same class.
- Every task ends with a commit, after running the tests it names.

## Verified mechanism (do not re-derive)

`make -n` propagates through `$(MAKE)`: a wrapper's expansion prints the sub-make invocation line followed by the *target's own* expansion. Confirmed 2026-08-09:

```
$ make -n --no-print-directory -f probe.mk -f Makefile probe
/Library/Developer/CommandLineTools/usr/bin/make --no-print-directory k8s-status
echo "== nodes =="; kubectl get nodes
...
```

So Layer A compares the wrapper's expansion (minus the leading `make …` line) against the old target's expansion. Always pass `--no-print-directory`.

## File Structure

| Path | Responsibility |
|---|---|
| `Makefile` | The dispatch table + 7 verb targets. Additive only. |
| `deploy/scripts/tests/verb-equivalence-test.sh` | Layer A: `make -n` expansion equivalence, all three envs. |
| `deploy/scripts/tests/verb-live-test.sh` | Layer B: the live verb set against compose. |
| `deploy/README.md` | The verb table + a Verification status section. |

---

## Task 1: Capture the expansion baseline

The oracle. Every later task is measured against what the OLD targets expand to today, captured before any Makefile change.

**Files:**
- Create: `deploy/scripts/tests/baseline/<target>.txt` (one per old target)
- Create: `deploy/scripts/tests/capture-baseline.sh`

- [ ] **Step 1: Capture every old target the verbs will wrap**

```
bootstrap  k8s-bootstrap  aws-all
svc-start  k8s-apps
status     k8s-status
down       k8s-down       aws-down
k8s-build  aws-push
svc-restart k8s-rebuild
```

Each as `make -n --no-print-directory <target>` → `baseline/<target>.txt`.

- [ ] **Step 2: Assert every capture is non-empty**

If any baseline file is empty, the capture is broken — an empty oracle makes every later comparison vacuous. Fail loudly, naming the target.

```bash
for f in deploy/scripts/tests/baseline/*.txt; do
  [ -s "$f" ] || { echo "FAIL: $(basename "$f") captured NOTHING — oracle is broken"; exit 1; }
done
```

- [ ] **Step 3: Record which targets have side effects under `-n`**

`k8s-bootstrap` ends in `@$(MAKE) k8s-status`, and `$(MAKE)` lines DO run under `-n` (that is how the sub-make prints). Confirm no captured target performs a real mutation during capture — read each recipe, and report anything that would.

- [ ] **Step 4: Commit**

```bash
git add deploy/scripts/tests
git commit -m "test(verbs): capture make -n expansion baseline for the old targets"
```

---

## Task 2: The dispatch table and the four 1:1 verbs

**Files:**
- Modify: `Makefile` (additive only)

**Interfaces:**
- Produces: `ENV` variable (default `compose`), `VERB_<verb>_<env>` lookup variables, a `dispatch` macro, and the targets `deploy`, `status`, `teardown`, `rebuild`.

- [ ] **Step 1: Add the table and the macro**

```make
# ── Unified verbs (Phase 6) ────────────────────────────────────────────────
# `make <verb> ENV=<env>` delegates to the existing target below. Additive:
# every old target still works and is unchanged. See
# docs/superpowers/specs/2026-08-09-unified-make-verbs-design.md
ENV ?= compose

VERB_deploy_compose    := svc-start
VERB_deploy_k8s        := k8s-apps
VERB_status_compose    := status
VERB_status_k8s        := k8s-status
VERB_teardown_compose  := down
VERB_teardown_k8s      := k8s-down
VERB_teardown_aws      := aws-down
VERB_rebuild_compose   := svc-restart
VERB_rebuild_k8s       := k8s-rebuild

# An unmapped (verb, env) pair fails HERE, by construction — no per-verb
# special case. A verb that silently succeeds where it has nothing to do is
# indistinguishable from one that worked.
dispatch = t="$(VERB_$(1)_$(ENV))"; \
  if [ -z "$$t" ]; then \
    echo "make $(1): not applicable for ENV=$(ENV)$(if $(VERB_$(1)_$(ENV)_WHY), — $(VERB_$(1)_$(ENV)_WHY))" >&2; \
    exit 1; \
  fi; \
  $(MAKE) --no-print-directory $$t
```

- [ ] **Step 2: Add the four verb targets**

```make
.PHONY: deploy status teardown rebuild
deploy:
	@$(call dispatch,deploy)
status:
	@$(call dispatch,status)
teardown:
	@$(call dispatch,teardown)
rebuild:
	@$(call dispatch,rebuild)
```

**Note:** `status` already exists as a compose target. Adding a `status` verb that dispatches to it would recurse. Resolve by naming the *compose* mapping's target explicitly and confirming `make status` (no ENV) still behaves as it does today — **run it and compare against the baseline**. If a collision is unavoidable, report it rather than renaming the old target (renaming violates a Global Constraint).

- [ ] **Step 3: Verify each verb expands to its target**

For each mapped pair, `make -n --no-print-directory <verb> ENV=<env>` minus its first line must equal `baseline/<target>.txt`.

- [ ] **Step 4: Verify an unmapped pair fails**

Run: `make deploy ENV=aws`
Expected: non-zero exit, message naming the verb and env. `deploy` has no aws mapping until Phase 7.

- [ ] **Step 5: Commit**

---

## Task 3: `bootstrap` and `image-build`

The two verbs with behaviour beyond a 1:1 wrap.

**Files:**
- Modify: `Makefile` (additive only)

- [ ] **Step 1: Add the mappings**

```make
VERB_bootstrap_compose  := bootstrap
VERB_bootstrap_k8s      := k8s-bootstrap
VERB_bootstrap_aws      := aws-all
VERB_image-build_k8s    := k8s-build
VERB_image-build_aws    := aws-push
VERB_image-build_compose_WHY := compose builds no container images (services run as JVM processes from Maven artifacts — see `make build`)
```

Note there is deliberately **no** `VERB_image-build_compose`, so the dispatch macro rejects it and prints the `_WHY` text.

- [ ] **Step 2: Add the targets**

```make
.PHONY: image-build
image-build:
	@$(call dispatch,image-build)
```

The `bootstrap` verb target is deliberately not written here — see "A note on the collisions" below. `bootstrap` already exists as the compose target name, and how to add the verb without renaming it is the implementer's call.

**`bootstrap` already exists as the compose target.** Same collision as `status` in Task 2 — resolve it the same way and report what you did. Do not rename the existing target.

- [ ] **Step 3: Verify `image-build ENV=compose` fails with the specific message**

Run: `make image-build ENV=compose`
Expected: exit non-zero, message naming compose and pointing at `make build`. **Not** exit 0, and not a generic "no mapping".

- [ ] **Step 4: Verify `bootstrap ENV=k8s` preserves prerequisite order**

`k8s-bootstrap` chains **nine** prerequisites, and the order is load-bearing: `k8s-seed-mysql` must run after `k8s-apps` or `ecommerce.sql` hits `ERROR 1146` against a schema Hibernate has not created. Diff the expansion against `baseline/k8s-bootstrap.txt` — it must match exactly, order included.

- [ ] **Step 5: Commit**

---

## Task 4: Layer A — expansion equivalence

**Files:**
- Create: `deploy/scripts/tests/verb-equivalence-test.sh`

- [ ] **Step 1: Write the suite**

For every (verb, env) in the table: capture `make -n --no-print-directory <verb> ENV=<env>`, strip the leading sub-make invocation line, and diff against `baseline/<target>.txt`.

- [ ] **Step 2: Guard against vacuous comparison**

**Both** sides must be non-empty before comparing. An empty expansion compared against an empty baseline "matches" and proves nothing — this exact shape produced five defects in Phase 5, two of them inside guards. Fail naming which side was empty.

- [ ] **Step 3: Encode the declared difference**

`image-build ENV=compose` has no baseline and must **fail to dispatch**. Assert that it exits non-zero and that its message names the env — and **fail if it ever starts succeeding**. A declared behaviour that silently reverts is a regression an exclusion list would pass.

- [ ] **Step 4: Prove the suite can fail**

Point one `VERB_*` mapping at the wrong target, confirm the suite reports that verb, names both sides, and exits non-zero. Restore and re-run green. Verify the restore with `git diff --stat Makefile`.

- [ ] **Step 5: Commit**

---

## Task 5: Layer B, docs, and entry points

**Files:**
- Create: `deploy/scripts/tests/verb-live-test.sh`
- Modify: `Makefile` (test targets), `deploy/README.md`

- [ ] **Step 1: Write the live compose run**

`deploy` → `seed` → `status` → `rebuild` against the running compose stack, asserting each exits 0 and the stack still serves afterwards.

**Do not run `teardown ENV=compose` as part of the suite** — it would stop the stack later tasks and other work need. Verify its *expansion* in Layer A instead, and say so in the report.

- [ ] **Step 2: Add make targets for both suites**

The Phase 5 suites shipped with no entry point and had to be retrofitted; do not repeat that. Follow the style of `seed-test-equivalence` / `seed-live-verify`.

- [ ] **Step 3: Document in `deploy/README.md`**

The verb table, the `ENV` default, what `image-build ENV=compose` does and why, and a **Verification status** section stating plainly:
- proven live: the compose verb set
- proven offline: expansion equivalence for all three envs
- **not proven:** no verb has been executed against k8s or aws — no cluster exists, and `deploy ENV=aws` is unmapped until Phase 7

Match the candour of the existing Verification status sections; do not soften the last point.

- [ ] **Step 4: Verify**

Both suites pass. `git diff --stat docker/ scripts/ k8s/` empty. Every old target still resolves: spot-check `make -n bootstrap`, `make -n k8s-bootstrap`, `make -n status` against Task 1's baselines.

- [ ] **Step 5: Commit**

---

## A note on the collisions

`bootstrap` and `status` already exist as compose target names, and the verb set wants those same words. This is the one genuinely fiddly part of the plan, and it is deliberately left to the implementer to resolve rather than prescribed here — because the right answer depends on GNU make behaviour that should be *tested*, not assumed, and the Global Constraints forbid the obvious shortcut (renaming the old target).

Whatever you choose, `make bootstrap` and `make status` with **no `ENV=`** must keep behaving exactly as they do today — that is what the Task 1 baselines are for. Report what you did and why.

## Verification summary

| Layer | Scope | Gate |
|---|---|---|
| `verb-equivalence-test.sh` | every (verb, env), offline, all three envs | all mapped pairs match their baseline; the declared difference still differs |
| `verb-live-test.sh` | compose verb set, live | all exit 0, stack still serves |
| `git diff --stat docker/ scripts/ k8s/` | the frozen trees | empty at every commit |
| old targets | backwards compatibility | expansions unchanged from baseline |
