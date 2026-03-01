/**
 * observability -- Outputs
 *
 * Exposes CloudTrail ARN, CloudWatch log group name, and the Glue
 * catalog table name for Athena-based audit log queries.
 */

# =============================================================================
# CloudTrail
# =============================================================================

output "cloudtrail_arn" {
  description = "ARN of the CloudTrail trail"
  value       = aws_cloudtrail.datalake.arn
}

output "cloudtrail_log_group_name" {
  description = "Name of the CloudWatch Log Group receiving CloudTrail events"
  value       = aws_cloudwatch_log_group.cloudtrail.name
}

# =============================================================================
# Glue Audit Table (for Athena querying of CloudTrail logs)
# =============================================================================

output "cloudtrail_glue_table_name" {
  description = "Glue Catalog table name for CloudTrail logs (query via Athena)"
  value       = aws_glue_catalog_table.cloudtrail_logs.name
}
