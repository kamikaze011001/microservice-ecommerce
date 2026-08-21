# AWS live run — design

**Date:** 2026-08-21 · **Branch:** `feat/aws-live-run` · **Base:** `main` @ `c548f9e`

## Goal

Deploy `ENV=aws` for the first time and establish whether the stack works. Five
consecutive phases have shipped AWS support verified only by `helm template`
against fixtures; no EKS cluster has ever been created by this repo and
`terraform apply` has never run against `aws/main`.

This is also a learning exercise. The operator is new to AWS, Kubernetes and
Terraform, so the run is structured to make failures legible rather than to
finish quickly.

## Context — verified, not assumed

Checked live against account `583178372344` on 2026-08-20:

| Prerequisite | State |
|---|---|
| Identity | `arn:aws:iam::583178372344:user/microecom-admin` |
| Route 53 zone `microecom.click.` | **exists** — `dns.tf:28` is a data source and would fail the plan if absent |
| `aws/bootstrap` | **applied** — state bucket `microecom-tfstate-583178372344`, DynamoDB lock table, 11 ECR repos |
| `aws/main` remote state | **empty** — `terraform state list` returns nothing |
| ECR contents | `:dev` tags present, but predate Phases 7–8 and PRs #59–63 |

`terraform init` has already run in `aws/main`; `terraform.tfvars` exists,
sets `node_desired_size` and `db_master_password`, and is gitignored
(`aws/.gitignore:5`).

## Decisions

### D1 — Kubernetes 1.31, unchanged, surcharge accepted

`eks.tf` pins `cluster_version = "1.31"`, whose standard support ended
2025-11-26. Running it incurs AWS's extended-support surcharge of +$0.60/hr,
taking the stack from ~$0.40/hr to ~$1.00/hr.

We keep it anyway. The controllers are pinned to 2024-era versions —
`aws-load-balancer-controller` chart `1.8.1` (`alb-controller.tf:65`),
`external-dns` chart `1.15.0` (`external-dns.tf:70`), EKS module `~> 20.0`
(`eks.tf:42`) — all contemporaries of Kubernetes 1.30–1.31. Bumping the cluster
to a supported version (1.34+) would run those controllers three or more minor
versions ahead of anything they were tested against, and the ALB controller is
not optional: if it fails, no Ingress is reconciled, no load balancer exists,
and the storefront never comes up.

**Why:** the purpose of this run is to test the stack *as written*. Changing the
Kubernetes version changes the thing under test, so a failure could no longer be
attributed to the stack rather than to our own edit. The cost delta is ~$2.40 per
four-hour session; a confounded result costs an evening.

**Revisit when:** the stack is proven working. Bumping the cluster and the
controllers together then becomes an informed change with a known-good baseline
to diff against.

### D2 — Four checkpoints, grouped by failure domain

The RUNBOOK defines nine steps and `make aws-all` runs them in one shot. We run
them in four groups instead, each ending in an explicit verification:

| CP | Steps | Entry points | Failure vocabulary |
|---|---|---|---|
| 1 | 0–1 | `make aws-up` | AWS-shaped: quotas, spot capacity, IAM propagation, subnets |
| 2 | 2–3 | `make aws-push`, `make aws-infra-up` | credential- and storage-shaped: ECR auth, IRSA trust, PVC binding |
| 3 | 4–6 | `deploy/scripts/seed.sh`, `secrets-seed.sh`, `make aws-deploy-apps` | Kubernetes-shaped: crashloops, ExternalSecret resolution, readiness |
| 4 | 7–9 | post-apps seeds, then acceptance and teardown | data-shaped: schema, seeding, S3 |

**Why:** the failure modes at each boundary use entirely different vocabularies.
Letting two layers fail in one run means reading two unrelated error languages
simultaneously, which is the single biggest obstacle for someone learning the
stack. Each checkpoint is also a clean stopping point — continue from it, or tear
down.

### D3 — a full rebuild is mandatory, via `svc=all`

ECR holds `:dev` tags, but they predate Phases 7–8 and PRs #59–63, so reusing
them would deploy images that do not match `main` and any failure would be
unattributable.

**The knob depends on the entry point, and this bit us.** `PUSH=all` is read
*only* by `scripts/aws/up-all.sh:61`, which D2 deliberately routes around — the
checkpoint plan calls the individual entry points instead. The knob that
`make aws-push` reads is `svc`: `Makefile:817` passes `$(svc)` through to
`push-images.sh`, whose line 36 is `TARGET="${1:-gateway}"`. So the correct
command is **`make aws-push svc=all`** (matching `scripts/aws/RUNBOOK.md:53`);
`PUSH=all make aws-push` sets a variable nothing on that path reads and pushes
gateway plus `maven-cores` only.

That failure is silent: the stale tags exist and pull fine, so seven services,
the frontend and mock-paypal would run months-old images and misbehave at
Checkpoint 3 — the checkpoint this design already calls the most likely to
fail — while billing. It was caught by the final review, not by any suite.

With `svc=all`, `push-images.sh:44` leaves `SVC` unset when invoking
`build.sh`, which builds `maven-cores` plus every service — there is no
`SKIP_CORES` trap on this path.

Both reuse shortcuts in `deploy/images/build.sh` are gated on `REUSE_EXISTING`
(lines 61 and 88), which is unset here, so `all` genuinely rebuilds.

### D4 — Memory `0005` does not block this run

`0005` records that consolidating AWS infra into the umbrella chart requires a
release-name decision first. The current design deliberately keeps them
separate: `infra-up.sh` applies raw manifests from `deploy/aws-infra/`, and
`aws-deploy.sh` installs apps with `--set infra.enabled=false`. Because Helm
never owned the infra objects, the toggle deletes nothing. `0005` blocks a future
refactor, not this deploy.

## Cost

Region `ap-southeast-1`. Baseline, excluding NAT data processing and ALB LCUs:

| | With D1's 1.31 surcharge |
|---|---|
| Per hour | ~$1.00 |
| Four-hour session | ~$4.00 |
| Day | ~$24 |
| Month, left running | ~$732 |

Drivers: EKS control plane $0.10/hr (+$0.60/hr extended support), node group
~$0.12/hr (3× `t4g.large`, SPOT), NAT gateway $0.059/hr. RDS primary + replica
(`db.t4g.micro`), ElastiCache (`cache.t4g.micro`), the ALB and 14 GB of EBS are
each pennies per hour.

`aws/bootstrap` survives teardown and is effectively free, except ECR image
storage — its lifecycle policy expires only *untagged* images, so repeated
`:dev` pushes accumulate.

## Known blockers — must be fixed before any spend

### B1 — `build.sh`'s registry probe kills the AWS image push

`deploy/images/build.sh:28` probes the registry over plain HTTP:

```bash
if ! curl -fsS -o /dev/null "http://${REGISTRY}/v2/" 2>/dev/null; then
  echo "ERROR: registry at ${REGISTRY} is not reachable." >&2
  echo "Run 'make k8s-cluster-up' or 'make k8s-registry-forward' first." >&2
  exit 1
fi
```

`push-images.sh:33` sets `REGISTRY` to the ECR host and calls `build.sh` with no
bypass. Measured against the real endpoint:

```
curl: (28) Failed to connect to 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com
      port 80 after 75028 ms: Couldn't connect to server
```

Step 2 therefore hangs ~75 s and exits 1, pointing the operator at minikube.

The probe is not wrong, only mis-scoped: it exists to catch a stopped local
registry, and on the AWS path it is redundant because `push-images.sh:40`
already runs `docker login` against ECR. Fix: apply the probe only to a local
plain-HTTP registry, and bound it with `--max-time` so it can never hang.

Offline suites never caught this because `make aws-diff-test` renders Helm
templates and never executes `build.sh` — the gate and the defect occupy
different universes.

### B2 — `down.sh` has no kubectl context guard

`scripts/aws/down.sh` deletes the Ingresses so the Load Balancer Controller
deprovisions the ALB, then destroys. It never asserts which cluster `kubectl`
points at, while `up-all.sh` passes `--context microecom-eks` explicitly at every
seed step (lines 142, 215, 228, 253).

With `kubectl` still pointed at minikube, both deletes succeed as no-ops, the
script waits 60 s for a controller it never contacted, and `terraform destroy`
proceeds while the real ALB keeps billing — invisible to `terraform state list`.
Every command exits 0.

The guard is present on the creation path and absent on the teardown path, which
inverts where the risk lives. Fix: assert the current context before deleting
anything, and fail loudly otherwise.

## Pre-flight audit

B1 was findable for free in about thirty seconds by reading a script, and it
survived five phases of green offline suites. Steps 2–9 are entirely unexercised
code and this failure class — a local-development assumption on a remote path —
is precisely what offline verification cannot catch.

Before any billed command, audit steps 2–9 for:

- hardcoded `localhost` / `127.0.0.1` on paths that run against AWS
- `http://` against remote hosts
- minikube, Docker Desktop or kind assumptions
- missing `kubectl` context assertions
- unbounded network calls (no `--max-time`, no timeout)
- error messages naming the wrong system
- references to files Phase 8 deleted
- ordering assumptions the Helm cut-over changed

Every blocker found here is one not paid for at EKS rates. Deliverables: the B1
and B2 fixes, plus a findings list triaged into must-fix-before-run and
note-and-proceed.

## Acceptance — what "the stack works" means

Tiered, in increasing depth:

1. **Reachable** — `https://shop.microecom.click` loads, ACM certificate valid
2. **Read path** — product catalog renders, images load from the S3 media bucket
3. **Auth path** — registration and login succeed
4. **Write path and saga** — add to cart, place an order, and the saga completes:
   Mongo CDC → Kafka Connect → orchestrator → payment → inventory over gRPC

Tiers 1–2 mean the deploy worked. **Tier 4 means the stack works normally** and
is the bar for this phase, because an order completing end to end exercises
essentially every component.

Open risk: tier 3 depends on OTP delivery, which needs working mail
configuration on AWS. The audit resolves whether that is configured; if it is
not, tier 3 and 4 need an alternative path and that becomes a finding.

## Teardown discipline

Every session ends with teardown. No exceptions, including sessions that fail
early.

1. `make aws-down` — deletes `hello-nginx` and the `gateway-alb` Ingress, waits
   60 s for the controller to deprovision, then `terraform destroy`, then lists
   any Secrets Manager entries in soft-delete
2. `make aws-leak-check` — ALB/NLBs, available NAT gateways, allocated EIPs,
   unattached EBS volumes, EKS clusters. Empty tables mean clean
3. Next day, confirm in Cost Explorer that spend returned to approximately zero

The 60 s wait in `down.sh` is a fixed sleep rather than a poll; if the ALB takes
longer, `terraform destroy` can hang on orphaned ENIs. Noted, not fixed —
recognising the symptom is enough for this run.

Expected survivors: the `aws/bootstrap` stack only — state bucket, lock table,
11 ECR repos, budget alarm. No resource in `aws/main` sets `prevent_destroy`,
and both RDS instances set `skip_final_snapshot = true` and
`deletion_protection = false`.

## Safety rails

- **No billed command is run by the assistant.** Every command that costs money
  or mutates the AWS account is handed to the operator with what it does and
  what it should print. This includes `terraform apply`, every `make aws-*`
  target, and `up-all.sh`.
- The assistant reads, diagnoses, and writes code. The operator drives spend.
- `deploy/.env` and every `*.tfvars` are never opened or printed.
- No credential value is ever printed.
- Handoffs use the coworking format: what was done, then what the operator needs
  to run, before any context or rationale.

## Out of scope

- Consolidating AWS infra into the umbrella chart (see D4 and memory `0005`)
- Bumping Kubernetes or controller versions (see D1)
- Fixing `down.sh`'s fixed-sleep ALB wait
- Any change to the local `ENV=compose` or `ENV=k8s` paths
