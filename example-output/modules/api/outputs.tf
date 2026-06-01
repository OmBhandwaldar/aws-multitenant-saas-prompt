output "api_id" {
  value       = aws_api_gateway_rest_api.this.id
  description = "REST API ID."
}

output "api_name" {
  value       = aws_api_gateway_rest_api.this.name
  description = "REST API name."
}

output "stage_name" {
  value       = aws_api_gateway_stage.this.stage_name
  description = "Deployed stage name."
}

output "stage_arn" {
  value       = aws_api_gateway_stage.this.arn
  description = "Stage ARN (used to attach WAF)."
}

output "invoke_url" {
  value       = aws_api_gateway_stage.this.invoke_url
  description = "Stage invoke URL."
}

output "base_url" {
  value       = var.enable_custom_domain ? "https://${var.custom_domain}" : aws_api_gateway_stage.this.invoke_url
  description = "Base URL (custom domain when enabled, otherwise stage invoke URL)."
}

output "execution_arn" {
  value       = aws_api_gateway_rest_api.this.execution_arn
  description = "Execution ARN used for IAM source_arn scoping."
}
