# Phase 5b — `shop.microecom.click` over HTTPS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the storefront at `https://shop.microecom.click` over real TLS — a Route 53 record + DNS-validated ACM cert + an HTTPS ALB listener layered on top of the Phase 5a same-origin SPA, with no app code changes.

**Architecture:** Terraform looks up the (console-registered) `microecom.click` hosted zone, requests an ACM cert for `shop.microecom.click`, and DNS-validates it. external-dns (IRSA + helm) watches the Ingress and writes the `shop.microecom.click` A-alias to the dynamic ALB hostname. The ingress gains a `host:` rule + `listen-ports`/`ssl-redirect` annotations; the AWS Load Balancer Controller auto-discovers the cert by host match — no `certificate-arn` plumbing crosses the Terraform↔kustomize boundary.

**Tech Stack:** Terraform (`aws_route53_zone` data source, `aws_acm_certificate` + DNS validation, `terraform-aws-modules/iam` IRSA, `helm_release`), Kubernetes Ingress (AWS Load Balancer Controller annotations), bash.

---

## Coworking-learning split

This is a **coworking-learning** phase. The **user writes the Terraform HCL bodies**
(`[CHECKPOINT — HUMAN ✍️]`); Claude writes the heavily-commented skeletons, the
Claude-owned glue (helm_release, ingress YAML, banner, output), and reviews.

| Task | File | Owner |
|------|------|-------|
| 1 | `aws/main/dns.tf` (zone + ACM) | Claude scaffolds → **HUMAN ✍️** bodies → Claude reviews |
| 2 | `aws/main/external-dns.tf` (IRSA 2a + helm 2b) | Claude scaffolds → **HUMAN ✍️** 2a → Claude appends 2b |
| 3 | `aws/main/s3.tf` Part C (CORS origin) | **HUMAN ✍️** one-line edit → Claude reviews |
| 4 | `k8s/apps/overlays/aws/ingress-gateway.yaml` | **Claude** |
| 5 | `aws/main/outputs.tf` + `scripts/aws/up-all.sh` | **Claude** |
| 6 | Final offline verification gate | **Claude** |

## One-time manual prerequisite (NOT Terraform, NOT `make aws-*`)

Before any of this can `apply`, the user registers `microecom.click` in the **Route 53
console** (Route 53 → Registered domains → Register domain). That auto-creates the
hosted zone Task 1 looks up. Done once; survives every `make aws-down`. **This plan does
not automate it** — it's the human's one-time action, like an interactive login.

## A note on "tests" for declarative infra

This stack has **no unit-test framework for Terraform/YAML**, and the offline constraint
forbids `terraform init/validate/plan`, `aws`, `kubectl <cluster>`, `helm`, and `make
aws-*` (they bill account `583178372344` / profile `microecom` / `ap-southeast-1`). The
honest verification for declarative infra is **render + lint gates**, which replace the
TDD "failing test" ritual throughout this plan:
- `terraform fmt` (formatting only — no `init`/`validate`/`plan`)
- `kubectl kustomize k8s/apps/overlays/aws` (local render, no cluster contact)
- `bash -n <script>`
- `grep` cross-checks

The billed `make aws-all` + browser walk is the **user's** step (see the spec's
"Billed (USER)" section).

## Branch

Stay on `feat/aws-deploy` (continuation of the AWS workstream — do **not** branch off
main). Confirm with `git branch --show-current` before the first edit.

---

### Task 1: `aws/main/dns.tf` — Route 53 zone lookup + ACM certificate

**Files:**
- Create: `aws/main/dns.tf`

This task produces a heavily-commented **scaffold** (Claude), then the **HUMAN** writes
the four resource bodies, then Claude reviews. Two commits: scaffold, then bodies.

- [ ] **Step 1 (Claude): Write the scaffold file**

Create `aws/main/dns.tf` with exactly this content (comments only — no resource blocks
yet; the human writes those in Step 3):

```hcl
# aws/main/dns.tf  —  Phase 5b — Route 53 zone lookup + ACM certificate
#
# WHY THIS FILE EXISTS
# Phase 5a serves the storefront on the raw ALB over HTTP. This file gives it a real
# domain + TLS: it looks up the (console-registered) microecom.click hosted zone,
# requests an ACM certificate for shop.microecom.click, and DNS-validates it by writing
# the validation records into that zone. The cert is then auto-discovered by the AWS
# Load Balancer Controller (no certificate-arn annotation) because the ingress carries a
# matching `host: shop.microecom.click` rule (see k8s/apps/overlays/aws/ingress-gateway.yaml).
#
# PREREQ — one-time, MANUAL, NOT Terraform:
#   Register microecom.click in the Route 53 console (Route 53 → Registered domains →
#   Register domain). That auto-creates the hosted zone this file looks up and auto-points
#   the domain's NS at it. Done once; survives every `make aws-down`. We deliberately keep
#   registration OUT of Terraform: it's async, paid yearly, and can't be cleanly destroyed
#   — it doesn't belong in a nightly-torn-down stack.
#
# ─────────────────────────────────────────────────────────────────────────────
# [CHECKPOINT — HUMAN ✍️]  Write PARTS A–D below, then tell Claude "review".
#
# PART A — look up the hosted zone. A DATA source, not a resource: Terraform READS the
#   console-created zone but never owns or destroys it, so the NS delegation stays stable
#   across teardowns.
#
#     data "aws_route53_zone" "primary" {
#       name = "microecom.click"
#     }
#
# PART B — request the certificate. DNS validation (not email): ACM hands us a CNAME to
#   publish; once it sees the CNAME, the cert flips to ISSUED.
#
#     resource "aws_acm_certificate" "shop" {
#       domain_name       = "shop.microecom.click"
#       validation_method = "DNS"
#       lifecycle {
#         create_before_destroy = true   # never leave the ALB without a cert mid-replace
#       }
#     }
#
# PART C — publish the validation record(s). THE ONE TRICKY BIT:
#   `domain_validation_options` is a SET, so iterate it with for_each (NOT count), keyed
#   by domain_name. allow_overwrite = true because a re-apply can re-emit the same record
#   name and would otherwise collide.
#
#     resource "aws_route53_record" "shop_cert_validation" {
#       for_each = {
#         for dvo in aws_acm_certificate.shop.domain_validation_options :
#         dvo.domain_name => {
#           name   = dvo.resource_record_name
#           type   = dvo.resource_record_type
#           record = dvo.resource_record_value
#         }
#       }
#       zone_id         = data.aws_route53_zone.primary.zone_id
#       name            = each.value.name
#       type            = each.value.type
#       records         = [each.value.record]
#       ttl             = 60
#       allow_overwrite = true
#     }
#
# PART D — the validation gate. This resource has no cloud side-effect of its own; it
#   blocks dependents until ACM confirms the records → cert ISSUED.
#
#     resource "aws_acm_certificate_validation" "shop" {
#       certificate_arn         = aws_acm_certificate.shop.arn
#       validation_record_fqdns = [for r in aws_route53_record.shop_cert_validation : r.fqdn]
#     }
#
# ─────────────────────────────────────────────────────────────────────────────
# 🎓 Interview prep — be ready to explain:
#   - Why the zone is a `data` source (stable NS delegation across destroy/apply) and why
#     registration is kept out of TF (irreversible / externally billed / async).
#   - DNS vs email validation; why for_each over a SET needs a map projection and
#     allow_overwrite; what aws_acm_certificate_validation actually *does* (a synchronization
#     gate, not a real AWS object).
#   - How the cert reaches the ALB with NO certificate-arn: host-based discovery.
#
# Write PARTS A–D below, then tell Claude "review".
```

- [ ] **Step 2 (Claude): Format + commit the scaffold**

```bash
terraform fmt aws/main/dns.tf
git add aws/main/dns.tf
git commit -m "docs(aws): scaffold dns.tf — Route 53 zone + ACM cert checkpoint (Phase 5b)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
Expected: `terraform fmt` prints the filename (or nothing if already formatted) and exits 0. **Do not run `terraform init/validate/plan`.**

- [ ] **Step 3 [CHECKPOINT — HUMAN ✍️]: Write the four resource bodies**

The user appends PARTS A–D (the four blocks shown in the Step-1 comments) below the
scaffold. The expected end state: a `data "aws_route53_zone" "primary"`, an
`aws_acm_certificate "shop"`, an `aws_route53_record "shop_cert_validation"` (for_each
map projection + `allow_overwrite = true`), and an `aws_acm_certificate_validation "shop"`.
**Claude does not write these.** Pause here until the user says "review".

- [ ] **Step 4 (Claude): Review + format + commit the bodies**

Review the human's HCL against the spec. Verify (by reading the file + grep):
```bash
terraform fmt aws/main/dns.tf
grep -E 'data "aws_route53_zone" "primary"|aws_acm_certificate" "shop"|for_each|allow_overwrite|aws_acm_certificate_validation' aws/main/dns.tf
```
Expected: the zone data source, the cert resource, the `for_each`/`allow_overwrite`
validation record, and the validation gate all present; `name = "microecom.click"` and
`domain_name = "shop.microecom.click"`. Report any deviation, then:
```bash
git add aws/main/dns.tf
git commit -m "feat(aws): Route 53 zone + DNS-validated ACM cert for shop.microecom.click

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `aws/main/external-dns.tf` — IRSA (2a HUMAN) + helm (2b Claude)

**Files:**
- Create: `aws/main/external-dns.tf`

**Depends on Task 1** — the 2a IRSA references `data.aws_route53_zone.primary.arn` from
`dns.tf`. Structural twin of `aws/main/alb-controller.tf` (4a IRSA → 4b helm).

- [ ] **Step 1 (Claude): Write the scaffold with the 2a checkpoint**

Create `aws/main/external-dns.tf` with exactly this content (2a is a comment block the
human fills; 2b is appended in Step 4):

```hcl
# aws/main/external-dns.tf  —  Phase 5b — external-dns (IRSA + helm)
#
# WHY THIS FILE EXISTS
# The ALB hostname is invented by the AWS Load Balancer Controller at apply time, so
# Terraform can't write a static alias record for it. external-dns solves exactly that:
# it watches the live Ingress and creates the shop.microecom.click A-alias in Route 53
# *after* the ALB exists. This file is the structural twin of alb-controller.tf — open it
# side by side; the IRSA → helm shape is identical.
#
#   2a [HUMAN ✍️]  the IRSA role  (write it below)
#   2b [CLAUDE]    the helm_release that installs external-dns (appended after 2a review)
#
# ─────────────────────────────────────────────────────────────────────────────
# 2a — [CHECKPOINT — HUMAN ✍️]  Write the IRSA role module below.
#
# Same module/version as alb_irsa, but external-dns has its OWN magic flag. The one
# difference from the ALB controller: scope the role to OUR zone (least privilege) instead
# of the module default of every zone ("*").
#
#   module "external_dns_irsa" {
#     source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#     version = "~> 5.0"
#
#     role_name                     = "${var.project}-external-dns"
#     attach_external_dns_policy    = true                                  # the magic flag
#     external_dns_hosted_zone_arns = [data.aws_route53_zone.primary.arn]   # least privilege: our zone only
#
#     oidc_providers = {
#       main = {
#         provider_arn               = module.eks.oidc_provider_arn
#         namespace_service_accounts = ["kube-system:external-dns"]
#       }
#     }
#   }
#
# English: "the k8s ServiceAccount `external-dns` in kube-system may assume an IAM role
# that can change record sets ONLY in the microecom.click hosted zone." That zone-scoped
# trust is IRSA + least privilege in one block.
#
# Docs: https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest/submodules/iam-role-for-service-accounts-eks
#
# Write your module "external_dns_irsa" block below, then tell Claude "review".
# (Claude appends the helm_release — 2b — after the review.)
```

- [ ] **Step 2 (Claude): Format + commit the scaffold**

```bash
terraform fmt aws/main/external-dns.tf
git add aws/main/external-dns.tf
git commit -m "docs(aws): scaffold external-dns.tf — IRSA checkpoint (Phase 5b)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
Expected: `terraform fmt` exits 0. **No `init/validate/plan`.**

- [ ] **Step 3 [CHECKPOINT — HUMAN ✍️]: Write the IRSA module**

The user writes `module "external_dns_irsa"` below the 2a comment (the block shown in the
Step-1 comment). Key fields: `attach_external_dns_policy = true`,
`external_dns_hosted_zone_arns = [data.aws_route53_zone.primary.arn]`, SA
`kube-system:external-dns`. **Claude does not write it.** Pause until the user says "review".

- [ ] **Step 4 (Claude): Review the IRSA, then append the 2b helm_release**

Review the human's module against the spec, then **append** this 2b block to
`aws/main/external-dns.tf`:

```hcl

# ─────────────────────────────────────────────────────────────────────────────
# 2b — [CLAUDE]  Install external-dns via its Helm chart.
# The serviceAccount.annotations line is the IRSA link (role ARN → SA → STS temp creds,
# no static keys). domainFilters scopes what external-dns will touch; policy=upsert-only
# means it NEVER deletes records (safe for a stack torn down nightly — the record is
# re-pointed at the new ALB on the next apply). txtOwnerId stamps a TXT registry record so
# this cluster only manages records it created. SA name/namespace MUST match the
# namespace_service_accounts in 2a.
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = "kube-system"
  version    = "1.15.0"

  set {
    name  = "provider.name" # chart ≥1.14 nests the provider under provider.name
    value = "aws"
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_dns_irsa.iam_role_arn
  }
  set {
    name  = "policy"
    value = "upsert-only"
  }
  set {
    name  = "txtOwnerId"
    value = module.eks.cluster_name
  }
  set {
    name  = "domainFilters[0]"
    value = "microecom.click"
  }

  depends_on = [module.eks]
}
```

Then format, verify, commit:
```bash
terraform fmt aws/main/external-dns.tf
grep -E 'attach_external_dns_policy|external_dns_hosted_zone_arns|helm_release "external_dns"|upsert-only|domainFilters' aws/main/external-dns.tf
git add aws/main/external-dns.tf
git commit -m "feat(aws): external-dns IRSA + helm_release for Route 53 records (Phase 5b)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
Expected: grep shows the magic flag, the zone-scoped ARN, the helm_release, `upsert-only`,
and `domainFilters`.

---

### Task 3: `aws/main/s3.tf` Part C — CORS allowed-origin

**Files:**
- Modify: `aws/main/s3.tf:79-87` (the `aws_s3_bucket_cors_configuration.media` resource)

A one-line **HUMAN ✍️** edit (the user owns s3.tf). Claude reviews.

- [ ] **Step 1 [CHECKPOINT — HUMAN ✍️]: Replace the wildcard origins with the domain**

In `aws/main/s3.tf`, the user changes the `allowed_origins` line inside
`resource "aws_s3_bucket_cors_configuration" "media"`:

From:
```hcl
    allowed_origins = ["http://microecom.local", "https://microecom.local", "http://*.elb.amazonaws.com", "https://*.elb.amazonaws.com"]
```
To:
```hcl
    allowed_origins = ["http://microecom.local", "https://microecom.local", "https://shop.microecom.click"]
```
Rationale (for the learner): the browser's direct PUT to the S3 presigned upload URL is
cross-origin, so S3 must allow the shop's origin. The `*.elb` wildcards were the no-domain
stopgap; with a stable domain they're superseded. Keep `microecom.local` for local k8s.
Optionally refresh the Part-C comment block above (lines 70-78) to list the new origin.

- [ ] **Step 2 (Claude): Review + format + commit**

```bash
terraform fmt aws/main/s3.tf
grep -n 'allowed_origins' aws/main/s3.tf
git diff --stat aws/main/s3.tf
```
Expected: `allowed_origins` contains `https://shop.microecom.click` and NO `*.elb`
substring remains.
```bash
git add aws/main/s3.tf
git commit -m "feat(aws): S3 CORS allows the shop.microecom.click origin (Phase 5b)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `k8s/apps/overlays/aws/ingress-gateway.yaml` — HTTPS listener + host rule

**Files:**
- Modify: `k8s/apps/overlays/aws/ingress-gateway.yaml`

**Claude-owned.** Three edits: add two annotations, add the `host:` to the rule, and
refresh the now-stale "No host" comment.

- [ ] **Step 1 (Claude): Add the HTTPS annotations**

Insert the `listen-ports` + `ssl-redirect` annotations after the `target-type: ip` line.
Replace:
```yaml
    alb.ingress.kubernetes.io/target-type: ip
    # NOTE: health checks are NOT set here. With two backends (gateway + frontend)
```
with:
```yaml
    alb.ingress.kubernetes.io/target-type: ip
    # HTTPS: terminate TLS on the ALB. listen-ports opens BOTH :80 and :443; ssl-redirect
    # 301-bounces every :80 request to :443. There is NO certificate-arn — the controller
    # auto-discovers the ACM cert whose domain matches the `host:` rule below
    # (shop.microecom.click). That cert is created in aws/main/dns.tf.
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    # NOTE: health checks are NOT set here. With two backends (gateway + frontend)
```

- [ ] **Step 2 (Claude): Add the host rule + refresh the comment**

Replace the host comment + the bare `- http:` rule opener. From:
```yaml
spec:
  ingressClassName: alb
  # No host: match every Host header. On EKS we hit the raw *.elb.amazonaws.com
  # DNS, so a host rule would 404. Phase 5b adds shop.microecom.click once
  # Route 53 + ACM are in place.
  #
  # Listener-rule precedence is by path specificity: the AWS Load Balancer
```
to:
```yaml
spec:
  ingressClassName: alb
  # host: shop.microecom.click on every rule (Phase 5b). This single value feeds TWO
  # things: (1) the AWS LB Controller auto-discovers the ACM cert matching this host for
  # the :443 listener, and (2) external-dns reads it to create the Route 53 A-alias. The
  # trade-off vs 5a: the raw *.elb.amazonaws.com hostname now 404s (every rule requires
  # this Host header) — browse via https://shop.microecom.click instead.
  #
  # Listener-rule precedence is by path specificity: the AWS Load Balancer
```
And add the `host:` to the single rule. From:
```yaml
  rules:
    - http:
        paths:
          - path: /authorization-server
```
to:
```yaml
  rules:
    - host: shop.microecom.click
      http:
        paths:
          - path: /authorization-server
```

- [ ] **Step 3 (Claude): Render the overlay offline + verify**

```bash
kubectl kustomize k8s/apps/overlays/aws > /tmp/5b-render.yaml
grep -E 'listen-ports|ssl-redirect|host: shop.microecom.click' /tmp/5b-render.yaml
```
Expected: the rendered `gateway-alb` Ingress shows `alb.ingress.kubernetes.io/listen-ports`,
`alb.ingress.kubernetes.io/ssl-redirect: '443'`, and exactly one `host: shop.microecom.click`.
Confirm the render exits 0 (no kustomize error). **This is a local render — no cluster contact.**

- [ ] **Step 4 (Claude): Commit**

```bash
git add k8s/apps/overlays/aws/ingress-gateway.yaml
git commit -m "feat(aws): ingress HTTPS listener + ssl-redirect + shop.microecom.click host (Phase 5b)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `aws/main/outputs.tf` + `scripts/aws/up-all.sh` — surface the URL

**Files:**
- Modify: `aws/main/outputs.tf` (append output)
- Modify: `scripts/aws/up-all.sh:166-171` (banner)

**Claude-owned.**

- [ ] **Step 1 (Claude): Add the `shop_url` output**

Append to `aws/main/outputs.tf`:
```hcl

output "shop_url" {
  description = "Public HTTPS URL of the storefront (Phase 5b)"
  value       = "https://shop.microecom.click"
}
```

- [ ] **Step 2 (Claude): Update the up-all.sh DONE banner**

Replace the final banner block. From:
```bash
echo "  Gateway ALB : ${ALB:-<pending — re-check: kubectl -n apps get ingress gateway-alb>}"
echo "  Storefront  : http://${ALB:-<pending>}/   ← open in a browser and shop the funnel"
echo "  Verify      : login should return a JWT; catalog lists products; cart shows stock"
echo "  Remember    : 'make aws-down' when done — the cluster bills ~\$0.25-0.30/hr."
```
to:
```bash
echo "  Gateway ALB : ${ALB:-<pending — re-check: kubectl -n apps get ingress gateway-alb>}"
echo "  Storefront  : https://shop.microecom.click   ← open in a browser (valid TLS)"
echo "  First apply : DNS propagation + ACM issuance can take a few minutes before it resolves."
echo "  Raw ALB     : http://${ALB:-<pending>}/   (debug only — the host rule means this now 404s)"
echo "  Verify      : padlock is valid; http:// 301-redirects to https://; the funnel completes"
echo "  Remember    : 'make aws-down' when done — the cluster bills ~\$0.25-0.30/hr."
```

- [ ] **Step 3 (Claude): Lint + verify**

```bash
bash -n scripts/aws/up-all.sh
grep -n 'shop.microecom.click' scripts/aws/up-all.sh aws/main/outputs.tf
terraform fmt aws/main/outputs.tf
```
Expected: `bash -n` exits 0; grep shows the domain in both the banner and the output.

- [ ] **Step 4 (Claude): Commit**

```bash
git add aws/main/outputs.tf scripts/aws/up-all.sh
git commit -m "feat(aws): surface https://shop.microecom.click (output + up-all banner) (Phase 5b)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Final offline verification gate

**Files:** none (read-only checks)

**Claude-owned.** Run every offline gate together before handing the billed `make aws-all`
to the user. **No `terraform init/validate/plan`, no `aws`, no `kubectl <cluster>`, no `helm`.**

- [ ] **Step 1: Terraform formatting is clean**

```bash
terraform fmt -check aws/main/
```
Expected: exits 0 with no filenames printed (all files already formatted). If it prints a
file, run `terraform fmt aws/main/` and re-commit that file.

- [ ] **Step 2: The aws overlay renders with the HTTPS contract**

```bash
kubectl kustomize k8s/apps/overlays/aws | grep -E 'kind: Ingress|name: gateway-alb|listen-ports|ssl-redirect|host: shop.microecom.click'
```
Expected: the `gateway-alb` Ingress renders with `listen-ports`, `ssl-redirect: '443'`,
and `host: shop.microecom.click`. Render exits 0.

- [ ] **Step 3: Scripts lint clean**

```bash
bash -n scripts/aws/up-all.sh
```
Expected: exits 0.

- [ ] **Step 4: grep cross-checks across the whole phase**

```bash
grep -q 'attach_external_dns_policy' aws/main/external-dns.tf && echo "OK irsa flag"
grep -q 'external_dns_hosted_zone_arns' aws/main/external-dns.tf && echo "OK zone-scoped"
grep -q 'policy' aws/main/external-dns.tf && grep -q 'upsert-only' aws/main/external-dns.tf && echo "OK upsert-only"
grep -q 'domainFilters' aws/main/external-dns.tf && echo "OK domainFilter"
grep -q 'aws_acm_certificate_validation' aws/main/dns.tf && echo "OK acm gate"
grep -q 'shop.microecom.click' aws/main/s3.tf && echo "OK s3 cors"
! grep -q '\*\.elb\.amazonaws\.com' aws/main/s3.tf && echo "OK no elb wildcard"
grep -q 'shop.microecom.click' aws/main/outputs.tf && echo "OK output"
```
Expected: every line prints its `OK …`. Any missing line points at the file to fix.

- [ ] **Step 5: Report the handoff**

Lead with the coworking handoff header (per CLAUDE.md). Summarize what Claude built, what
the user must do (register the domain in the console, then `make aws-all`), and the
billed-verification walk from the spec. Do **not** run `make aws-all`. `finishing-a-development-branch`
is deliberately **not** run — `feat/aws-deploy` is long-running.

---

## Self-Review

**Spec coverage** (each spec component → task):
- Component 1 (dns.tf, Route 53 + ACM) → Task 1. ✓
- Component 2 (external-dns IRSA 2a + helm 2b) → Task 2. ✓
- Component 3 (s3.tf CORS) → Task 3. ✓
- Component 4 (ingress HTTPS + host) → Task 4. ✓
- Component 5 (output + banner) → Task 5. ✓
- Prereq (console registration) → documented as the manual prerequisite + Task 6 Step 5 handoff. ✓
- Offline gates (fmt / kustomize / bash -n / grep) → Task 6 + per-task verify steps. ✓
- "Not touched" (seed-secrets, gateway CORS, app code) → none of the tasks touch them. ✓

**Placeholder scan:** no TBD/TODO; every Claude step has complete file content or exact
commands; HUMAN checkpoints give the expected end-state, not a vague "write the terraform".

**Type/name consistency:** `data.aws_route53_zone.primary` (dns.tf) is referenced by
`external_dns_hosted_zone_arns` (Task 2) — same name. `module.external_dns_irsa.iam_role_arn`
(2b) matches `module "external_dns_irsa"` (2a). SA `kube-system:external-dns` matches between
the IRSA `namespace_service_accounts` and the helm `serviceAccount.name`/`namespace`.
`host: shop.microecom.click` matches the ACM `domain_name`, the external-dns record target,
and the S3 CORS origin scheme/host. The `shop_url` output value matches the ingress host.
