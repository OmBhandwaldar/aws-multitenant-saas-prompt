project_name = "saas-starter"
environment  = "prod"
aws_region   = "us-east-1"
owner        = "platform"
cost_center  = "engineering"

entity_types = ["projects", "tasks"]

auto_confirm_signups      = false
cognito_advanced_security = "ENFORCED"
sts_duration_seconds      = 900
authorizer_result_ttl     = 300

authorizer_reserved_concurrency = 10
business_reserved_concurrency   = 10

enable_waf           = true
enable_custom_domain = false
log_retention_days   = 90
log_level            = "INFO"

api_throttling_burst_limit = 1000
api_throttling_rate_limit  = 500

alert_email = ""
