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
  shared_dir = abspath("${path.root}/../../src/shared")

  # The set of Lambdas we build: one per entity_type, plus the admin-only "users" Lambda.
  entity_lambdas = {
    for e in var.entity_types : e => {
      name              = "${var.project_name}-${var.environment}-${replace(e, "_", "-")}"
      source_dir        = abspath("${path.root}/../../src/business/${e}")
      powertools_service = "saas-${replace(e, "_", "-")}"
      handler_kind      = "entity"
    }
  }

  users_lambda = {
    "users" = {
      name              = "${var.project_name}-${var.environment}-users"
      source_dir        = abspath("${path.root}/../../src/business/users")
      powertools_service = "saas-users"
      handler_kind      = "users"
    }
  }

  all_lambdas = merge(local.entity_lambdas, local.users_lambda)
}

###############################################################################
# Build artifacts (one per Lambda).
###############################################################################
resource "null_resource" "build" {
  for_each = local.all_lambdas

  triggers = {
    requirements   = filesha256("${each.value.source_dir}/requirements.txt")
    handler        = filesha256("${each.value.source_dir}/handler.py")
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
      BUILD_DIR="${path.module}/.build/${each.key}"
      rm -rf "$BUILD_DIR"
      mkdir -p "$BUILD_DIR"
      cp "${each.value.source_dir}/handler.py" "$BUILD_DIR/"
      cp -r "${local.shared_dir}" "$BUILD_DIR/shared"
      pip install --quiet \
        --target "$BUILD_DIR" \
        --platform manylinux2014_x86_64 \
        --implementation cp \
        --python-version 3.12 \
        --only-binary=:all: \
        --upgrade \
        -r "${each.value.source_dir}/requirements.txt"
    EOT
  }
}

data "archive_file" "lambda" {
  for_each = local.all_lambdas

  type        = "zip"
  source_dir  = "${path.module}/.build/${each.key}"
  output_path = "${path.module}/.build/${each.key}.zip"
  depends_on  = [null_resource.build]
}

###############################################################################
# Execution role(s).
#
# Business Lambdas do NOT have DynamoDB permissions of their own — they use
# the STS credentials returned by the authorizer. Their execution role grants
# only logging, X-Ray, and metric emission.
#
# The "users" Lambda is the exception: it needs cognito-idp:AdminCreateUser
# and AdminDeleteUser (scoped to the user pool) plus DynamoDB user-record
# writes via the tenant credentials.
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

resource "aws_iam_role" "entity" {
  for_each           = local.entity_lambdas
  name               = "${each.value.name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "entity_basic" {
  for_each   = local.entity_lambdas
  role       = aws_iam_role.entity[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "entity_xray" {
  for_each   = local.entity_lambdas
  role       = aws_iam_role.entity[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role" "users" {
  name               = "${local.users_lambda["users"].name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "users_basic" {
  role       = aws_iam_role.users.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "users_xray" {
  role       = aws_iam_role.users.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "users_inline" {
  statement {
    sid = "CognitoUserAdmin"
    actions = [
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminDeleteUser",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminUpdateUserAttributes",
      "cognito-idp:ListUsers",
    ]
    resources = ["arn:aws:cognito-idp:*:${data.aws_caller_identity.current.account_id}:userpool/${var.user_pool_id}"]
  }
}

resource "aws_iam_role_policy" "users_inline" {
  name   = "${local.users_lambda["users"].name}-inline"
  role   = aws_iam_role.users.id
  policy = data.aws_iam_policy_document.users_inline.json
}

###############################################################################
# Log groups.
###############################################################################
resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.all_lambdas
  name              = "/aws/lambda/${each.value.name}"
  retention_in_days = var.log_retention_days
}

###############################################################################
# Lambda functions.
###############################################################################
resource "aws_lambda_function" "entity" {
  for_each = local.entity_lambdas

  function_name                  = each.value.name
  role                           = aws_iam_role.entity[each.key].arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.lambda[each.key].output_path
  source_code_hash               = data.archive_file.lambda[each.key].output_base64sha256
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
      AWS_REGION_NAME         = var.aws_region
      APP_TABLE_NAME          = var.app_table_name
      ENTITY_TYPE             = each.key
      POWERTOOLS_SERVICE_NAME = each.value.powertools_service
      POWERTOOLS_LOG_LEVEL    = var.log_level
      LOG_LEVEL               = var.log_level
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.entity_basic,
    aws_iam_role_policy_attachment.entity_xray,
  ]
}

resource "aws_lambda_function" "users" {
  function_name                  = local.users_lambda["users"].name
  role                           = aws_iam_role.users.arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.lambda["users"].output_path
  source_code_hash               = data.archive_file.lambda["users"].output_base64sha256
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
      AWS_REGION_NAME         = var.aws_region
      APP_TABLE_NAME          = var.app_table_name
      USER_POOL_ID            = var.user_pool_id
      POWERTOOLS_SERVICE_NAME = local.users_lambda["users"].powertools_service
      POWERTOOLS_LOG_LEVEL    = var.log_level
      LOG_LEVEL               = var.log_level
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.users_inline,
    aws_iam_role_policy_attachment.users_basic,
    aws_iam_role_policy_attachment.users_xray,
  ]
}
