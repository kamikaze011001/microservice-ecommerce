# aws/bootstrap/ecr.tf  —  [CHECKPOINT — HUMAN ✍️]
#
# Create one ECR repository per image we will push. These live in the PERSISTENT
# bootstrap stack on purpose: images survive `make aws-down` so spin-up stays
# fast. (The ephemeral `aws/main` stack is destroyed every session; the registry
# is durable shared state, like the Terraform state bucket next to this file.)
#
# The account ID for the registry hostname comes from the existing
# `data "aws_caller_identity" "current"` already declared in state.tf — just
# reference data.aws_caller_identity.current.account_id (no new data block here).
#
# ──────────────────────────────────────────────────────────────────────────────
# YOUR JOB: write the four things below, then ask Claude to review before apply.
# ──────────────────────────────────────────────────────────────────────────────
#
# 1) variable "service_images" — a set(string) of image names so the list is
#    data, not copy-paste. Suggested default:
#
#       "maven-cores",            # shared build-cache base image
#       "gateway", "authorization-server", "bff-service",
#       "product-service", "inventory-service", "order-service",
#       "payment-service", "orchestrator-service",
#       "frontend", "mock-paypal-service"
#
# 2) resource "aws_ecr_repository" "svc"  — for_each = var.service_images
#       - name                 = each.value
#       - image_tag_mutability = "MUTABLE"   # we push the mutable :dev tag in dev
#       - image_scanning_configuration { scan_on_push = true }
#       - force_delete         = false       # spec §4 gotcha #3: normal teardown
#                                            #   KEEPS images; only bootstrap
#                                            #   destroy paths force-delete.
#
# 3) resource "aws_ecr_lifecycle_policy" "svc"  — for_each = var.service_images
#       - repository = aws_ecr_repository.svc[each.key].name
#       - policy     = jsonencode({ rules = [{
#           rulePriority = 1
#           description  = "expire untagged images, keep last 3"
#           selection    = { tagStatus = "untagged",
#                            countType = "imageCountMoreThan", countNumber = 3 }
#           action       = { type = "expire" }
#         }] })
#
# 4) output "ecr_registry" — the registry hostname the push script reads:
#       value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
#
# Docs:
#  - https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository
#  - https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy
#
# 🎓 While you write it, be ready to explain in an interview:
#   - why for_each over a set(string) beats count (stable addresses — reordering
#     the list doesn't recreate every repo)
#   - why the lifecycle policy matters (untagged layers pile up on every :dev push)
#   - why ECR is in bootstrap, not main (persistent vs ephemeral split)
variable "service_images" {
  type        = set(string)
  description = "A set of Java application images"
  default = ["maven-cores", "gateway", "authorization-server",
    "bff-service", "product-service", "inventory-service", "order-service",
  "payment-service", "orchestrator-service", "frontend", "mock-paypal-service"]
}

resource "aws_ecr_repository" "svc" {
  for_each             = var.service_images
  name                 = each.value
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = false
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = var.service_images
  repository = aws_ecr_repository.svc[each.key].name
  policy = jsonencode(
    {
      rules = [
        {
          rulePriority = 1,
          description  = "expire untagged images, keep last 3",
          selection = {
            tagStatus   = "untagged",
            countType   = "imageCountMoreThan",
            countNumber = 3
          },
          action = { type = "expire" },
        }
      ]
    }
  )
}

output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}








