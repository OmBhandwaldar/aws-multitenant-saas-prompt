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

locals {
  function_name = "${var.project_name}-${var.environment}-tenant-signup"
  source_dir    = abspath("${path.root}/../../src/tenant_signup")
  shared_dir    = abspath("${path.root}/../../src/shared")
  build_dir     = "${path.module}/.build/tenant_signup"
}

resource "null_resource" "build" {
  triggers = {
    requirements   = filesha256("${local.source_dir}/requirements.txt")
    handler        = filesha256("${local.source_dir}/handler.py")
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

data "archive_file" "signup" {
  type        = "zip"
  source_dir  = local.build_dir
  output_path = "${path.module}/.build/tenant_signup.zip"
  depends_on  = [null_resource.build]
}

###############################################################################
# Execution role.
# Privileged-but-narrow: this Lambda is the only one that:
#  - creates Cognito users (admin API)
#  - writes the tenant META + admin USER records to the app table directly
#    (without going through the per-request tenant credentials, because there
#    is no JWT yet).
###############################################################################
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "inline" {
  statement {
    sid = "CognitoAdminCreate"
    actions = [
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminSetUserPassword",
      "cognito-idp:AdminUpdateUserAttributes",
      "cognito-idp:AdminConfirmSignUp",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminDeleteUser",
    ]
    resources = ["arn:aws:cognito-idp:*:${data.aws_caller_identity.current.account_id}:userpool/${var.user_pool_id}"]
  }

  statement {
    sid = "WriteTenantSignupRecords"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:TransactWriteItems",
    ]
    resources = [var.app_table_arn]
  }
}

resource "aws_iam_role_policy" "inline" {
  name   = "${local.function_name}-inline"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.inline.json
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name                  = local.function_name
  role                           = aws_iam_role.this.arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.signup.output_path
  source_code_hash               = data.archive_file.signup.output_base64sha256
  memory_size                    = 256
  timeout                        = 15
  architectures                  = ["x86_64"]
  reserved_concurrent_executions = var.reserved_concurrency

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      PROJECT_NAME            = var.project_name
      ENVIRONMENT             = var.environment
      USER_POOL_ID            = var.user_pool_id
      USER_POOL_CLIENT_ID     = var.user_pool_client_id
      APP_TABLE_NAME          = var.app_table_name
      AUTO_CONFIRM_SIGNUPS    = var.auto_confirm_signups ? "true" : "false"
      POWERTOOLS_SERVICE_NAME = "saas-tenant-signup"
      POWERTOOLS_LOG_LEVEL    = var.log_level
      LOG_LEVEL               = var.log_level
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy.inline,
    aws_iam_role_policy_attachment.basic,
    aws_iam_role_policy_attachment.xray,
  ]
}
