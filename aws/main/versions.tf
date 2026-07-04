terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  # REMOTE backend — the S3 bucket + DynamoDB lock table built in Phase 0
  # (aws/bootstrap, commit 57a03a5). Hard-coded because backend blocks are
  # evaluated before variables exist.
  backend "s3" {
    bucket         = "microecom-tfstate-583178372344"
    key            = "main/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "microecom-tfstate-lock"
    encrypt        = true
  }
}
