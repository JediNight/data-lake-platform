/**
 * observability -- Variables
 *
 * Inputs for CloudTrail, CloudWatch, Glue audit table, and optional
 * QuickSight resources.  Bucket ARNs/IDs come from data-lake-storage.
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "account_id" {
  description = "AWS account ID (used in CloudTrail S3 prefix and bucket policy conditions)"
  type        = string
}

variable "mnpi_bucket_arn" {
  description = "ARN of the MNPI data lake bucket (for S3 data event selectors)"
  type        = string
}

variable "nonmnpi_bucket_arn" {
  description = "ARN of the non-MNPI data lake bucket (for S3 data event selectors)"
  type        = string
}

variable "audit_bucket_arn" {
  description = "ARN of the audit/CloudTrail bucket"
  type        = string
}

variable "audit_bucket_id" {
  description = "ID (name) of the audit/CloudTrail bucket"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Log Group retention in days"
  type        = number
  default     = 90
}

variable "enable_quicksight" {
  description = "Whether to create QuickSight resources (account subscription + data source)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
