/**
 * service-roles — Outputs
 */

output "kafka_connect_role_arn" {
  description = "ARN of the Kafka Connect IRSA IAM role"
  value       = aws_iam_role.kafka_connect.arn
}

output "kafka_connect_role_name" {
  description = "Name of the Kafka Connect IRSA IAM role"
  value       = aws_iam_role.kafka_connect.name
}
