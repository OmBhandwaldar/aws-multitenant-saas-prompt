output "api_invoke_url" {
  value = module.api.invoke_url
}

output "api_base_url" {
  value = module.api.base_url
}

output "user_pool_id" {
  value = module.cognito.user_pool_id
}

output "user_pool_client_id" {
  value = module.cognito.user_pool_client_id
}

output "app_table_name" {
  value = module.data.app_table_name
}

output "tenant_access_role_arn" {
  value = module.authorizer.tenant_access_role_arn
}

output "sns_alarm_topic_arn" {
  value = module.observability.sns_topic_arn
}
