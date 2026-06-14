# aws/main/vpc.tf
#
# [CHECKPOINT — HUMAN ✍️]  Write the VPC module block below.
#
# Use module "vpc", source "terraform-aws-modules/vpc/aws", version "~> 5.0".
#
# ── REQUIREMENTS ─────────────────────────────────────────────────────────────
#  - name = "${var.project}-vpc"
#  - cidr = var.vpc_cidr
#  - azs  = 2 AZs.  Use: slice(data.aws_availability_zones.available.names, 0, 2)
#  - private_subnets = 2 subnets, one per AZ — the NODES live here.
#        e.g. ["10.0.1.0/24", "10.0.2.0/24"]
#  - public_subnets  = 2 subnets, one per AZ — the ALB + NAT live here.
#        e.g. ["10.0.101.0/24", "10.0.102.0/24"]
#  - enable_nat_gateway   = true
#  - single_nat_gateway   = true   # ONE NAT for both AZs — deliberate cost cut.
#        (prod would set false → one NAT per AZ for AZ-failure isolation. Doc it.)
#  - enable_dns_hostnames = true   # EKS + private DNS need this.
#
# ── THE TAGS THAT MATTER (the bit interviewers love) ─────────────────────────
# The AWS Load Balancer Controller auto-discovers subnets by tag. Without these
# your Task 5 ingress sits "pending" forever with no ALB created:
#   public_subnet_tags  = { "kubernetes.io/role/elb"          = "1" }
#   private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
#
# Docs: https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
#
# Write your module "vpc" block below, then tell Claude "review".

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~>5.0"
  name    = format("%s-vpc", var.project)

  cidr = var.vpc_cidr

  azs                  = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets      = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets       = ["10.0.101.0/24", "10.0.102.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

