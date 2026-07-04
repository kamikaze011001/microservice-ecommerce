# aws/main/secrets.tf  —  [CHECKPOINT — HUMAN ✍️]  (Phase 3, Secrets)
#
# WHY THIS FILE EXISTS
# Every JVM service used to read its config from a self-managed Vault pod. On EKS
# we replace Vault with AWS Secrets Manager + the External Secrets Operator (ESO).
# This file declares, in Terraform:
#   PART A — the EMPTY secret CONTAINERS (one per service). No values here — values
#            are pushed later by scripts/aws/seed-secrets.sh, so nothing secret
#            ever lands in tfstate.
#   PART B — the IRSA role ESO assumes to call secretsmanager:GetSecretValue.
#            Same IRSA shape you already wrote for the ALB controller and the EBS
#            CSI driver — open alb-controller.tf / storage.tf side by side.
#
# ─────────────────────────────────────────────────────────────────────────────
# The 11 service paths (kept in a local so PART A can for_each over them and the
# IRSA policy in PART B can scope to exactly these ARNs).
locals {
  secret_services = [
    "core-s3", "ecommerce", "authorization-server", "gateway",
    "product-service", "inventory-service", "order-service",
    "orchestrator-service", "payment-service", "bff-service",
    "mock-paypal-service",
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# PART A — [HUMAN ✍️]  one empty Secrets Manager container per service.
#
# Declare an aws_secretsmanager_secret with for_each over local.secret_services.
# Requirements:
#   - name = "app/${each.value}"            # the path ESO will read (app/<service>)
#   - recovery_window_in_days = 0           # ephemeral: allow immediate recreate,
#                                           #   no 30-day soft-delete that blocks a
#                                           #   teardown/re-apply cycle
#   - DO NOT set a secret_string here       # values come from seed-secrets.sh
#
# Reference: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret
#
# Write `resource "aws_secretsmanager_secret" "app" { ... }` below.

resource "aws_secretsmanager_secret" "app" {
  for_each                = toset(local.secret_services)
  name                    = "app/${each.value}"
  recovery_window_in_days = 0
}

# ─────────────────────────────────────────────────────────────────────────────
# PART B — [HUMAN ✍️]  the ESO IRSA role.
#
# Use the SAME IRSA submodule as alb_irsa / ebs_csi_irsa. ESO has a built-in
# "magic flag" (like attach_load_balancer_controller_policy / attach_ebs_csi_policy):
#
#   module "eso_irsa" {
#     source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#     version = "~> 5.0"
#
#     role_name = "${var.project}-external-secrets"
#     attach_external_secrets_policy        = true                       # the magic flag
#     external_secrets_secrets_manager_arns = [for s in aws_secretsmanager_secret.app : s.arn]
#
#     oidc_providers = {
#       main = {
#         provider_arn               = module.eks.oidc_provider_arn
#         namespace_service_accounts = ["infra:external-secrets"]        # ESO SA we create in Task 5
#       }
#     }
#   }
#
# English: "the k8s ServiceAccount infra/external-secrets may assume this IAM role,
# and the role may GetSecretValue on exactly the app/* secrets above." Least
# privilege — ESO can read these secrets and nothing else.
#
# 🎓 Interview prep — be ready to explain:
#   - Why scope external_secrets_secrets_manager_arns to the 11 ARNs instead of "*"
#     (blast radius: a compromised ESO can't read unrelated secrets).
#   - Why values live in the seed script, not here (tfstate is plaintext-at-rest in
#     S3; keeping values out of state means a state leak ≠ a secrets leak).
#   - IRSA vs static IAM user keys in the cluster (no long-lived creds; STS issues
#     short-lived tokens scoped to the SA).
#
# Write `module "eso_irsa" { ... }` below, then tell Claude "review".
module "eso_irsa" {
  source                                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version                               = "~> 5.0"
  role_name                             = "${var.project}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = [for s in aws_secretsmanager_secret.app : s.arn]
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["infra:external-secrets"]
    }
  }
}

