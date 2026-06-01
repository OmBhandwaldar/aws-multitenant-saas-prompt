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
  description = "AWS region (passed to the Lambda for JWKS URL construction)."
}

variable "user_pool_id" {
  type        = string
  description = "Cognito user pool ID — used to construct the JWKS URL and 'iss' check."
}

variable "user_pool_client_id" {
  type        = string
  description = "App client ID — used for the JWT 'aud' / 'client_id' check."
}

variable "app_table_arn" {
  type        = string
  description = "DynamoDB single-table ARN — the TenantAccessRole's base policy grants access to this and its indexes only."
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported value."
  }
}

variable "log_level" {
  type        = string
  description = "Powertools log level."
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARNING, ERROR."
  }
}

variable "reserved_concurrency" {
  type        = number
  description = "Authorizer Lambda reserved concurrency. -1 means unreserved."
  default     = -1

  validation {
    condition     = var.reserved_concurrency == -1 || (var.reserved_concurrency >= 1 && var.reserved_concurrency <= 1000)
    error_message = "reserved_concurrency must be -1 or between 1 and 1000."
  }
}

variable "sts_duration_seconds" {
  type        = number
  description = "STS AssumeRole DurationSeconds for tenant credentials. Min 900."
  default     = 900

  validation {
    condition     = var.sts_duration_seconds >= 900 && var.sts_duration_seconds <= 3600
    error_message = "sts_duration_seconds must be between 900 and 3600."
  }
}
