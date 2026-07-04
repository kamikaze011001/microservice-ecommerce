# Pick the first 2 AZs that support EKS in this region (ap-southeast-1a/b/c).
# Filtering out opt-in AZs (Local Zones / Wavelength) keeps us on standard AZs.
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
