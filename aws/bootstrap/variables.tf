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

variable "budget_limit_usd" {
  description = "Monthly cost ceiling that trips the budget alarm"
  type        = number
  default     = 25
}

variable "budget_email" {
  description = "Email address that receives budget alerts"
  type        = string
  # no default — must be supplied via terraform.tfvars (it's personal)
}
