# AWS Cut-over — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make the Helm chart produce what AWS needs, prove it against the existing AWS deployment definition, and wire the deploy-time inputs — entirely offline.

**Architecture:** differential. The existing AWS overlay is the oracle; the chart's aws render must reproduce it, modulo declared differences. Same shape as Phases 4 and 5, where the old path was the trustworthy reference.

**Tech Stack:** Helm 3, kustomize (via `kubectl kustomize`), bash, python3. Tests print `N passed, M failed`, matching `deploy/seed/tests/*.sh`.

**Design spec:** `docs/superpowers/specs/2026-08-12-aws-cutover-design.md`. Read it before Task 1.

## Global Constraints

- **Never `git push`.** A pre-push hook owns pushing and it is the human's job. Never bypass it.
- **Never run anything that costs money.** No `make aws-all`, `aws-up`, `aws-infra-up`, `deploy ENV=aws` for real, no `terraform apply`. `helm template` and `kubectl kustomize` are offline and safe. **`scripts/aws/up-all.sh` has no confirmation prompt** — treat every `aws-*` target as live-fire.
- **No new Terraform.** Phase 7 consumes existing outputs only. Terraform authoring in this repo is the human's.
- **Delete nothing.** `k8s/apps/overlays/aws/` is the oracle and stays. `docker/` and `scripts/` byte-identical — check `git diff --stat` against each at every commit.
- **Never print a credential value.** An AWS account ID in an ECR hostname is not a secret; a role ARN is not a secret; anything that looks like a key is.
- **`--set-string`, never `--set`, for any value containing dots.** Helm's `--set` treats dots as path separators, so an ECR hostname silently becomes nested keys. This produced two wrong renders while designing this plan.
- Every task ends with a commit, after running the tests it names.

## File Structure

| Path | Responsibility |
|---|---|
| `deploy/charts/microecom/tests/aws-oracle/` | Captured oracle + the capture script. |
| `deploy/charts/microecom/tests/aws-diff-test.sh` | The differential suite. |
| `deploy/charts/microecom/tests/fixtures/aws-tf-outputs.json` | Fixture terraform outputs (no AWS needed). |
| `deploy/charts/microecom/envs/aws.yaml` | Fixes, if the gap is a values problem. |
| `deploy/charts/microecom/charts/apps/templates/*` | Fixes, if it is a template problem. |
| `Makefile` | `VERB_deploy_aws` mapping + a test target. |
| `deploy/README.md` | AWS section + Verification status. |

---

## Task 1: Capture the composed oracle

**Files:**
- Create: `deploy/charts/microecom/tests/aws-oracle/capture.sh`
- Create: `deploy/charts/microecom/tests/aws-oracle/oracle.yaml`
- Create: `deploy/charts/microecom/tests/fixtures/aws-tf-outputs.json`

**The oracle is COMPOSED FROM TWO SOURCES. Both are required.**

```
kubectl kustomize k8s/apps/overlays/aws
+ k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml, with s3_irsa_role_arn substituted
```

The second file is **not** in the overlay's `kustomization.yaml`. `scripts/aws/up-all.sh:127-137` reads `terraform output -raw s3_irsa_role_arn`, substitutes it, and pipes to `kubectl apply`. Read those lines and reproduce the substitution exactly — do not invent it.

- [ ] **Step 1: Write the fixture terraform outputs**

`s3_irsa_role_arn` and the ECR registry. Use obviously-fake-but-well-formed values (e.g. account `000000000000`) so nobody mistakes the fixture for real infrastructure.

- [ ] **Step 2: Capture**

Run: `bash deploy/charts/microecom/tests/aws-oracle/capture.sh`
Expected: `oracle.yaml` containing **39 objects from kustomize plus the 2 IRSA ServiceAccounts = 41**.

- [ ] **Step 3: Assert the composition actually happened**

Both halves must be present, asserted separately. Expected from the kustomize half:

```
10 Deployment · 10 Service · 9 ExternalSecret · 5 HorizontalPodAutoscaler
1 ServiceAccount · 1 Role · 1 RoleBinding · 1 Namespace · 1 Ingress   = 39
```

And from the second half: at least one ServiceAccount carrying an `eks.amazonaws.com/role-arn` annotation. **If the IRSA half contributes nothing, the capture is broken** — the whole reason this task exists is that `kustomize build` alone misses it.

- [ ] **Step 4: Assert 9-vs-10 is the expected asymmetry**

Exactly one Deployment must lack an ExternalSecret, and it must be `frontend` (a static SPA with no secrets). If a different service is missing one, that is a finding — report it.

- [ ] **Step 5: Commit**

---

## Task 2: Diagnose and close the render gap

**This task has an unknown size. Diagnose before estimating, and report the diagnosis before fixing.**

Rendering the chart's apps subchart with `envs/aws.yaml` currently produces **4 objects** (3 Namespaces + 1 ServiceAccount) against the oracle's 39+. It may be a values-plumbing problem or a template problem; nothing established yet distinguishes them.

**Files:** whichever the diagnosis indicates — `envs/aws.yaml`, `charts/apps/templates/*`, or `charts/apps/values.yaml`.

- [ ] **Step 1: Reproduce**

```bash
helm template microecom deploy/charts/microecom \
  -f deploy/charts/microecom/envs/aws.yaml \
  --set apps.enabled=true --set infra.enabled=false \
  --set-string apps.irsa.s3RoleArn=<fixture> \
  --set-string global.appImage.registry=<fixture> \
  --set-string global.appImage.tag=abc1234
```

**Use `--set-string` for all three** — the ECR hostname and the ARN both contain dots and colons.

- [ ] **Step 2: Diagnose, and report before fixing**

Determine *why* the services loop yields nothing. Compare against the working `envs/local-k8s.yaml` invocation. Note `local-k8s.yaml` nests service overrides under `apps.apps.<name>` while `aws.yaml` uses `apps.defaults` — establish whether the service list is being replaced rather than merged.

**Report the diagnosis and your estimate of the repair before making it.** If it is structural — the subchart cannot express what the overlay does — say so plainly rather than forcing a fix.

- [ ] **Step 3: Fix**

Smallest change that makes the chart render the apps for aws. Do not restructure the chart to make a diff match; a difference that reveals a real design gap is a finding, not an obstacle.

- [ ] **Step 4: Verify**

The render succeeds and produces Deployments, Services, ExternalSecrets and an ALB ingress. Exact equality with the oracle is Task 3's job — here, non-empty and structurally plausible is enough.

- [ ] **Step 5: Confirm no regression**

`bash deploy/charts/microecom/tests/render-test.sh` → **268 passed, 0 failed**. The local-k8s path must be untouched.

- [ ] **Step 6: Commit**

---

## Task 3: The differential suite

**Files:**
- Create: `deploy/charts/microecom/tests/aws-diff-test.sh`

- [ ] **Step 1: Compare by kind and name, not raw text**

Group both sides into `(kind, name)` and compare. Raw text diff will drown in ordering and formatting noise; the question is whether the same objects exist with the same substance.

- [ ] **Step 2: Guard against vacuous comparison — MANDATORY**

Assert **both sides are non-empty AND the object count is plausible** (the oracle has 39+; a chart render of 4 must fail loudly, not diff two near-empty streams). Seven "empty result masquerading as a negative result" defects have landed across Phases 5 and 6, several *inside guards written to prevent them*.

- [ ] **Step 3: Declared differences, asserted directionally**

Any object the chart legitimately adds or omits versus the oracle goes in a declared table, each asserted **to differ in the stated direction** and to **FAIL if it ever matches again**. An exclusion list would let an intended improvement silently revert.

Do not add an entry you cannot explain. The 9-vs-10 ExternalSecrets and the gateway-vs-IRSA ServiceAccount were both resolved during design precisely so they would not be declared blindly.

- [ ] **Step 4: Prove the suite can fail**

Perturb one chart value so an object changes, confirm the suite names it and exits non-zero, restore byte-exactly, re-run green. Verify the restore with `git diff --stat`.

- [ ] **Step 5: Commit**

---

## Task 4: Wire the deploy-time inputs

**Files:**
- Modify: `Makefile`
- Create: `deploy/scripts/aws-deploy.sh` (or similar) — the new wiring helper

**PRE-FLIGHT RESOLUTION (human-approved).** The existing aws deploy path is
`scripts/aws/up-all.sh`, which the Global Constraints freeze. **Do not edit it.** Put
the wiring in a NEW helper under `deploy/`, and point `VERB_deploy_aws` at that. This
keeps the build-alongside property every prior phase held: `up-all.sh` keeps working
untouched, rollback stays "don't call the new verb", and Phase 8 deletes the old path
as one atomic step. The Makefile comment saying Phase 7 "moves that into the AWS deploy
script" predates this decision — the destination is the new helper, not `up-all.sh`.

- [ ] **Step 1: Replace the manual `HELM_EXTRA` incantation**

Today the ARN is passed by hand:
`make k8s-apps-helm ENV=aws HELM_EXTRA='--set apps.irsa.s3RoleArn=$(terraform output -raw s3_irsa_role_arn)'`

Wire the three inputs — `s3_irsa_role_arn`, ECR registry, image tag — into the deploy path so the operator does not assemble them. **`--set-string` for all three.**

- [ ] **Step 2: Fill `VERB_deploy_aws`**

Phase 6 left it deliberately empty, so `make deploy ENV=aws` currently fails with "not applicable". Map it at the new helper.

**Expect `verb-equivalence-test.sh` to FAIL until you update its total-count assertion.** Phase 6 added `assert len(results) == 20` specifically so a refactor could not silently empty the check list. Adding a mapping makes it 21. That failure is the guard working — update the count and add the new pair to the suite's coverage, do not weaken or remove the assertion.

- [ ] **Step 3: Make a missing terraform output fail legibly**

A missing `s3RoleArn` already fails with a clear named message; a missing registry/tag fails with an opaque `YAML parse error … mapping values are not allowed in this context`. Both are deliberate refusals; make the second one legible too.

- [ ] **Step 4: Verify offline**

`make -n deploy ENV=aws` resolves correctly. **Do not run it for real.**

- [ ] **Step 5: Commit**

---

## Task 5: Docs and entry points

**Files:**
- Modify: `deploy/README.md`, `Makefile`

- [ ] **Step 1: Make target for the new suite**

Phase 5's suites shipped with no entry point and had to be retrofitted; Phase 6 fixed that pattern. Follow `seed-test-equivalence` / `verb-test-equivalence`.

- [ ] **Step 2: Document the AWS path**

The three deploy-time inputs and where they come from; that the oracle is composed from two sources and why; `--set-string`; and a **Verification status** section stating plainly:

- proven offline: the chart's aws render matches the composed oracle
- **NOT proven: no AWS deployment has been executed.** No EKS cluster was created, `terraform apply` never ran, and fixture outputs stood in for real ones throughout. This is the fourth consecutive phase shipping an unexercised transport.

Match the candour of the existing Verification status sections — there are three now.

- [ ] **Step 3: Verify**

All suites pass: chart `render-test` 268/0, the new aws diff suite, `verb-equivalence-test` 20/0 (or 21 with the new mapping), seed and secrets suites unaffected. `git diff --stat docker/ scripts/` empty.

- [ ] **Step 4: Commit**

---

## Verification summary

| Layer | Scope | Gate |
|---|---|---|
| `aws-oracle/capture.sh` | the composed oracle | both halves present; 41 objects |
| `aws-diff-test.sh` | chart aws render vs oracle | all match or declared-different; 0 unexplained |
| `render-test.sh` | local-k8s unaffected | 268 passed, 0 failed |
| `verb-equivalence-test.sh` | verbs unaffected | all mappings match baselines |
| `git diff --stat docker/ scripts/` | frozen trees | empty |
