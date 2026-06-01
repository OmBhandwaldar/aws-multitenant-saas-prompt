output "api_invoke_url" {
  value       = module.api.invoke_url
  description = "Base API Gateway invoke URL."
}

output "api_base_url" {
  value       = module.api.base_url
  description = "Use as the base URL for all API calls (with or without custom domain)."
}

output "user_pool_id" {
  value       = module.cognito.user_pool_id
  description = "Cognito user pool ID (needed for sign-up / initiate-auth)."
}

output "user_pool_client_id" {
  value       = module.cognito.user_pool_client_id
  description = "Cognito user pool client ID."
}

output "app_table_name" {
  value       = module.data.app_table_name
  description = "DynamoDB single-table name."
}

output "app_table_arn" {
  value       = module.data.app_table_arn
  description = "DynamoDB single-table ARN."
}

output "tenant_access_role_arn" {
  value       = module.authorizer.tenant_access_role_arn
  description = "ARN of the TenantAccessRole the authorizer assumes per request."
}

output "authorizer_function_name" {
  value       = module.authorizer.function_name
  description = "Lambda authorizer function name."
}

output "tenant_signup_function_name" {
  value       = module.tenant_signup.function_name
  description = "Public tenant signup Lambda function name."
}

output "business_function_names" {
  value       = module.business.function_names
  description = "Map of entity_type -> business Lambda function name."
}

output "sns_alarm_topic_arn" {
  value       = module.observability.sns_topic_arn
  description = "Subscribe humans to this for alerts."
}

output "dashboard_name" {
  value       = module.observability.dashboard_name
  description = "CloudWatch dashboard."
}
