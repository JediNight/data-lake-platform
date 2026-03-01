output "api_endpoint" {
  description = "API Gateway endpoint URL"
  value       = aws_apigatewayv2_api.producer.api_endpoint
}

output "function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.producer.function_name
}

output "function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.producer.arn
}
