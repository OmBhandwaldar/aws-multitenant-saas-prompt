terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  function_name             = "${var.project_name}-${var.environment}-authorizer"
  tenant_access_role_name   = "${var.project_name}-${var.environment}-tenant-access"
  authorizer_role_name      = "${local.function_name}-role"
  source_dir                = abspath("${path.root}/../../src/authorizer")
  shared_dir                = abspath("${path.root}/../../src/shared")
  build_dir                 = "${path.module}/.build/authorizer"
}

###############################################################################
# Lambda packaging.
###############################################################################
resource "null_resource" "build" {
  triggers = {
    requirements = filesha256("${local.source_dir}/requirements.txt")
    handler      = filesha256("${local.source_dir}/handler.py")
    shared_auth    = filesha256("${local.shared_dir}/auth.py")
    shared_ddb     = filesha256("${local.shared_dir}/ddb.py")
    shared_logging = filesha256("${local.shared_dir}/logging.py")
    shared_metrics = filesha256("${local.shared_dir}/metrics.py")
    shared_init    = filesha256("${local.shared_dir}/__init__.py")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      rm -rf "${local.build_dir}"
      mkdir -p "${local.build_dir}"
      cp "${local.source_dir}/handler.py" "${local.build_dir}/"
      cp -r "${local.shared_dir}" "${local.build_dir}/shared"
      pip install --quiet \
        --target "${local.build_dir}" \
        --platform manylinux2014_x86_64 \
        --implementation cp \
        --python-version 3.12 \
        --only-binary=:all: \
        --upgrade \
        -r "${local.source_dir}/requirements.txt"
    EOT
  }
}

data "archive_file" "authorizer" {
  type        = "zip"
  source_dir  = local.build_dir
  output_path = "${path.module}/.build/authorizer.zip"
  depends_on  = [null_resource.build]
}

###############################################################################
# TenantAccessRole — the role the authorizer assumes per request.
#
# Trust policy: ONLY the authorizer Lambda's role may assume.
# Permission policy: DynamoDB read/write on the app table and its indexes only.
# Per-request session policy (injected via sts:AssumeRole) further restricts
# the credentials to a single tenant via dynamodb:LeadingKeys.
###############################################################################
data "aws_iam_policy_document" "tenant_access_trust" {
  statement {
    sid     = "AuthorizerLambdaAssume"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.authorizer_lambda.arn]
    }
  }
}

resource "aws_iam_role" "tenant_access" {
  name               = local.tenant_access_role_name
  assume_role_policy = data.aws_iam_policy_document.tenant_access_trust.json
  description        = "Assumed per-request by the authorizer Lambda. Session policy further restricts to one tenant."

  # Allow up to 1h sessions even though dev uses 15 min.
  max_session_duration = 3600
}

data "aws_iam_policy_document" "tenant_access_inline" {
  statement {
    sid = "TenantScopedDynamoDB"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:TransactWriteItems",
      "dynamodb:TransactGetItems",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [
      var.app_table_arn,
      "${var.app_table_arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "tenant_access_inline" {
  name   = "${local.tenant_access_role_name}-inline"
  role   = aws_iam_role.tenant_access.id
  policy = data.aws_iam_policy_document.tenant_access_inline.json
}

###############################################################################
# Authorizer Lambda's execution role.
# - sts:AssumeRole on the TenantAccessRole only.
# - Basic execution + X-Ray.
###############################################################################
data "aws_iam_policy_document" "authorizer_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "authorizer_lambda" {
  name               = local.authorizer_role_name
  assume_role_policy = data.aws_iam_policy_document.authorizer_assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.authorizer_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.authorizer_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "authorizer_inline" {
  statement {
    sid       = "AssumeTenantAccessRole"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = [aws_iam_role.tenant_access.arn]
  }
}

resource "aws_iam_role_policy" "authorizer_inline" {
  name   = "${local.authorizer_role_name}-inline"
  role   = aws_iam_role.authorizer_lambda.id
  policy = data.aws_iam_policy_document.authorizer_inline.json
}

###############################################################################
# Log group.
###############################################################################
resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

###############################################################################
# Lambda function.
###############################################################################
resource "aws_lambda_function" "authorizer" {
  function_name                  = local.function_name
  role                           = aws_iam_role.authorizer_lambda.arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.authorizer.output_path
  source_code_hash               = data.archive_file.authorizer.output_base64sha256
  memory_size                    = 512
  timeout                        = 10
  architectures                  = ["x86_64"]
  reserved_concurrent_executions = var.reserved_concurrency

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      PROJECT_NAME            = var.project_name
      ENVIRONMENT             = var.environment
      AWS_REGION_NAME         = var.aws_region
      USER_POOL_ID            = var.user_pool_id
      USER_POOL_CLIENT_ID     = var.user_pool_client_id
      TENANT_ACCESS_ROLE_ARN  = aws_iam_role.tenant_access.arn
      APP_TABLE_ARN           = var.app_table_arn
      STS_DURATION_SECONDS    = tostring(var.sts_duration_seconds)
      POWERTOOLS_SERVICE_NAME = "saas-authorizer"
      POWERTOOLS_LOG_LEVEL    = var.log_level
      LOG_LEVEL               = var.log_level
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.authorizer,
    aws_iam_role_policy.authorizer_inline,
    aws_iam_role_policy_attachment.basic,
    aws_iam_role_policy_attachment.xray,
  ]
}
