terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

locals {
  api_name   = "${var.project_name}-${var.environment}-api"
  stage_name = var.environment

  # Methods that exist per entity. (CRUD + list)
  entity_collection_methods = ["GET", "POST"]
  entity_item_methods       = ["GET", "PATCH", "DELETE"]

  # All routes that should trigger a redeploy when their integration changes.
  # We hash these into the deployment trigger.
  redeploy_inputs = jsonencode([
    aws_api_gateway_resource.tenants.id,
    aws_api_gateway_resource.tenants_signup.id,
    aws_api_gateway_method.tenants_signup_post.id,
    aws_api_gateway_integration.tenants_signup.id,
    [for r in aws_api_gateway_resource.entity_collection : r.id],
    [for r in aws_api_gateway_resource.entity_item : r.id],
    [for m in aws_api_gateway_method.entity_collection : m.id],
    [for m in aws_api_gateway_method.entity_item : m.id],
    [for i in aws_api_gateway_integration.entity_collection : i.id],
    [for i in aws_api_gateway_integration.entity_item : i.id],
    aws_api_gateway_resource.users.id,
    aws_api_gateway_resource.users_id.id,
    aws_api_gateway_method.users_get.id,
    aws_api_gateway_method.users_post.id,
    aws_api_gateway_method.users_delete.id,
    aws_api_gateway_integration.users_get.id,
    aws_api_gateway_integration.users_post.id,
    aws_api_gateway_integration.users_delete.id,
    aws_api_gateway_authorizer.tenant.id,
  ])
}

###############################################################################
# Account-level: API Gateway -> CloudWatch Logs role.
# Without this the stage cannot enable access logging.
###############################################################################
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  name               = "${var.project_name}-${var.environment}-apigw-cw"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn
  depends_on          = [aws_iam_role_policy_attachment.apigw_cloudwatch]
}

###############################################################################
# REST API.
###############################################################################
resource "aws_api_gateway_rest_api" "this" {
  name        = local.api_name
  description = "SaaS API for ${var.project_name} (${var.environment})"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

###############################################################################
# Lambda TOKEN authorizer.
# - identity_source: the entire Authorization header (we accept "Bearer <jwt>"
#   or raw JWT; the Lambda handles both).
# - result TTL: 300s caches the (token -> credentials) decision across calls.
###############################################################################
data "aws_iam_policy_document" "apigw_invoke_authorizer" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_authorizer_invoke" {
  name               = "${var.project_name}-${var.environment}-apigw-auth"
  assume_role_policy = data.aws_iam_policy_document.apigw_invoke_authorizer.json
}

# Give API Gateway permission to invoke the authorizer Lambda. The
# source_arn restricts the principal to authorizers under this REST API.
resource "aws_lambda_permission" "apigw_invoke_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = var.authorizer_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/authorizers/*"
}

resource "aws_api_gateway_authorizer" "tenant" {
  name                             = "${var.project_name}-${var.environment}-tenant-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.this.id
  authorizer_uri                   = var.authorizer_invoke_arn
  authorizer_credentials           = aws_iam_role.apigw_authorizer_invoke.arn
  type                             = "TOKEN"
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = var.authorizer_result_ttl
}

# Grant API Gateway permission to assume the role used to invoke the authorizer.
data "aws_iam_policy_document" "apigw_authorizer_role_policy" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = ["*"]
    # Scoped further by the source_arn on aws_lambda_permission above.
  }
}

resource "aws_iam_role_policy" "apigw_authorizer_role_policy" {
  name   = "${var.project_name}-${var.environment}-apigw-auth-inline"
  role   = aws_iam_role.apigw_authorizer_invoke.id
  policy = data.aws_iam_policy_document.apigw_authorizer_role_policy.json
}

###############################################################################
# /tenants/signup (public — no authorizer).
###############################################################################
resource "aws_api_gateway_resource" "tenants" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "tenants"
}

resource "aws_api_gateway_resource" "tenants_signup" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.tenants.id
  path_part   = "signup"
}

resource "aws_api_gateway_method" "tenants_signup_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.tenants_signup.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "tenants_signup" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.tenants_signup.id
  http_method             = aws_api_gateway_method.tenants_signup_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.tenant_signup_invoke_arn
  timeout_milliseconds    = 29000
}

resource "aws_lambda_permission" "tenants_signup" {
  statement_id  = "AllowAPIGatewayInvokeTenantSignup"
  action        = "lambda:InvokeFunction"
  function_name = var.tenant_signup_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

###############################################################################
# Per-entity routes (authenticated):
#   GET  /{entity}          -> list
#   POST /{entity}          -> create
#   GET    /{entity}/{id}   -> read
#   PATCH  /{entity}/{id}   -> update
#   DELETE /{entity}/{id}   -> delete
###############################################################################
resource "aws_api_gateway_resource" "entity_collection" {
  for_each    = toset(var.entity_types)
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = each.key
}

resource "aws_api_gateway_resource" "entity_item" {
  for_each    = toset(var.entity_types)
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.entity_collection[each.key].id
  path_part   = "{id}"
}

# Cartesian product: {entity, method} -> method object for collection routes.
locals {
  entity_collection_pairs = {
    for pair in setproduct(var.entity_types, local.entity_collection_methods) :
    "${pair[0]}__${pair[1]}" => { entity = pair[0], method = pair[1] }
  }
  entity_item_pairs = {
    for pair in setproduct(var.entity_types, local.entity_item_methods) :
    "${pair[0]}__${pair[1]}" => { entity = pair[0], method = pair[1] }
  }
}

resource "aws_api_gateway_method" "entity_collection" {
  for_each      = local.entity_collection_pairs
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.entity_collection[each.value.entity].id
  http_method   = each.value.method
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.tenant.id
}

resource "aws_api_gateway_method" "entity_item" {
  for_each      = local.entity_item_pairs
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.entity_item[each.value.entity].id
  http_method   = each.value.method
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.tenant.id

  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "entity_collection" {
  for_each = local.entity_collection_pairs

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.entity_collection[each.value.entity].id
  http_method             = aws_api_gateway_method.entity_collection[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.business_lambdas[each.value.entity].invoke_arn
  timeout_milliseconds    = 29000
}

resource "aws_api_gateway_integration" "entity_item" {
  for_each = local.entity_item_pairs

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.entity_item[each.value.entity].id
  http_method             = aws_api_gateway_method.entity_item[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.business_lambdas[each.value.entity].invoke_arn
  timeout_milliseconds    = 29000
}

resource "aws_lambda_permission" "entity" {
  for_each      = toset(var.entity_types)
  statement_id  = "AllowAPIGatewayInvokeEntity-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = var.business_lambdas[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

###############################################################################
# /users routes (authenticated, admin-only — enforced in handler).
###############################################################################
resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "users"
}

resource "aws_api_gateway_resource" "users_id" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "{id}"
}

resource "aws_api_gateway_method" "users_get" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.tenant.id
}

resource "aws_api_gateway_method" "users_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.tenant.id
}

resource "aws_api_gateway_method" "users_delete" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.users_id.id
  http_method   = "DELETE"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.tenant.id

  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "users_get" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.users.id
  http_method             = aws_api_gateway_method.users_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.business_lambdas["users"].invoke_arn
  timeout_milliseconds    = 29000
}

resource "aws_api_gateway_integration" "users_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.users.id
  http_method             = aws_api_gateway_method.users_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.business_lambdas["users"].invoke_arn
  timeout_milliseconds    = 29000
}

resource "aws_api_gateway_integration" "users_delete" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.users_id.id
  http_method             = aws_api_gateway_method.users_delete.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.business_lambdas["users"].invoke_arn
  timeout_milliseconds    = 29000
}

resource "aws_lambda_permission" "users" {
  statement_id  = "AllowAPIGatewayInvokeUsers"
  action        = "lambda:InvokeFunction"
  function_name = var.business_lambdas["users"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

###############################################################################
# Request validation: reject malformed bodies at the edge.
###############################################################################
resource "aws_api_gateway_request_validator" "body" {
  name                        = "validate-body"
  rest_api_id                 = aws_api_gateway_rest_api.this.id
  validate_request_body       = true
  validate_request_parameters = true
}

###############################################################################
# Deployment + stage.
###############################################################################
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(local.redeploy_inputs)
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.tenants_signup,
    aws_api_gateway_integration.entity_collection,
    aws_api_gateway_integration.entity_item,
    aws_api_gateway_integration.users_get,
    aws_api_gateway_integration.users_post,
    aws_api_gateway_integration.users_delete,
  ]
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${local.api_name}/${local.stage_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_stage" "this" {
  stage_name           = local.stage_name
  rest_api_id          = aws_api_gateway_rest_api.this.id
  deployment_id        = aws_api_gateway_deployment.this.id
  xray_tracing_enabled = true

  # Account-level CloudWatch role must exist before access logging works.
  depends_on = [aws_api_gateway_account.this]

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      userAgent      = "$context.identity.userAgent"
      integration    = "$context.integrationLatency"
      latency        = "$context.responseLatency"
      tenantId       = "$context.authorizer.tenant_id"
      role           = "$context.authorizer.role"
      principalId    = "$context.authorizer.principalId"
    })
  }
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "INFO"
    data_trace_enabled     = false # NEVER true in prod (logs full request bodies, including JWTs)
    throttling_burst_limit = var.throttling_burst_limit
    throttling_rate_limit  = var.throttling_rate_limit
  }
}

###############################################################################
# Optional: custom domain + ACM.
###############################################################################
resource "aws_acm_certificate" "this" {
  count             = var.enable_custom_domain ? 1 : 0
  domain_name       = var.custom_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_route53_zone" "this" {
  count        = var.enable_custom_domain ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.enable_custom_domain ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "this" {
  count                   = var.enable_custom_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_api_gateway_domain_name" "this" {
  count                    = var.enable_custom_domain ? 1 : 0
  domain_name              = var.custom_domain
  regional_certificate_arn = aws_acm_certificate_validation.this[0].certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "this" {
  count       = var.enable_custom_domain ? 1 : 0
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this[0].domain_name
}

resource "aws_route53_record" "alias" {
  count   = var.enable_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.custom_domain
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.this[0].regional_domain_name
    zone_id                = aws_api_gateway_domain_name.this[0].regional_zone_id
    evaluate_target_health = false
  }
}

###############################################################################
# Optional: WAFv2 web ACL.
###############################################################################
resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0
  name  = "${local.api_name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.api_name}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_api_gateway_stage.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
