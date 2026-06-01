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
  description = "AWS region."
}

variable "entity_types" {
  type        = list(string)
  description = "Business entity types to provision (one Lambda + route per type)."

  validation {
    condition     = length(var.entity_types) > 0
    error_message = "entity_types must be non-empty."
  }
}

variable "app_table_name" {
  type        = string
  description = "DynamoDB single-table name."
}

variable "app_table_arn" {
  type        = string
  description = "DynamoDB single-table ARN."
}

variable "user_pool_id" {
  type        = string
  description = "Cognito user pool ID (for the admin-only users Lambda)."
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention."
  default     = 30
}

variable "log_level" {
  type        = string
  description = "Powertools log level."
  default     = "INFO"
}

variable "reserved_concurrency" {
  type        = number
  description = "Reserved concurrency for business Lambdas. -1 means unreserved."
  default     = -1

  validation {
    condition     = var.reserved_concurrency == -1 || (var.reserved_concurrency >= 1 && var.reserved_concurrency <= 1000)
    error_message = "reserved_concurrency must be -1 or between 1 and 1000."
  }
}
