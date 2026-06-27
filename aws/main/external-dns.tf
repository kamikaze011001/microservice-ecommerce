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
