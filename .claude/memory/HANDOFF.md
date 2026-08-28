# HANDOFF

**Updated:** 2026-08-28 · **Branch:** `main` @ `320467d` · **Last:** PR #64 merged

## Current goal

None in flight. `ENV=aws` has now been **run against real AWS** — the thing five
phases shipped without ever demonstrating. The path works up to a live EKS cluster
with all nine services deployed; the remaining question is the acceptance tiers.

## Done recently

- **PR #63** — the two HTML teaching pages corrected from kind to minikube.
- **PR #64** (21 commits) — offline pre-flight for the first live `ENV=aws` run,
  **plus the run itself and the four fixes it produced.**

### What the run cost and proved

Two sessions, roughly **$6–8** total at ~$1.00/hr. Checkpoint 1 (infra) passed
cleanly: 3 nodes `Ready`, VPC/EKS/RDS/ElastiCache/IRSA/both Helm controllers all
created. Teardown verified clean twice — `terraform state list` at 0, every
`aws-leak-check` table empty.

### Blockers found by READING (offline, free)

1. `build.sh` probed every registry over plain HTTP → 75 s hang against ECR, then an
   error telling the operator to start minikube ([[a-shared-builder-assumes-its-local-registry]]).
2. `down.sh` named no kube context and swallowed transport failures with `|| true` →
   could strand a billing ALB with every command exiting 0
   ([[the-teardown-path-lacks-the-guards-the-creation-path-has]]).
3. The plan's `PUSH=all make aws-push` pushed one service out of ten.

### Blockers found by RUNNING (only discoverable live)

4. **`aws-deploy.sh` had `--set infra.enabled=false` in its render branch only**, so
   `make aws-diff-test` validated a command the live apply never issued
   ([[an-oracle-can-validate-a-command-nobody-runs]]). This is the most significant
   defect of the whole workstream.
5. `up.sh` ran `update-kubeconfig` only after a successful apply → a partial apply left
   a running, billing cluster the operator could not reach.
6. The four `PAYPAL_*` / `APPLICATION_MAIL_*` env vars were never exported, because the
   checkpoint design routes around `up-all.sh`'s Step 0 preflight
   ([[decomposing-a-wrapper-drops-what-it-did-besides-calling-steps]]).
7. `microecom.click` carried a registrar **`clientHold`** and resolved nowhere, so ACM
   validation burned its full 1h15m timeout after building ~143 resources. `up.sh` now
   refuses to start unless the apex domain delegates publicly.

## In progress — one loose end

A review of PR #64's **last three commits** (`97d1afc`, `80de663`) was dispatched
before the merge and had not returned when the branch merged. Those commits touch
billed-path scripts (`up.sh`'s new control flow under `set -euo pipefail`, the DNS
pre-check, `HELM_FLAGS`). **If it surfaces anything, the fix needs a fresh branch off
`main`** — `feat/aws-live-run` is merged and done.

Specifically worth confirming: `up.sh`'s `if CLUSTER_NAME="$(...)" && CLUSTER_REGION="$(...)"`
compound, and that a failed apply still exits non-zero after the kubeconfig wiring.

## Next, if picking something up

1. **Finish the acceptance tiers.** The deploy works; whether the *stack* works
   (tier 4 = an order completing through the saga) is still unconfirmed. Needs a
   billed session and roughly $2–4.
2. **The SMTP egress question.** Mail is wired for `ENV=aws`, but whether pods in
   private subnets can reach the SMTP host through the NAT gateway is unanswerable
   offline — it resolves at tier 3.
3. `deploy/README.md`'s Verification status still says `ENV=aws` is **NOT proven**.
   That is now partly false and should be updated with what the run established
   ([[a-gaps-registry-decays-through-success]]).

## Settled decisions

- [[0007-first-aws-run-keeps-k8s-1-31]] — pay the surcharge rather than confound the test.
- [[0008-unexercised-paths-run-in-checkpoints-not-one-shot]] — four checkpoints by failure domain.
- [[0005-aws-infra-stays-outside-the-umbrella-chart]] — and the live run showed exactly
  why: the umbrella tried to create objects `infra-up.sh`'s releases already owned.

## Context to load

- `docs/superpowers/plans/2026-08-21-aws-live-run.md` — Part B runbook, now with Checkpoint 0
- `docs/superpowers/plans/2026-08-21-aws-preflight-findings.md` — the audit and its gaps
- `scripts/aws/RUNBOOK.md` — the nine steps and teardown
- `deploy/README.md` — Verification status (stale, see Next #3)

## Blocked

Nothing. Standing constraints: `rm`/`git rm` and `git push` are human-gated, and **no
assistant runs a billed AWS command** — every `make aws-*`, `terraform`, and
`scripts/aws/*` invocation is the operator's.
