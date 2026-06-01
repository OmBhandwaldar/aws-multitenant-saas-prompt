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
  topic_name           = "${var.project_name}-${var.environment}-alarms"
  custom_metrics_ns    = "${var.project_name}/${var.environment}"
  all_business_lambdas = var.business_function_names
}

###############################################################################
# SNS topic for alarms.
###############################################################################
resource "aws_sns_topic" "alarms" {
  name              = local.topic_name
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# Per-Lambda error-rate alarms (authorizer + tenant_signup + every business Lambda).
###############################################################################
resource "aws_cloudwatch_metric_alarm" "authorizer_401" {
  alarm_name          = "${var.project_name}-${var.environment}-authorizer-deny-spike"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  metric_name         = "AuthorizerDeny"
  namespace           = local.custom_metrics_ns
  statistic           = "Sum"
  threshold           = 50
  alarm_description   = "Authorizer denied > 50 tokens in 5min — possible attack or misconfigured client."
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  dimensions = {
    service = "saas-authorizer"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each            = merge({ tenant_signup = var.tenant_signup_function_name, authorizer = var.authorizer_function_name }, local.all_business_lambdas)
  alarm_name          = "${var.project_name}-${var.environment}-${each.key}-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  alarm_description   = "${each.key} Lambda error rate > 1% over 5 minutes"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id          = "error_rate"
    expression  = "100 * errors / IF(invocations > 0, invocations, 1)"
    label       = "Error %"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      period      = 300
      stat        = "Sum"
      dimensions  = { FunctionName = each.value }
    }
  }

  metric_query {
    id = "invocations"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Invocations"
      period      = 300
      stat        = "Sum"
      dimensions  = { FunctionName = each.value }
    }
  }
}

###############################################################################
# API Gateway 5xx alarm.
###############################################################################
resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-apigw-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  alarm_description   = "API Gateway 5xx rate > 1% over 5 minutes"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id          = "rate"
    expression  = "100 * errors / IF(count > 0, count, 1)"
    label       = "5xx %"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5XXError"
      period      = 300
      stat        = "Sum"
      dimensions  = { ApiName = var.api_name, Stage = var.api_stage_name }
    }
  }
  metric_query {
    id = "count"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      period      = 300
      stat        = "Sum"
      dimensions  = { ApiName = var.api_name, Stage = var.api_stage_name }
    }
  }
}

###############################################################################
# DynamoDB throttling alarm.
###############################################################################
resource "aws_cloudwatch_metric_alarm" "ddb_throttles" {
  alarm_name          = "${var.project_name}-${var.environment}-ddb-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  metric_name         = "ThrottledRequests"
  namespace           = "AWS/DynamoDB"
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Any DynamoDB throttling — partition hot-spot or burst beyond on-demand burst capacity."
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  dimensions          = { TableName = var.app_table_name }
}

###############################################################################
# Cognito sign-in throttle alarm.
###############################################################################
resource "aws_cloudwatch_metric_alarm" "cognito_throttle" {
  alarm_name          = "${var.project_name}-${var.environment}-cognito-throttle"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  metric_name         = "SignInThrottles"
  namespace           = "AWS/Cognito"
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Cognito sign-in throttles > 10 in 5min — possible brute-force."
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  dimensions = {
    UserPool       = var.user_pool_id
    UserPoolClient = "ALL"
  }
}

###############################################################################
# Single "tenants" dashboard. Uses metric-math against the tenant_id dimension
# emitted by every business Lambda — no per-tenant dashboard sprawl.
###############################################################################
resource "aws_cloudwatch_dashboard" "tenants" {
  dashboard_name = "${var.project_name}-${var.environment}-tenants"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway — Count / 4xx / 5xx"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", var.api_name, "Stage", var.api_stage_name],
            [".", "4XXError", ".", ".", ".", "."],
            [".", "5XXError", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Authorizer — Allow vs Deny"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            [local.custom_metrics_ns, "AuthorizerAllow", "service", "saas-authorizer"],
            [".", "AuthorizerDeny", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "Per-tenant API requests (top-10) — custom metric APIRequests"
          region = var.aws_region
          view   = "timeSeries"
          stacked = false
          period = 300
          stat   = "Sum"
          metrics = [
            for fn in values(local.all_business_lambdas) :
            [local.custom_metrics_ns, "APIRequests", "FunctionName", fn, { stat = "Sum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Errors (all functions)"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = concat(
            [["AWS/Lambda", "Errors", "FunctionName", var.authorizer_function_name]],
            [["AWS/Lambda", "Errors", "FunctionName", var.tenant_signup_function_name]],
            [for fn in values(local.all_business_lambdas) : ["AWS/Lambda", "Errors", "FunctionName", fn]],
          )
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB — consumed capacity & throttles"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.app_table_name],
            [".", "ConsumedWriteCapacityUnits", ".", "."],
            [".", "ThrottledRequests", ".", ".", { stat = "Sum" }],
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 18
        width  = 24
        height = 6
        properties = {
          title  = "Top tenants by request count (last 1h)"
          region = var.aws_region
          query  = "SOURCE '/aws/lambda/${var.authorizer_function_name}' | fields @timestamp, tenant_id | filter ispresent(tenant_id) | stats count(*) as requests by tenant_id | sort requests desc | limit 10"
          view   = "table"
        }
      },
    ]
  })
}
