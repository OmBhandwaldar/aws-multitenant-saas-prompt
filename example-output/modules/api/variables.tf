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

variable "authorizer_invoke_arn" {
  type        = string
  description = "Authorizer Lambda invoke ARN (apigateway: prefix)."
}

variable "authorizer_function_name" {
  type        = string
  description = "Authorizer Lambda function name (for lambda:InvokeFunction permission)."
}

variable "authorizer_result_ttl" {
  type        = number
  description = "API Gateway authorizer result cache TTL in seconds (0 disables)."
  default     = 300

  validation {
    condition     = var.authorizer_result_ttl >= 0 && var.authorizer_result_ttl <= 3600
    error_message = "authorizer_result_ttl must be between 0 and 3600."
  }
}

variable "tenant_signup_invoke_arn" {
  type        = string
  description = "Tenant signup Lambda invoke ARN."
}

variable "tenant_signup_function_name" {
  type        = string
  description = "Tenant signup Lambda function name."
}

variable "business_lambdas" {
  type = map(object({
    function_name = string
    invoke_arn    = string
  }))
  description = "Map keyed by entity_type (and 'users') -> {function_name, invoke_arn}."
}

variable "entity_types" {
  type        = list(string)
  description = "Business entity types to expose as REST collections."

  validation {
    condition     = length(var.entity_types) > 0
    error_message = "entity_types must be non-empty."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days for access logs."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported value."
  }
}

variable "throttling_burst_limit" {
  type        = number
  description = "Per-method burst throttle."
  default     = 1000

  validation {
    condition     = var.throttling_burst_limit >= 1
    error_message = "throttling_burst_limit must be >= 1."
  }
}

variable "throttling_rate_limit" {
  type        = number
  description = "Per-method steady-state throttle (RPS)."
  default     = 500

  validation {
    condition     = var.throttling_rate_limit >= 1
    error_message = "throttling_rate_limit must be >= 1."
  }
}

variable "enable_custom_domain" {
  type        = bool
  description = "If true, provision ACM + Route53 + custom domain."
  default     = false
}

variable "custom_domain" {
  type        = string
  description = "Custom domain name (only when enable_custom_domain=true)."
  default     = ""
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone name."
  default     = ""
}

variable "enable_waf" {
  type        = bool
  description = "If true, attach a WAFv2 web ACL (~$8/month)."
  default     = false
}

variable "waf_rate_limit" {
  type        = number
  description = "Per-IP rate limit (5-minute window) for the WAF rate rule."
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 100 && var.waf_rate_limit <= 20000000
    error_message = "waf_rate_limit must be between 100 and 20,000,000."
  }
}
