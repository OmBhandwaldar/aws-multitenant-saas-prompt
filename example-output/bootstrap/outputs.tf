output "state_bucket_name" {
  value       = aws_s3_bucket.state.id
  description = "S3 bucket name to pass via -backend-config=bucket=..."
}

output "lock_table_name" {
  value       = aws_dynamodb_table.lock.name
  description = "DynamoDB lock table name to pass via -backend-config=dynamodb_table=..."
}

output "aws_region" {
  value       = var.aws_region
  description = "Region for the backend block."
}
