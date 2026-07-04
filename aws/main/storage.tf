# aws/main/storage.tf  —  [CHECKPOINT — HUMAN ✍️]  (Phase 2, Task 3)
#
# WHY THIS FILE EXISTS
# Our self-hosted infra (Kafka, MongoDB, VictoriaMetrics) is stateful — each pod
# needs a disk that survives a reschedule. On kind that disk was a hostPath; on
# EKS it must be a real AWS EBS volume. The thing that turns a Kubernetes PVC
# into a provisioned EBS volume is the **EBS CSI driver**. It does not ship in a
# vanilla EKS cluster — you add it as a managed add-on, and (because creating an
# EBS volume is an AWS API call) it needs AWS permissions via IRSA.
#
# So this file is the storage twin of alb-controller.tf:
#   - alb-controller.tf  gave the ALB controller perms to create load balancers
#   - storage.tf         gives the EBS CSI driver perms to create disks
#
# You already wrote the ALB IRSA module — this is the SAME shape. Open
# alb-controller.tf side-by-side; the only deltas are the flag name, the role
# name, and the service-account name.
#
# ─────────────────────────────────────────────────────────────────────────────
# PART A — [HUMAN ✍️]  the EBS CSI IRSA role
#
#   module "ebs_csi_irsa" {
#     source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#     version = "~> 5.0"
#
#     role_name             = "${var.project}-ebs-csi"
#     attach_ebs_csi_policy = true     # <- the magic flag (ALB used
#                                      #    attach_load_balancer_controller_policy)
#
#     oidc_providers = {
#       main = {
#         provider_arn               = module.eks.oidc_provider_arn
#         namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
#       }
#     }
#   }
#
# The SA name is fixed by the add-on: the driver's controller pod runs as
# kube-system/ebs-csi-controller-sa. The trust policy says "that SA may assume
# this role" — same IRSA contract you declared for the ALB controller.
#
# ─────────────────────────────────────────────────────────────────────────────
# PART B — [HUMAN ✍️]  the managed add-on that installs the driver
#
# Unlike the ALB controller (a Helm chart), the EBS CSI driver is a first-class
# EKS *managed add-on* — AWS keeps it patched. So instead of helm_release you use
# aws_eks_addon:
#
#   resource "aws_eks_addon" "ebs_csi" {
#     cluster_name             = module.eks.cluster_name
#     addon_name               = "aws-ebs-csi-driver"
#     service_account_role_arn = module.ebs_csi_irsa.iam_role_arn   # <- the IRSA link
#     resolve_conflicts_on_create = "OVERWRITE"
#   }
#
#   - service_account_role_arn is what wires Part A to Part B: the add-on stamps
#     this role ARN onto the ebs-csi-controller-sa it creates, so the driver's
#     pods get temp AWS creds via STS — no static keys (exactly like the ALB SA
#     annotation, but AWS does the stamping for you here).
#   - resolve_conflicts_on_create = "OVERWRITE" lets the add-on take ownership of
#     the SA cleanly on first install.
#
# Docs:
#  - IRSA submodule: https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest/submodules/iam-role-for-service-accounts-eks
#  - aws_eks_addon:  https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon
#
# 🎓 Interview prep — be ready to explain:
#   - Why the EBS CSI driver needs IRSA at all (it calls ec2:CreateVolume etc.;
#     a pod with no AWS identity couldn't provision a disk).
#   - add-on vs Helm: when do you pick a managed add-on over a community chart?
#     (lifecycle/patching owned by AWS, version pinned to the cluster, vs. the
#     flexibility/breadth of Helm for things AWS doesn't manage like the ALB ctlr.)
#   - Why WaitForFirstConsumer on the StorageClass (Task 4) pairs with this: the
#     volume is created in the AZ where the pod actually lands.
#
# Write module "ebs_csi_irsa" and resource "aws_eks_addon" "ebs_csi" below, then
# tell Claude "review". (Task 4 = the gp3 StorageClass manifest, comes after.)
module "ebs_csi_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.0"
  role_name             = "${var.project}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
}

