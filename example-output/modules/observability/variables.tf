variable "project_name" {
  type        = string
  description = "Short kebab-case project identifier."
}

variable "environment" {
  type        = string
  description = "Deployment environment."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region (used in dashboard widget JSON)."
}

variable "alert_email" {
  type        = string
  description = "Email subscribed to the SNS alarm topic. Empty = skip."
  default     = ""
}

variable "authorizer_function_name" {
  type        = string
  description = "Authorizer Lambda function name."
}

variable "tenant_signup_function_name" {
  type        = string
  description = "Tenant signup Lambda function name."
}

variable "business_function_names" {
  type        = map(string)
  description = "Map of route key -> business Lambda function name."
}

variable "app_table_name" {
  type        = string
  description = "DynamoDB single-table name."
}

variable "api_name" {
  type        = string
  description = "API Gateway REST API name."
}

variable "api_stage_name" {
  type        = string
  description = "API Gateway stage name."
}

variable "user_pool_id" {
  type        = string
  description = "Cognito user pool ID (for SignInThrottles alarm)."
}
