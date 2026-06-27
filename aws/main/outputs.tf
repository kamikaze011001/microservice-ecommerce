output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region the environment lives in"
  value       = var.region
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile microecom"
}

output "eso_irsa_role_arn" {
  description = "IRSA role ARN for the External Secrets Operator SA"
  value       = module.eso_irsa.iam_role_arn
}

# Phase 4a — read by seed-secrets.sh (terraform output -raw db_master_password) so
# the seeded JDBC password is sourced from the same place RDS was created with.
# sensitive = true keeps it out of plan/apply logs; it still lives in tfstate
# (already accepted — state is the secrets boundary, gitignored + in the S3 bucket).
output "db_master_password" {
  description = "RDS master password — single source of truth for seed-secrets.sh"
  value       = var.db_master_password
  sensitive   = true
}

output "shop_url" {
  description = "Public HTTPS URL of the storefront (Phase 5b)"
  value       = "https://shop.microecom.click"
}