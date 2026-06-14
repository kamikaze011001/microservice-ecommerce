# AWS Phase 0 — Bootstrap Stack (Coworking Learning Plan)

> **Coworking learning mode.** This plan is for a human (strong Java/Spring, AWS
> beginner) who wants to *learn Terraform + AWS for interviews* by writing the
> meaningful resource blocks themselves. Tasks marked **[CHECKPOINT — HUMAN]**
> are yours to write — the plan gives you the skeleton, requirements, and doc
> links, **not** the answer. Claude scaffolds the surrounding wiring and reviews
> what you write. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the one-time, persistent Terraform "bootstrap" stack — remote
state backend (S3 + DynamoDB lock) and a cost guardrail (AWS Budget alarm) — so
that every later phase has somewhere safe to keep state and a tripwire against
runaway spend.

**Architecture:** A standalone Terraform root module at `aws/bootstrap/` that uses
a **local** backend (it can't store state in the bucket it is itself creating —
classic chicken-and-egg). It creates: an S3 bucket (versioned, encrypted, public
access blocked) for *future* stacks' state, a DynamoDB table for state locking,
and an AWS Budgets monthly cost alarm. These resources persist between sessions
(cost ≪ $1/mo) — everything else in later phases is ephemeral.

**Tech Stack:** Terraform ≥1.7, AWS provider ≥5.x, region `ap-southeast-1`, AWS
CLI v2. Makefile target `aws-bootstrap` wrapping `scripts/aws/bootstrap.sh`.

**Spec:** `docs/superpowers/specs/2026-06-10-aws-deployment-design.md` §4, §7,
§8 (Phase 0 row).

---

## File Structure

```
aws/
├── .gitignore                      # belt-and-suspenders: *.tfvars, .terraform/, *.tfstate*
├── bootstrap/
│   ├── versions.tf                 # terraform{} required_version + provider constraints  [CLAUDE]
│   ├── providers.tf                # aws provider (region, default_tags)                   [CLAUDE]
│   ├── variables.tf                # region, project, budget_limit_usd, budget_email       [CLAUDE]
│   ├── state.tf                    # S3 state bucket + DynamoDB lock table          [HUMAN ✍️]
│   ├── budget.tf                   # aws_budgets_budget monthly cost alarm          [HUMAN ✍️]
│   ├── outputs.tf                  # state_bucket, lock_table (consumed by aws/main later)  [CLAUDE]
│   └── terraform.tfvars.example    # sample values; real terraform.tfvars is gitignored    [CLAUDE]
└── scripts/
    └── bootstrap.sh                # terraform -chdir=aws/bootstrap init && apply           [CLAUDE]
```

Root `.gitignore` and `Makefile` get one entry each.

---

## Task 0: Prerequisites — your AWS account + local tooling  [CHECKPOINT — HUMAN]

**This is yours.** Claude cannot create your AWS account, enable MFA, or install
binaries on your machine. Do these first; the rest of the plan assumes they're done.

- [ ] **Step 1: Install Terraform + AWS CLI v2**

```bash
brew install terraform awscli      # macOS / Apple Silicon
terraform version                  # expect: Terraform v1.7+  (arm64)
aws --version                      # expect: aws-cli/2.x
```

- [ ] **Step 2: Create an IAM admin user with MFA (AWS Console, root login once)**

  - Root account → IAM → Users → create `microecom-admin`.
  - Attach `AdministratorAccess` (acceptable for a learning sandbox; the
    interview talking point is "I'd scope this down with permission boundaries
    in a real org").
  - Enable a virtual MFA device on this user.
  - Create an **access key** for CLI use (Application running outside AWS).
  - Stop using the root user after this.

- [ ] **Step 3: Configure a named CLI profile**

```bash
aws configure --profile microecom
# Access key / secret from Step 2
# Default region: ap-southeast-1
# Default output: json
```

- [ ] **Step 4: Verify identity**

```bash
aws sts get-caller-identity --profile microecom
```
Expected: JSON showing your `Account`, `UserId`, and an ARN ending in
`:user/microecom-admin`. **If this fails, stop — nothing downstream will work.**

- [ ] **Step 5: Tell Claude** your account ID is confirmed and the profile name
  (`microecom`) so later scaffolding uses the right `--profile` / `AWS_PROFILE`.

> 🎓 **Interview note to bank:** why an IAM user + MFA instead of root keys, and
> why a named profile instead of `default`. Write your one-line answer in the
> Phase 5 interview-notes doc when we get there.

---

## Task 1: Project skeleton + gitignore  [CLAUDE scaffolds]

**Files:**
- Create: `aws/.gitignore`
- Modify: root `.gitignore` (add `aws/**/*.tfvars`, `aws/**/.terraform/`, `aws/**/*.tfstate*`)
- Create: `aws/bootstrap/` (empty dir to be filled by later tasks)

- [ ] **Step 1: Claude creates `aws/.gitignore`**

```gitignore
# Never commit state, lock metadata, provider plugins, or real secrets
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
crash.log
```

- [ ] **Step 2: Claude appends to root `.gitignore`**

```gitignore
# Terraform (AWS deploy) — state and secrets stay local
aws/**/.terraform/
aws/**/*.tfstate
aws/**/*.tfstate.*
aws/**/*.tfvars
!aws/**/*.tfvars.example
```

- [ ] **Step 3: Verify ignore rules**

Run: `git check-ignore aws/bootstrap/terraform.tfvars aws/bootstrap/.terraform/`
Expected: both paths echoed back (meaning they're ignored).

- [ ] **Step 4: Commit**

```bash
git add aws/.gitignore .gitignore
git commit -m "chore(aws): gitignore terraform state, tfvars, plugins"
```

---

## Task 2: Provider, versions, and variables  [CLAUDE scaffolds]

These are boilerplate with no meaningful design choices — Claude writes them so
you spend your energy on the resources in Tasks 3–4.

**Files:**
- Create: `aws/bootstrap/versions.tf`
- Create: `aws/bootstrap/providers.tf`
- Create: `aws/bootstrap/variables.tf`
- Create: `aws/bootstrap/terraform.tfvars.example`

- [ ] **Step 1: Claude creates `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Bootstrap uses a LOCAL backend on purpose: it creates the very bucket that
  # later stacks (aws/main) will use as their remote backend. You cannot store
  # state in a bucket that does not exist yet.
  backend "local" {}
}
```

- [ ] **Step 2: Claude creates `providers.tf`**

```hcl
provider "aws" {
  region = var.region

  # Tag everything this stack makes so aws-leak-check and the bill are legible.
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
```

- [ ] **Step 3: Claude creates `variables.tf`**

```hcl
variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used as a tag and a resource name prefix"
  type        = string
  default     = "microecom"
}

variable "budget_limit_usd" {
  description = "Monthly cost ceiling that trips the budget alarm"
  type        = number
  default     = 25
}

variable "budget_email" {
  description = "Email address that receives budget alerts"
  type        = string
  # no default — must be supplied via terraform.tfvars (it's personal)
}
```

- [ ] **Step 4: Claude creates `terraform.tfvars.example`**

```hcl
# Copy to terraform.tfvars (gitignored) and fill in. Defaults cover the rest.
budget_email = "you@example.com"
# region           = "ap-southeast-1"
# project          = "microecom"
# budget_limit_usd = 25
```

- [ ] **Step 5: Commit**

```bash
git add aws/bootstrap/versions.tf aws/bootstrap/providers.tf \
        aws/bootstrap/variables.tf aws/bootstrap/terraform.tfvars.example
git commit -m "feat(aws): bootstrap provider, versions, and variables"
```

---

## Task 3: Remote-state backend resources  [CHECKPOINT — HUMAN ✍️]

**This is the heart of the lesson — you write it.** Terraform remote state is
*the* thing interviewers probe ("where does your state live? how do you stop two
applies racing?"). Writing the bucket + lock table yourself is how that answer
becomes muscle memory.

**File:** Create `aws/bootstrap/state.tf` (Claude leaves you this skeleton).

```hcl
# aws/bootstrap/state.tf
#
# Goal: the durable home for EVERY later stack's terraform.tfstate, plus the
# lock that prevents two `terraform apply`s from corrupting it.
#
# ── REQUIREMENT A: S3 bucket for state ───────────────────────────────────────
# Create an S3 bucket named like "${var.project}-tfstate-<account_id>".
#   - Bucket names are GLOBALLY unique → suffix with the account id so it never
#     collides. Get the account id from a data source (hint below).
#   - Turn ON versioning (so a bad apply can be rolled back).
#   - Turn ON server-side encryption (SSE-S3 / AES256 is fine for a sandbox).
#   - BLOCK all public access (state files contain secrets — never public).
#
# In AWS provider v5 these are SEPARATE resources, not bucket sub-blocks:
#   aws_s3_bucket, aws_s3_bucket_versioning,
#   aws_s3_bucket_server_side_encryption_configuration,
#   aws_s3_bucket_public_access_block
#
# ── REQUIREMENT B: DynamoDB lock table ───────────────────────────────────────
# Create an aws_dynamodb_table for state locking.
#   - billing_mode = "PAY_PER_REQUEST" (no idle cost when we're torn down).
#   - hash_key MUST be exactly "LockID" (string) — Terraform's S3 backend
#     hard-codes that attribute name.
#
# ── HINT: account id data source ─────────────────────────────────────────────
# data "aws_caller_identity" "current" {}
# ...then reference data.aws_caller_identity.current.account_id
#
# Docs:
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table
#
# Write your resources below. Ask Claude to review before you apply.
```

- [ ] **Step 1: [HUMAN] Write `state.tf`** to satisfy Requirements A + B above.
- [ ] **Step 2: [HUMAN] Ask Claude to review** your `state.tf` before applying.
- [ ] **Step 3: Validate syntax** (no AWS calls yet):

```bash
terraform -chdir=aws/bootstrap init -backend=false
terraform -chdir=aws/bootstrap validate
terraform -chdir=aws/bootstrap fmt
```
Expected: `Success! The configuration is valid.`

> 🎓 **Interview notes to bank:** (1) why state lives in S3 + why versioning, (2)
> what the DynamoDB table actually prevents and what "LockID" is, (3) the
> chicken-and-egg reason bootstrap itself uses a local backend.

---

## Task 4: Budget cost-guardrail  [CHECKPOINT — HUMAN ✍️]

**You write this too** — it's short, and "how do you stop a sandbox from
surprising you with a $300 bill?" is a real interview question. The spec makes
this guardrail #1 of its cost defense-in-depth (§7).

**File:** Create `aws/bootstrap/budget.tf` (skeleton below).

```hcl
# aws/bootstrap/budget.tf
#
# Goal: an AWS Budgets monthly COST budget that emails you when ACTUAL spend
# crosses a threshold of var.budget_limit_usd.
#
# Use resource: aws_budgets_budget
#   - budget_type  = "COST"
#   - time_unit    = "MONTHLY"
#   - limit_amount = var.budget_limit_usd   (note: this attribute is a STRING)
#   - limit_unit   = "USD"
#   - Add a notification block: comparison_operator GREATER_THAN, threshold 80
#     (percent), threshold_type PERCENTAGE, notification_type ACTUAL, and
#     subscriber_email_addresses = [var.budget_email].
#   - Optional bonus: a second notification at threshold 100 with
#     notification_type FORECASTED (warns before you even spend it).
#
# Docs:
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget
#
# Write your resource below; ask Claude to review before applying.
```

- [ ] **Step 1: [HUMAN] Write `budget.tf`.**
- [ ] **Step 2: [HUMAN] Ask Claude to review.**
- [ ] **Step 3: Validate:** `terraform -chdir=aws/bootstrap validate` → valid.

---

## Task 5: Outputs  [CLAUDE scaffolds]

Later stacks (`aws/main`) read these to wire their own remote backend, so they
must exist before we apply.

**File:** Create `aws/bootstrap/outputs.tf`.

- [ ] **Step 1: Claude creates `outputs.tf`** (references the resource names you
  chose in Task 3 — Claude will read your `state.tf` first and match them).

```hcl
output "state_bucket" {
  description = "S3 bucket holding remote state for all other stacks"
  value       = aws_s3_bucket.<your_bucket_resource_name>.id
}

output "lock_table" {
  description = "DynamoDB table used for state locking"
  value       = aws_dynamodb_table.<your_lock_resource_name>.name
}

output "region" {
  value = var.region
}
```

- [ ] **Step 2: Commit Tasks 3–5 together**

```bash
git add aws/bootstrap/state.tf aws/bootstrap/budget.tf aws/bootstrap/outputs.tf
git commit -m "feat(aws): bootstrap remote-state backend + budget alarm"
```

---

## Task 6: Makefile target + wrapper script  [CLAUDE scaffolds]

Mirrors the repo convention: Makefile is a thin wrapper over `scripts/*`.

**Files:**
- Create: `scripts/aws/bootstrap.sh`
- Modify: `Makefile` (add `aws-bootstrap` target + a help line)

- [ ] **Step 1: Claude creates `scripts/aws/bootstrap.sh`**

```bash
#!/usr/bin/env bash
# One-time: create the persistent Terraform state backend + budget alarm.
# Idempotent — safe to re-run; terraform reconciles to desired state.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../aws/bootstrap" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"

if [[ ! -f "$DIR/terraform.tfvars" ]]; then
  echo "ERROR: $DIR/terraform.tfvars missing." >&2
  echo "  cp aws/bootstrap/terraform.tfvars.example aws/bootstrap/terraform.tfvars" >&2
  echo "  then set budget_email." >&2
  exit 1
fi

terraform -chdir="$DIR" init -backend=false
terraform -chdir="$DIR" apply
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/aws/bootstrap.sh
```

- [ ] **Step 3: Claude adds the Makefile target**

```makefile
.PHONY: aws-bootstrap
aws-bootstrap:
	@scripts/aws/bootstrap.sh
```
(plus a help line under a new "AWS (ephemeral EKS):" heading)

- [ ] **Step 4: Commit**

```bash
git add scripts/aws/bootstrap.sh Makefile
git commit -m "feat(aws): make aws-bootstrap wrapper for the bootstrap stack"
```

---

## Task 7: Apply for real + verify  [CHECKPOINT — HUMAN ✍️ runs it]

**You run the apply** (it touches *your* AWS account and bills you). Claude walks
you through reading the plan output.

- [ ] **Step 1: Create your real tfvars**

```bash
cp aws/bootstrap/terraform.tfvars.example aws/bootstrap/terraform.tfvars
# edit: set budget_email to your address
```

- [ ] **Step 2: Read the plan** (always read before apply)

```bash
make aws-bootstrap        # runs init + apply; will show the plan and prompt yes/no
```
Expected plan: ~5–6 resources to **add** (bucket, versioning, encryption,
public-access-block, dynamodb table, budget), 0 to change, 0 to destroy. Read
each line. Type `yes` only when it matches that.

- [ ] **Step 3: Confirm in AWS the resources exist**

```bash
aws s3 ls --profile microecom | grep tfstate
aws dynamodb list-tables --profile microecom
aws budgets describe-budgets --account-id <your-account-id> --profile microecom
```
Expected: your state bucket listed, the lock table present, the budget returned.

- [ ] **Step 4: Confirm the budget email** — AWS sends a one-time SNS-style
  confirmation for budget notifications; check your inbox if prompted.

- [ ] **Step 5: Note the outputs** — `terraform -chdir=aws/bootstrap output`
  prints `state_bucket` and `lock_table`. **Phase 1 will reference these** as its
  backend config. Paste them back to Claude so the Phase 1 plan hard-codes the
  right names.

> 🎓 **Phase 0 done = interview story:** "My state backend and a budget tripwire
> are themselves IaC, applied once and versioned. Everything else is ephemeral."

---

## Self-Review (Claude ran this against the spec)

- **§4 bootstrap stack** (state bucket + lock + budget) → Tasks 3, 4, 5. ✅
- **§7 cost guardrail #1** (Budget $25/mo email) → Task 4. ✅
- **§8 Phase 0 deliverable** (IAM admin+MFA, CLI profiles, bootstrap stack, budget) → Task 0 (human AWS account) + Tasks 1–7. ✅
- **§4 "persists between sessions"** (state bucket, budget ≪ $1/mo) → local-backend note in Task 2, durable resources in Task 3. ✅
- **Repo convention** (Makefile wraps scripts/*) → Task 6. ✅
- **Deferred to Phase 1 (correctly out of scope here):** VPC, EKS, ECR, the
  `aws/main` root module and its *remote* backend block — Phase 1 consumes Task
  5's outputs.

---

## Next phase

Phase 1 (VPC + EKS + ALB controller, "hello-nginx reachable from the internet")
gets its own plan once Phase 0 is applied and you've banked the Task-3/4
interview notes. We plan one phase at a time — that's the learning loop.
