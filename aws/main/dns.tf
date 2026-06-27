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
