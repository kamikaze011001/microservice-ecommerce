# AWS Cut-over — Design

**Phase 7** of the deploy refactor (`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`).
Follows Phase 6 (unified make verbs), whose `deploy ENV=aws` mapping this fills in.

**Goal:** make the Helm chart produce what AWS actually needs, prove it against the
existing AWS deployment definition, and wire the deploy-time inputs — offline.

---

## 1. What is already true

The parent spec's Phase 7 reads as a porting task ("write `envs/aws.yaml`", "port ESO,
IRSA, ALB ingress into chart templates"). **Most of that already exists**, built during
Phase 3:

- `deploy/charts/microecom/envs/aws.yaml` — 90 lines
- `charts/apps/templates/externalsecrets.yaml`
- `charts/apps/templates/irsa-serviceaccounts.yaml`
- `charts/apps/templates/ingress.yaml`

So Phase 7 is **not** porting. It is making the ported templates produce the right
output and proving they do.

### CORRECTION (2026-08-13): the gap did not exist

**An earlier draft of this section claimed the chart's aws path was broken. That was a
measurement error, and the claim is withdrawn.** It is recorded here rather than deleted
because the *reasoning* it produced is still what shapes this phase.

Two false claims, both from commands that silently dropped data:

1. **"The chart renders 4 objects for aws."** It renders **43**. The hand-render omitted
   `--namespace infra`, which the test suite's own `render()` helper always passes.
   Without the flag: 4 objects. With it: 43.
2. **"`apps_render` is called 6 times, none pass `envs/aws.yaml`."** `render-test.sh:826-836`
   builds an `ALB_ARGS` array containing `envs/aws.yaml` and calls
   `apps_render "${ALB_ARGS[@]}"`, asserting `"aws values render"` plus ALB, IRSA and ESO
   properties. The grep required both tokens on one line; they are on different lines.

### What is actually true, measured

The chart's aws render and the composed oracle agree on **every kind except Namespace**:

| kind | chart | oracle |
|---|---|---|
| Service · Deployment · ExternalSecret · HPA · ServiceAccount | 10 · 10 · 9 · 5 · 3 | identical |
| Role · RoleBinding · Ingress | 1 · 1 · 1 | identical |
| **Namespace** | **3** | **1** |

The Namespace delta is the umbrella's `templates/namespaces.yaml` rendering all three
non-infra namespaces — pre-existing, unrelated to AWS, and a candidate declared
difference rather than a defect.

**So the porting is done and the rendering works.** What remains is genuinely unfinished:
no test compares chart output to the overlay *object-by-object* (only individual
properties), the three deploy-time inputs are still assembled by hand, and Phase 6's
`VERB_deploy_aws` mapping is still empty.

### Two asymmetries, resolved before being declared

- **9 ExternalSecrets for 10 Deployments is CORRECT.** They cover every service except
  `frontend`, a static SPA with no secrets to fetch.
- **The overlay's only ServiceAccount is `gateway`, unannotated** — the Spring Cloud
  Kubernetes discovery account that pairs with the Role/RoleBinding, not an IRSA one.

---

## 2. Decisions

### D1 — The old path is the oracle, and it is COMPOSED FROM TWO SOURCES

```
kubectl kustomize k8s/apps/overlays/aws                    → 39 objects
+ k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml       → applied out-of-band
    with s3_irsa_role_arn substituted
```

**`s3-irsa-serviceaccounts.yaml` is NOT referenced in the overlay's
`kustomization.yaml`.** `scripts/aws/up-all.sh:127-137` reads
`terraform output -raw s3_irsa_role_arn`, substitutes it into that file, and pipes the
result to `kubectl apply`.

This matters concretely: diffing against `kustomize build` alone would make the chart's
IRSA ServiceAccounts look like an invented addition, and a difference would be declared
that is not one.

*Rejected:* hand-written assertions from the design docs. The overlay is what AWS
actually gets today; a hand-written expectation would encode what someone believed it
gets. Phases 4 and 5 both proved the old path is the trustworthy oracle.

### D2 — Offline first; live EKS is a decision at the end, not a prerequisite

Close the render gap, add the missing coverage, wire the inputs — all free. Decide
about a billed `make deploy ENV=aws` once there is something worth spending on.

*Rejected:* making a live EKS run the acceptance gate (commits real spend and a cluster
bring-up before the offline gaps are even closed), and offline-only-by-policy (would
foreclose the decision rather than defer it).

### D3 — No new Terraform; Phase 7 only consumes outputs

`s3_irsa_role_arn` and the ECR registry already exist. Phase 7 wires them into the
deploy path, replacing today's manual
`HELM_EXTRA='--set apps.irsa.s3RoleArn=$(terraform output -raw s3_irsa_role_arn)'`.

This also honours the standing preference that Terraform authoring in this repo is the
human's, for learning. Chart templates, values files and deploy scripts are not that.

### D4 — Nothing is deleted

The kustomize overlay stays: it is the oracle. Deleting it is Phase 8's job, and Phase 8
must decide deliberately what replaces it — see §5.

---

## 3. Scope

**In:** close the apps-with-aws render gap until the chart reproduces the composed
oracle; add `apps_render × envs/aws.yaml` coverage; wire the three deploy-time inputs
(`s3_irsa_role_arn`, ECR registry, image tag); fill Phase 6's deliberately-empty
`deploy ENV=aws` mapping.

**Out:** new Terraform; a live EKS run; deleting the overlay; any change to
`docker/` or `scripts/`.

---

## 4. Verification

**Layer A — differential render, offline, free, CI-able.** The chart's aws render must
reproduce the composed oracle, modulo declared differences, each asserted **in the
stated direction and failing if it ever disappears**. Fixture terraform outputs stand
in for real ones, exactly as Phase 5's aws leg did.

**Coverage added:** `apps_render` with `envs/aws.yaml` — currently zero occurrences in
268 tests.

**Non-negotiable guards.** Seven "empty result masquerading as a negative result"
defects have landed across Phases 5 and 6, several *inside guards written to prevent
them*. So: assert both sides non-empty **and** object counts non-zero before comparing.
A chart rendering 4 objects against an oracle of 41 must fail loudly, never diff two
near-empty streams.

---

## 5. Risks

- **The oracle drifts.** Half of it comes from a script, so an edit to `up-all.sh`
  silently invalidates it. Capture must be mechanical and re-runnable, never
  hand-transcribed.
- **`--set` vs `--set-string`.** Helm's `--set` treats dots as path separators, so an
  ECR hostname like `583178372344.dkr.ecr.ap-southeast-1.amazonaws.com` silently
  becomes nested keys instead of a string. This produced two wrong renders during this
  design session. The deploy path must use `--set-string`, and the suite should assert
  it.
- **`--namespace infra` is load-bearing for any hand render.** Omitting it silently
  yields 4 objects instead of 43 — this produced the withdrawn premise above. Any script
  or doc that renders the chart must pass it.
- **Two fail-loud paths are inconsistent.** A missing `s3RoleArn` fails with a clear
  named message; a missing registry/tag fails with an opaque
  `YAML parse error … mapping values are not allowed in this context`. Both are
  deliberate refusals; only one is legible.
- **Phase 8 deletes the overlay, and with it this oracle.** That is the third instance
  of the same debt (the Phase 4 secrets goldens and the Phase 5 seed goldens are the
  others). Phase 8 needs one deliberate decision covering all three, not three
  rediscoveries.
- **No live verification.** This would be the fourth consecutive phase shipping an
  unexercised transport. It must be stated plainly in `deploy/README.md`, not implied.

## 6. Findings raised, not fixed

- `scripts/aws/up-all.sh` has **no confirmation prompt** before a real EKS apply
  (`grep -c 'read -p'` → 0). Phase 6 removed the accidental path to it (an exported
  `ENV` no longer redirects `make bootstrap`), but the target itself remains unguarded.
  Worth a prompt before anyone wires it into CI.
