terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Bootstrap uses a LOCAL backend on purpose: it creates the very bucket that
  # later stacks (aws/main) will use as their remote backend. You cannot store
  # state in a bucket that does not exist yet.
  backend "local" {}
}
