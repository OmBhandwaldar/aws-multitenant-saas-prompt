output "app_table_name" {
  value       = aws_dynamodb_table.app.name
  description = "Single-table DynamoDB name."
}

output "app_table_arn" {
  value       = aws_dynamodb_table.app.arn
  description = "Single-table DynamoDB ARN. Used in the TenantAccessRole's base policy."
}

output "gsi1_name" {
  value       = "GSI1"
  description = "Name of the entity-by-type GSI."
}
