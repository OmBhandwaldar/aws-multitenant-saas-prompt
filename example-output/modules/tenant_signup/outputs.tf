output "function_name" {
  value       = aws_lambda_function.this.function_name
  description = "Tenant signup Lambda function name."
}

output "function_arn" {
  value       = aws_lambda_function.this.arn
  description = "Tenant signup Lambda function ARN."
}

output "invoke_arn" {
  value       = aws_lambda_function.this.invoke_arn
  description = "Invoke ARN used by API Gateway."
}
