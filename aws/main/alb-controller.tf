# aws/main/alb-controller.tf
#
# The AWS Load Balancer Controller turns a Kubernetes Ingress into a real AWS
# ALB. It needs AWS permissions, granted via IRSA (IAM Role for Service Accounts)
# — the keystone Phase 1 concept.
#
# This file has TWO halves:
#   4a [HUMAN ✍️]  the IRSA role  (write it below)
#   4b [CLAUDE]    the helm_release that installs the controller (added after 4a review)
#
# ─────────────────────────────────────────────────────────────────────────────
# 4a — [CHECKPOINT — HUMAN ✍️]  Write the IRSA role module below.
#
# Use the IRSA submodule — it ships the exact IAM policy the ALB controller needs
# so you don't hand-write 200 lines of JSON:
#
#   module "alb_irsa" {
#     source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#     version = "~> 5.0"
#
#     role_name = "${var.project}-alb-controller"
#     attach_load_balancer_controller_policy = true     # the magic flag
#
#     oidc_providers = {
#       main = {
#         provider_arn               = module.eks.oidc_provider_arn
#         namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
#       }
#     }
#   }
#
# What you're declaring in English: "the k8s ServiceAccount named
# aws-load-balancer-controller in namespace kube-system may assume this IAM role."
# That trust relationship IS what IRSA is — no static AWS keys in the cluster.
#
# Docs: https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest/submodules/iam-role-for-service-accounts-eks
#
# Write your module "alb_irsa" block below, then tell Claude "review".
# (Claude appends the helm_release — 4b — after the review.)

module "alb_irsa" {
  source                                 = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version                                = "~> 5.0"
  role_name                              = "${var.project}-alb-controller"
  attach_load_balancer_controller_policy = true # the magic flag
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4b — [CLAUDE]  Install the AWS Load Balancer Controller via its Helm chart.
# The serviceAccount.annotations line is the IRSA link: it stamps the role ARN
# from module.alb_irsa onto the SA, so the controller's pods get temp AWS creds
# via STS — no static keys. The SA name/namespace here MUST match the
# namespace_service_accounts you declared above.
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_irsa.iam_role_arn
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [module.eks]
}

