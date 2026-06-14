output "state_bucket" {
  description = "S3 bucket holding remote state for all other stacks"
  value       = aws_s3_bucket.microecom-state.id
}

output "lock_table" {
  description = "DynamoDB table used for state locking"
  value       = aws_dynamodb_table.microecom-state-lock.name
}

output "region" {
  description = "AWS region these resources live in"
  value       = var.region
}
