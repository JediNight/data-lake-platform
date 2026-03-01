/**
 * data-lake-storage — Outputs
 *
 * Exposes bucket ARNs/IDs and KMS key ARNs for downstream modules
 * (Lake Formation, Glue, IAM personas, streaming).
 */

# =============================================================================
# MNPI Data Lake Bucket
# =============================================================================

output "mnpi_bucket_arn" {
  description = "ARN of the MNPI data lake bucket"
  value       = aws_s3_bucket.mnpi.arn
}

output "mnpi_bucket_id" {
  description = "ID (name) of the MNPI data lake bucket"
  value       = aws_s3_bucket.mnpi.id
}

# =============================================================================
# Non-MNPI Data Lake Bucket
# =============================================================================

output "nonmnpi_bucket_arn" {
  description = "ARN of the non-MNPI data lake bucket"
  value       = aws_s3_bucket.nonmnpi.arn
}

output "nonmnpi_bucket_id" {
  description = "ID (name) of the non-MNPI data lake bucket"
  value       = aws_s3_bucket.nonmnpi.id
}

# =============================================================================
# Audit Bucket
# =============================================================================

output "audit_bucket_arn" {
  description = "ARN of the audit/CloudTrail bucket"
  value       = aws_s3_bucket.audit.arn
}

output "audit_bucket_id" {
  description = "ID (name) of the audit/CloudTrail bucket"
  value       = aws_s3_bucket.audit.id
}

# =============================================================================
# Query Results Bucket
# =============================================================================

output "query_results_bucket_arn" {
  description = "ARN of the Athena query results bucket"
  value       = aws_s3_bucket.query_results.arn
}

output "query_results_bucket_id" {
  description = "ID (name) of the Athena query results bucket"
  value       = aws_s3_bucket.query_results.id
}

# =============================================================================
# KMS Keys
# =============================================================================

output "mnpi_kms_key_arn" {
  description = "ARN of the KMS CMK for MNPI zone encryption"
  value       = aws_kms_key.mnpi.arn
}

output "nonmnpi_kms_key_arn" {
  description = "ARN of the KMS CMK for non-MNPI zone encryption"
  value       = aws_kms_key.nonmnpi.arn
}
