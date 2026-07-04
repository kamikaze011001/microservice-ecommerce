# aws/main/eks.tf
#
# [CHECKPOINT — HUMAN ✍️]  Write the EKS module block below.
#
# Use module "eks", source "terraform-aws-modules/eks/aws", version "~> 20.0".
#
# ── REQUIREMENTS ─────────────────────────────────────────────────────────────
#  - cluster_name    = var.cluster_name
#  - cluster_version = var.cluster_version
#  - vpc_id     = module.vpc.vpc_id
#  - subnet_ids = module.vpc.private_subnets    # nodes live in PRIVATE subnets
#  - cluster_endpoint_public_access = true       # so your laptop kubectl reaches it
#  - enable_irsa = true                           # OIDC provider for IRSA (Task 4)
#
#  - eks_managed_node_groups = {
#      default = {
#        instance_types = var.node_instance_types     # ["t4g.large"] = Graviton/arm64
#        capacity_type  = "SPOT"                       # ~70% cheaper, fine for sandbox
#        ami_type       = "AL2023_ARM_64_STANDARD"     # ARM64 AMI — MUST match t4g!
#        min_size       = var.node_min_size
#        max_size       = var.node_max_size
#        desired_size   = var.node_desired_size
#      }
#    }
#
# ── GOTCHA 1: arm64 AMI <-> arm64 instance ───────────────────────────────────
# t4g.* are Graviton (arm64). The AMI MUST be an *_ARM_64_* type or every pod
# CrashLoops with "exec format error". (This is also why your local arm64 image
# builds run here with no cross-compile — spec §6.)
#
# ── GOTCHA 2: grant YOURSELF cluster admin ───────────────────────────────────
# EKS module v20 uses Access Entries. Add this or your own kubectl gets
# "Unauthorized" even though you created the cluster:
#   enable_cluster_creator_admin_permissions = true
#
# Docs: https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
#
# Write your module "eks" block below, then tell Claude "review".

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~>20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access           = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      # instance_types / capacity_type / ami_type / sizes
      instance_types = var.node_instance_types  # ["t4g.large"] = Graviton/arm64
      capacity_type  = "SPOT"                   # ~70% cheaper, fine for sandbox
      ami_type       = "AL2023_ARM_64_STANDARD" # ARM64 AMI — MUST match t4g!
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # [CHECKPOINT — HUMAN ✍️]  Pin this node group to a SINGLE AZ.
      #
      # WHY: EBS volumes are AZ-locked. Without this line the node group's ASG
      # spans both private subnets (both AZs) and is free to rebalance all
      # capacity into one AZ after a SPOT reclaim — stranding the stateful EBS
      # volumes (kafka/mongo/vm) in an AZ with no node. Pin nodes + volumes to
      # the same AZ and they always co-locate.
      #
      # HOW: override the cluster-level subnet_ids for just THIS group with one
      # private subnet. module.vpc.private_subnets is a list ordered by AZ, so
      # index [0] = the first AZ (ap-southeast-1a). Write a `subnet_ids = [...]`
      # line that selects a single element of module.vpc.private_subnets.
      #
      # TRADE-OFF to note: this kills AZ redundancy for the node group. Fine for
      # a single-replica sandbox tier; prod would run one node group per AZ.
      # Docs: registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
      #
      # subnet_ids = [ ... ]   ← write this line, then tell Claude "review"
      subnet_ids = [module.vpc.private_subnets[0]]
    }
  }
}

