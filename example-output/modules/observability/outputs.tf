output "sns_topic_arn" {
  value       = aws_sns_topic.alarms.arn
  description = "SNS topic ARN for alarm notifications."
}

output "dashboard_name" {
  value       = aws_cloudwatch_dashboard.tenants.dashboard_name
  description = "CloudWatch dashboard name."
}
