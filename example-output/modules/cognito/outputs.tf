output "user_pool_id" {
  value       = aws_cognito_user_pool.this.id
  description = "Cognito user pool ID."
}

output "user_pool_arn" {
  value       = aws_cognito_user_pool.this.arn
  description = "Cognito user pool ARN (used in Lambda IAM policies)."
}

output "user_pool_client_id" {
  value       = aws_cognito_user_pool_client.this.id
  description = "App client ID — sent as 'aud' / 'client_id' claim in tokens."
}
