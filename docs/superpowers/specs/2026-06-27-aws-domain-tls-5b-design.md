# Phase 5b — `shop.microecom.click` over HTTPS (domain + DNS + ACM-TLS) — Design

**Status:** approved 2026-06-27
**Branch:** `feat/aws-deploy` (continuation of the AWS deployment workstream)
**Predecessor:** Phase 5a (storefront SPA same-origin on the raw ALB, HTTP)
**Successor:** none planned — this is the last piece of the "browsable AWS storefront" arc

## Goal

After `make aws-all`, an operator opens **`https://shop.microecom.click`** in a browser
and runs the full storefront funnel over real TLS, on a memorable domain — no raw
`*.elb.amazonaws.com` hostname, no HTTP. Phase 5a already made the funnel work
same-origin over HTTP; 5b layers a domain + a real certificate on top.

This is the **coworking-learning** phase: the **user writes the Terraform**
(`[CHECKPOINT — HUMAN ✍️]` blocks); Claude scaffolds the heavily-commented file
skeletons, writes the non-HCL glue (kustomize ingress, banner, output), and reviews.

## Why 5b is purely additive

Every browser-facing URL was made **relative** in Phase 5a (`frontend.base-url=""`,
mock `public-base-url=/mock-paypal-service`, payment success/cancel paths relative,
SPA built with empty `VITE_API_BASE_URL`). Relative URLs resolve against *whatever
origin the browser is on*, so moving from `http://<alb>` to `https://shop.microecom.click`
requires **no change** to payment-service, the SPA, or `seed-secrets.sh`. 5b only adds
DNS, a certificate, and the HTTPS listener.

## Decisions locked during brainstorming

### Domain / hosted zone — register once in console, Terraform reads the zone

`microecom.click` is registered **manually, one time, in the Route 53 console**
(auto-creates the hosted zone and auto-points the domain's NS at it). Terraform
consumes that zone via `data "aws_route53_zone"` and owns **only** records + the ACM
cert.

Rationale:
- The user runs `make aws-down` between sessions. If Terraform *owned* the hosted
  zone, every destroy/apply would mint a **new NS delegation set** → the registrar's
  nameservers would drift and the site would go dark until re-pointed. A `data` source
  leaves the zone + delegation untouched across teardowns.
- Domain **registration** is async, needs WHOIS contact info, costs real money yearly,
  and can't be cleanly `terraform destroy`-ed. Keeping registration out of the TF
  lifecycle is the correct boundary (irreversible / externally-billed / slow-to-converge
  resources don't belong in the same lifecycle as ephemeral infra).

### Certificate delivery — host-based auto-discovery, not explicit `certificate-arn`

The ingress rules carry `host: shop.microecom.click`. The AWS Load Balancer Controller
then **auto-discovers** the matching ACM certificate (no `certificate-arn` annotation),
and external-dns reads that **same** `host:` to create the Route 53 record. One YAML
change feeds both — **no `terraform output → sed-into-yaml` glue** crossing the TF↔k8s
boundary.

Cost accepted: the raw-ALB HTTP fallback from 5a stops serving (every rule now requires
`Host: shop.microecom.click`). That is fine — 5b's whole point is the domain.

**Fallback (not chosen, documented):** if auto-discovery ever proves flaky, switch to
explicit `certificate-arn` + host-less rules, with `up-all.sh` injecting
`terraform output -raw acm_cert_arn` into the ingress via a kustomize patch, and
external-dns driven by the `external-dns.alb.ingress.kubernetes.io/hostname` annotation.

### DNS records — external-dns controller, not a static `aws_route53_record` alias

The ALB hostname is invented by the AWS LB Controller at apply time, so Terraform does
not know it and cannot write a static alias record. external-dns watches the Ingress and
writes the `shop.microecom.click` A-alias *after* the ALB exists. This is the canonical
reason external-dns exists.

## Prerequisite — one-time manual human action (NOT Terraform, NOT `make aws-*`)

Register `microecom.click` in the **Route 53 console** (Route 53 → Registered domains →
Register domain). This auto-creates the `microecom.click` hosted zone. Done once;
survives every `make aws-down`. Until this exists, the `data "aws_route53_zone"` lookup
in Component 1 has nothing to find.

## Components

### 1. `aws/main/dns.tf` (new) — Route 53 zone lookup + ACM cert — **HUMAN ✍️**

Claude scaffolds the file with `[CHECKPOINT — HUMAN ✍️]` comments + the one tricky idiom
explained (the `for_each` over `domain_validation_options`). The user writes the bodies:

- `data "aws_route53_zone" "primary"` — `name = "microecom.click"` (a `.` suffix is
  conventional but optional). Looks up the console-registered zone.
- `aws_acm_certificate "shop"` — `domain_name = "shop.microecom.click"`,
  `validation_method = "DNS"`, `lifecycle { create_before_destroy = true }`.
- `aws_route53_record "shop_cert_validation"` — `for_each` over
  `aws_acm_certificate.shop.domain_validation_options` keyed by `domain_name`, writing
  the validation CNAME (name/type/records) into `data.aws_route53_zone.primary.zone_id`,
  `ttl = 60`, `allow_overwrite = true`.
- `aws_acm_certificate_validation "shop"` — `certificate_arn = aws_acm_certificate.shop.arn`,
  `validation_record_fqdns = [for r in aws_route53_record.shop_cert_validation : r.fqdn]`.
  This resource is the gate: dependents wait until the cert is ISSUED.

**The one tricky bit to explain in comments:** `domain_validation_options` is a *set*,
so you iterate it with `for_each` (not `count`) keyed by `dvo.domain_name`, and you must
`allow_overwrite = true` because a re-apply can re-emit the same validation record.

### 2. `aws/main/external-dns.tf` (new) — IRSA + helm — **2a HUMAN ✍️ / 2b CLAUDE**

Mirrors `aws/main/alb-controller.tf` (its 4a HUMAN IRSA → 4b CLAUDE helm_release) exactly.

**2a — HUMAN ✍️:** the IRSA role. Same module/version as `alb_irsa`, with the
external-dns "magic flag":
```hcl
module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                     = "${var.project}-external-dns"
  attach_external_dns_policy    = true                                  # the magic flag
  external_dns_hosted_zone_arns = [data.aws_route53_zone.primary.arn]   # scope to our zone

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}
```
English: "the k8s ServiceAccount `external-dns` in `kube-system` may assume an IAM role
that can change record sets **only** in the `microecom.click` hosted zone." Scoping
`external_dns_hosted_zone_arns` to our zone (vs the module default `["*"]`) is least
privilege — a good interview point.

**2b — CLAUDE:** `helm_release "external_dns"` — chart `external-dns` from
`https://kubernetes-sigs.github.io/external-dns/`, namespace `kube-system`, with:
- the IRSA SA annotation (`serviceAccount.annotations.eks\.amazonaws\.com/role-arn` =
  `module.external_dns_irsa.iam_role_arn`), SA name `external-dns`.
- `provider=aws`, `domainFilters={microecom.click}`, `policy=upsert-only` (never deletes
  records — safe for a demo that's torn down often), `txtOwnerId=<cluster_name>`,
  `sources={ingress}`.
- `depends_on = [module.eks]`.

### 3. `aws/main/s3.tf` Part C — CORS allowed-origin — **HUMAN ✍️**

One-line edit to the existing human-written `aws_s3_bucket_cors_configuration.media`.
Replace the Phase-4c stopgap `*.elb.amazonaws.com` wildcards with the stable domain:
```hcl
allowed_origins = ["http://microecom.local", "https://microecom.local", "https://shop.microecom.click"]
```
Keep `microecom.local` (local k8s still uses it). Drop the `*.elb` wildcards — they were
the no-domain stopgap, now superseded. (The browser's direct PUT to the S3 presigned
upload URL is cross-origin; the served `<img>` GETs are anonymous-read and need no CORS.)

### 4. `k8s/apps/overlays/aws/ingress-gateway.yaml` — HTTPS listener — **CLAUDE**

- Add annotations:
  `alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'` and
  `alb.ingress.kubernetes.io/ssl-redirect: '443'` (the controller's magic redirect action:
  any :80 request → 301 → :443).
- Add `host: shop.microecom.click` to **every** rule (the 8 service prefixes + the `/`
  catch-all). This feeds (a) ACM cert auto-discovery and (b) external-dns record creation.
- **No** `certificate-arn` annotation (auto-discovery). The ingress stays free of any
  Terraform-derived value — no cross-boundary plumbing.

### 5. `aws/main/outputs.tf` + `scripts/aws/up-all.sh` — surface the URL — **CLAUDE**

- `output "shop_url" { value = "https://shop.microecom.click" }`.
- `up-all.sh` banner prints `Storefront : https://shop.microecom.click` and a note that
  on the **first** apply, DNS propagation + ACM issuance can take a few minutes before
  the URL resolves. Keep the raw-ALB line for debugging.

## Explicitly out of scope / not touched

- `scripts/aws/seed-secrets.sh` — all browser URLs are already relative from 5a.
- Gateway CORS (`application.gateway.cors.*`) — SPA is same-origin with the API.
- payment-service / SPA source — relative redirects + relative `VITE_API_BASE_URL`
  survive the domain migration unchanged.
- `www.` / apex redirect, multi-subdomain certs, WAF, CloudFront — YAGNI.

## Ordering / failure notes

- The ACM certificate must reach **ISSUED** before the ALB can bind it to the :443
  listener. If the ingress reconciles before validation completes, the controller retries
  until the cert is ready — self-heals, no action needed.
- `aws_acm_certificate_validation` already encodes the cert→DNS-record dependency inside
  Terraform, so a single `terraform apply` converges in order.
- external-dns `policy=upsert-only` means a `make aws-down` leaves the `shop.microecom.click`
  record behind pointing at a now-deleted ALB; the next `make aws-all` upserts it to the
  new ALB. Acceptable for a demo. (A `sync` policy would clean it up but could delete
  records on transient ingress flaps — not worth the risk here.)

## Verification

### Offline gates (Claude, pre-handoff)
- `terraform fmt aws/main/dns.tf aws/main/external-dns.tf aws/main/s3.tf aws/main/outputs.tf`
  (formatting only — **no** `init` / `validate` / `plan`; those need credentials and are
  the user's billed step).
- `kubectl kustomize k8s/apps/overlays/aws` renders successfully and the gateway ingress
  shows `listen-ports`, `ssl-redirect`, and `host: shop.microecom.click` on every rule.
- `bash -n scripts/aws/up-all.sh`.
- grep cross-checks: `attach_external_dns_policy` + `external_dns_hosted_zone_arns` in
  external-dns.tf; `shop.microecom.click` present in s3.tf CORS, the ingress, and the
  output; `policy=upsert-only` + `domainFilters` in the helm_release.

### Billed (USER)
1. **One-time:** register `microecom.click` in the Route 53 console.
2. Write the HUMAN Terraform (Components 1, 2a, 3), tell Claude "review".
3. `make aws-all`.
4. Wait for ACM `ISSUED` + DNS propagation (first apply: a few minutes).
5. Open `https://shop.microecom.click`, confirm the padlock (valid cert), and run the
   funnel: browse → login → cart → checkout → mock-PayPal approve → `/payment/success`
   → order COMPLETED. Confirm `http://shop.microecom.click` 301-redirects to HTTPS.

## Interview-prep talking points

- **Lifecycle boundaries:** why domain *registration* (irreversible, externally billed,
  async) lives outside the Terraform that's destroyed nightly, while records + cert live
  inside it — and why a `data` source for the zone keeps the NS delegation stable across
  teardowns.
- **external-dns vs a static alias record:** the ALB hostname is dynamic (controller-minted
  at apply), so only a controller that watches the live Ingress can write the record.
- **ACM DNS validation with `for_each`:** `domain_validation_options` is a set; the
  `for_each`/`allow_overwrite` idiom and why `aws_acm_certificate_validation` is the gate.
- **IRSA least privilege:** `external_dns_hosted_zone_arns` scopes the role to one zone
  instead of the module default `["*"]`.
- **Cert auto-discovery vs explicit ARN:** how a `host:` rule lets the AWS LB Controller
  find the cert with zero cross-boundary plumbing — and the trade-off (loses the raw-ALB
  fallback).
- **Why 5b needed no app changes:** relative URLs from 5a are origin-agnostic.
