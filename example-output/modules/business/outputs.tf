output "lambdas" {
  description = "Map of route key -> {function_name, invoke_arn} for API Gateway wiring. Includes one entry per entity_type plus 'users'."
  value = merge(
    {
      for k, v in aws_lambda_function.entity : k => {
        function_name = v.function_name
        invoke_arn    = v.invoke_arn
      }
    },
    {
      "users" = {
        function_name = aws_lambda_function.users.function_name
        invoke_arn    = aws_lambda_function.users.invoke_arn
      }
    },
  )
}

output "function_names" {
  description = "Map of route key -> Lambda function name."
  value = merge(
    { for k, v in aws_lambda_function.entity : k => v.function_name },
    { "users" = aws_lambda_function.users.function_name },
  )
}
