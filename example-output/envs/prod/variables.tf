variable "project_name" {
  type        = string
  description = "Short kebab-case project identifier."
  default     = "saas-starter"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 chars, lowercase, kebab-case."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment."
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "owner" {
  type    = string
  default = "platform"
}

variable "cost_center" {
  type    = string
  default = "engineering"
}

variable "entity_types" {
  type    = list(string)
  default = ["projects", "tasks"]
}

variable "auto_confirm_signups" {
  type        = bool
  description = "Auto-confirm signups. Must be false in prod (require email verification)."
  default     = false
}

variable "cognito_advanced_security" {
  type    = string
  default = "ENFORCED"
}

variable "sts_duration_seconds" {
  type    = number
  default = 900
}

variable "authorizer_result_ttl" {
  type    = number
  default = 300
}

variable "authorizer_reserved_concurrency" {
  type    = number
  default = 10

  validation {
    condition     = var.authorizer_reserved_concurrency == -1 || (var.authorizer_reserved_concurrency >= 1 && var.authorizer_reserved_concurrency <= 1000)
    error_message = "authorizer_reserved_concurrency must be -1 or between 1 and 1000."
  }
}

variable "business_reserved_concurrency" {
  type    = number
  default = 10

  validation {
    condition     = var.business_reserved_concurrency == -1 || (var.business_reserved_concurrency >= 1 && var.business_reserved_concurrency <= 1000)
    error_message = "business_reserved_concurrency must be -1 or between 1 and 1000."
  }
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "api_throttling_burst_limit" {
  type    = number
  default = 1000
}

variable "api_throttling_rate_limit" {
  type    = number
  default = 500
}

variable "enable_custom_domain" {
  type    = bool
  default = false
}

variable "custom_domain" {
  type    = string
  default = ""
}

variable "hosted_zone_name" {
  type    = string
  default = ""
}

variable "enable_waf" {
  type    = bool
  default = true
}

variable "waf_rate_limit" {
  type    = number
  default = 2000
}

variable "alert_email" {
  type    = string
  default = ""
}
