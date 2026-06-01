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
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid region id."
  }
}

variable "owner" {
  type        = string
  description = "Owner tag value."
  default     = "platform"
}

variable "cost_center" {
  type        = string
  description = "Cost center tag value."
  default     = "engineering"
}

variable "entity_types" {
  type        = list(string)
  description = "Business entity types to expose as CRUD routes (one Lambda + route per entity)."
  default     = ["projects", "tasks"]

  validation {
    condition = length(var.entity_types) > 0 && alltrue([
      for e in var.entity_types : can(regex("^[a-z][a-z0-9_]{1,30}[a-z0-9]$", e))
    ])
    error_message = "entity_types must be non-empty; each name must be lowercase snake_case (3-32 chars)."
  }
}

variable "auto_confirm_signups" {
  type        = bool
  description = "If true, signup auto-confirms users without email verification. Set false in prod."
  default     = true
}

variable "cognito_advanced_security" {
  type        = string
  description = "Cognito advanced security mode: OFF | AUDIT | ENFORCED."
  default     = "AUDIT"

  validation {
    condition     = contains(["OFF", "AUDIT", "ENFORCED"], var.cognito_advanced_security)
    error_message = "cognito_advanced_security must be one of OFF, AUDIT, ENFORCED."
  }
}

variable "sts_duration_seconds" {
  type        = number
  description = "STS AssumeRole DurationSeconds for tenant credentials. Min 900 (15 min)."
  default     = 900

  validation {
    condition     = var.sts_duration_seconds >= 900 && var.sts_duration_seconds <= 3600
    error_message = "sts_duration_seconds must be between 900 and 3600."
  }
}

variable "authorizer_result_ttl" {
  type        = number
  description = "API Gateway authorizer result cache TTL in seconds (0 disables caching)."
  default     = 300

  validation {
    condition     = var.authorizer_result_ttl >= 0 && var.authorizer_result_ttl <= 3600
    error_message = "authorizer_result_ttl must be between 0 and 3600."
  }
}

variable "authorizer_reserved_concurrency" {
  type        = number
  description = "Authorizer Lambda reserved concurrency. -1 means unreserved (recommended in dev)."
  default     = -1

  validation {
    condition     = var.authorizer_reserved_concurrency == -1 || (var.authorizer_reserved_concurrency >= 1 && var.authorizer_reserved_concurrency <= 1000)
    error_message = "authorizer_reserved_concurrency must be -1 or between 1 and 1000."
  }
}

variable "business_reserved_concurrency" {
  type        = number
  description = "Business Lambdas reserved concurrency. -1 means unreserved (recommended in dev)."
  default     = -1

  validation {
    condition     = var.business_reserved_concurrency == -1 || (var.business_reserved_concurrency >= 1 && var.business_reserved_concurrency <= 1000)
    error_message = "business_reserved_concurrency must be -1 or between 1 and 1000."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention."
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

variable "api_throttling_burst_limit" {
  type        = number
  description = "API Gateway burst throttle."
  default     = 1000
}

variable "api_throttling_rate_limit" {
  type        = number
  description = "API Gateway rate throttle (RPS)."
  default     = 500
}

variable "enable_custom_domain" {
  type        = bool
  description = "Provision custom domain + ACM. Requires custom_domain and hosted_zone_name."
  default     = false
}

variable "custom_domain" {
  type        = string
  description = "Custom domain FQDN (only used when enable_custom_domain=true)."
  default     = ""
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone name."
  default     = ""
}

variable "enable_waf" {
  type        = bool
  description = "Provision WAFv2 ACL (~$8/month). Off by default in dev."
  default     = false
}

variable "waf_rate_limit" {
  type        = number
  description = "WAF per-IP rate limit (5-minute window)."
  default     = 2000
}

variable "alert_email" {
  type        = string
  description = "Email subscribed to the SNS alarm topic. Empty = skip."
  default     = ""
}
