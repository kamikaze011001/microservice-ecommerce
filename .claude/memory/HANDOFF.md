# HANDOFF

**Updated:** 2026-08-21 · **Branch:** `feat/aws-live-run` · **Base:** `main` @ `c548f9e`

## Current goal

Deploy `ENV=aws` for the first time and establish whether the stack works. Five phases
shipped AWS support verified only by `helm template` against fixtures — no EKS cluster
has ever been created by this repo and `terraform apply` has never run against
`aws/main`. Run as a coworking/learning exercise: the operator is new to AWS, Kubernetes
and Terraform, so failures are made legible rather than rushed past.

## Done recently

- **PR #63** — the two HTML teaching pages corrected from kind to minikube. Not a rename:
  three mechanisms were wrong (registry, ingress exposure, and a SCAR describing a
  deleted code path).
- Established that **no unfinished AWS work exists**. Both `feat/aws-deploy` (76 commits
  ahead) and `feat/aws-live-deploy` (1 ahead) contain nothing `main` lacks — see
  [[branch-ahead-count-measures-divergence-not-value]]. Phase 5b shipped weeks ago;
  `aws/main/dns.tf` and `external-dns.tf` are on main.
- Spec `238c0bc` and plan `757d658` written and committed for the live run.

## In progress — `feat/aws-live-run`

Part A (offline pre-flight) of `docs/superpowers/plans/2026-08-21-aws-live-run.md`:

- **Task 1 COMPLETE** (`320fa58`, review clean) — `build.sh`'s registry probe scoped to
  local registries. This was a hard blocker: ECR hangs 75 s on port 80 then blames
  minikube ([[a-shared-builder-assumes-its-local-registry]]).
- **Task 2 COMPLETE** (`320fa58..8ea93d0`, review clean) — `down.sh` now proves which
  cluster it is destroying. Fix round 1 corrected a defect in the PLAN, not the
  implementation ([[errexit-consumes-a-functions-exit-code]]). Two deferred minors are
  in the SDD ledger.
- **Task 3 IN FLIGHT** — read-only audit of steps 2–9 for the same defect class, plus
  the mail/OTP verdict that acceptance tier 3 depends on.
- Then a triage gate turning must-fix findings into tasks, a whole-branch review, and
  finally **Part B: the billed run** (operator-executed only).

## Settled decisions

- [[0007-first-aws-run-keeps-k8s-1-31]] — pay the extended-support surcharge rather than
  confound the test by changing the cluster version.
- [[0008-unexercised-paths-run-in-checkpoints-not-one-shot]] — four checkpoints grouped
  by failure vocabulary, not one `make aws-all`.
- [[0005-aws-infra-stays-outside-the-umbrella-chart]] — **does not block this run**; it
  blocks folding infra into the chart, which this design deliberately does not do.
- Verified live 2026-08-20: the `microecom.click.` zone exists, `aws/bootstrap` is
  applied (state bucket, lock table, 11 ECR repos), `aws/main` state is empty, and ECR
  holds stale `:dev` tags so `PUSH=all` is mandatory.
- Cost with the surcharge: ~$1.00/hr, ~$4 for a four-hour session, ~$732/month if left
  running. Teardown is mandatory every session.

## Context to load

- `docs/superpowers/specs/2026-08-21-aws-live-run-design.md` — the design and rationale
- `docs/superpowers/plans/2026-08-21-aws-live-run.md` — Part A tasks, Part B runbook
- `.superpowers/sdd/2026-08-21-aws-live-run/progress.md` — the SDD ledger (gitignored)
- `scripts/aws/RUNBOOK.md` — the nine steps and teardown
- `deploy/README.md` — Verification status, including what `ENV=aws` has never proven

## Blocked

Nothing blocked. Three standing constraints: `rm`/`git rm` and `git push` are
human-gated, and **no assistant may run a billed AWS command** — every `make aws-*`,
`terraform`, and `scripts/aws/*` invocation is the operator's to execute.
