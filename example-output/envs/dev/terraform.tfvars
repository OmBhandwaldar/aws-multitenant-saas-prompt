project_name = "saas-starter"
environment  = "dev"
aws_region   = "us-east-1"
owner        = "platform"
cost_center  = "engineering"

entity_types = ["projects", "tasks"]

# Dev-friendly defaults:
auto_confirm_signups       = true
cognito_advanced_security  = "AUDIT"
sts_duration_seconds       = 900
authorizer_result_ttl      = 300

# Reserved concurrency: -1 keeps the unreserved pool above the AWS-enforced
# minimum (10) on new accounts. Switch to a positive number once your
# account-level Lambda concurrency limit is raised.
authorizer_reserved_concurrency = -1
business_reserved_concurrency   = -1

# Cost-sensitive defaults for dev:
enable_waf           = false
enable_custom_domain = false
log_retention_days   = 30
log_level            = "INFO"

api_throttling_burst_limit = 1000
api_throttling_rate_limit  = 500

# Alerts: leave empty to skip the SNS email subscription.
alert_email = ""
