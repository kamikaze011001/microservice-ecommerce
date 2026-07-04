variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used as a tag and a resource name prefix"
  type        = string
  default     = "microecom"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "microecom-eks"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# Phase 1 runs small + cheap. Phase 2/3 scale the node group up when real
# workloads land. t4g = Graviton (arm64) — matches your local arm64 image builds.
variable "node_instance_types" {
  description = "EC2 instance types for the managed node group (Graviton/arm64)"
  type        = list(string)
  default     = ["t4g.large"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

# Phase 4a — RDS master password. No default on purpose: it must be supplied via
# the gitignored terraform.tfvars so a secret never lands in version control.
# seed-secrets.sh reads the SAME value back via the sensitive output below, so the
# password the apps receive can never drift from what RDS was created with.
variable "db_master_password" {
  description = "Master password for the RDS MySQL instance (set in gitignored terraform.tfvars)"
  type        = string
  sensitive   = true
}
