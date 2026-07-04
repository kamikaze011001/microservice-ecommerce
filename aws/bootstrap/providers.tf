provider "aws" {
  region = var.region

  # Tag everything this stack makes so aws-leak-check and the bill are legible.
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
