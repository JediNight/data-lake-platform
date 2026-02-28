/**
 * iam-personas — Outputs
 *
 * Exposes role ARNs and names for downstream modules:
 *   - data-lake-storage: allowed_principal_arns (data-engineer + kafka-connect)
 *   - lake-formation:    LF-Tag grants per persona
 *   - analytics:         Athena workgroup permissions
 */

# =============================================================================
# Finance Analyst Role
# =============================================================================

output "finance_analyst_role_arn" {
  description = "ARN of the finance analyst IAM role"
  value       = aws_iam_role.finance_analyst.arn
}

output "finance_analyst_role_name" {
  description = "Name of the finance analyst IAM role"
  value       = aws_iam_role.finance_analyst.name
}

# =============================================================================
# Data Analyst Role
# =============================================================================

output "data_analyst_role_arn" {
  description = "ARN of the data analyst IAM role"
  value       = aws_iam_role.data_analyst.arn
}

output "data_analyst_role_name" {
  description = "Name of the data analyst IAM role"
  value       = aws_iam_role.data_analyst.name
}

# =============================================================================
# Data Engineer Role
# =============================================================================

output "data_engineer_role_arn" {
  description = "ARN of the data engineer IAM role"
  value       = aws_iam_role.data_engineer.arn
}

output "data_engineer_role_name" {
  description = "Name of the data engineer IAM role"
  value       = aws_iam_role.data_engineer.name
}

# =============================================================================
# Kafka Connect IRSA Role
# =============================================================================

output "kafka_connect_role_arn" {
  description = "ARN of the Kafka Connect IRSA IAM role"
  value       = aws_iam_role.kafka_connect.arn
}

output "kafka_connect_role_name" {
  description = "Name of the Kafka Connect IRSA IAM role"
  value       = aws_iam_role.kafka_connect.name
}
