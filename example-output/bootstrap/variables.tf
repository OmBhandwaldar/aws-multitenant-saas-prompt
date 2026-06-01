variable "project_name" {
  type        = string
  description = "Short kebab-case project identifier used in resource names."
  default     = "saas-starter"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 chars, lowercase, kebab-case."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for the remote state bucket and lock table."
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid region id, e.g. us-east-1."
  }
}

variable "owner" {
  type        = string
  description = "Owner tag value (team or individual responsible)."
  default     = "platform"
}

variable "cost_center" {
  type        = string
  description = "Cost center tag value."
  default     = "engineering"
}
