output "function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.simulator.function_name
}

output "function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.simulator.arn
}

output "eventbridge_rule_name" {
  description = "EventBridge schedule rule name"
  value       = aws_cloudwatch_event_rule.schedule.name
}
