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