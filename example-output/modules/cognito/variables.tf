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

variable "auto_confirm_signups" {
  type        = bool
  description = "If true, signup auto-confirms users without email verification."
  default     = false
}

variable "advanced_security" {
  type        = string
  description = "Cognito advanced security mode: OFF | AUDIT | ENFORCED."
  default     = "AUDIT"

  validation {
    condition     = contains(["OFF", "AUDIT", "ENFORCED"], var.advanced_security)
    error_message = "advanced_security must be one of OFF, AUDIT, ENFORCED."
  }
}

variable "deletion_protection" {
  type        = bool
  description = "If true, set deletion_protection=ACTIVE on the user pool."
  default     = false
}
