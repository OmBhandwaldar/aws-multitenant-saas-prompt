output "function_name" {
  value       = aws_lambda_function.authorizer.function_name
  description = "Authorizer Lambda function name."
}

output "function_arn" {
  value       = aws_lambda_function.authorizer.arn
  description = "Authorizer Lambda function ARN."
}

output "invoke_arn" {
  value       = aws_lambda_function.authorizer.invoke_arn
  description = "Authorizer invoke ARN (used by aws_api_gateway_authorizer)."
}

output "role_arn" {
  value       = aws_iam_role.authorizer_lambda.arn
  description = "Authorizer Lambda execution role ARN."
}

output "tenant_access_role_arn" {
  value       = aws_iam_role.tenant_access.arn
  description = "TenantAccessRole ARN — the role assumed per request with a tenant-scoped session policy."
}
