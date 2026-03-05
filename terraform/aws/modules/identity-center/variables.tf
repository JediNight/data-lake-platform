/**
 * identity-center — Variables
 *
 * Inputs for Identity Center groups, permission sets, and demo users.
 * Bucket ARNs are needed for permission set inline policies.
 */

variable "environment" {
  description = "Environment or deployment context (dev, prod, shared)"
  type        = string
}

variable "mnpi_bucket_arn" {
  description = "ARN of the MNPI data lake S3 bucket (for DataEngineer S3 policy)"
  type        = string
}

variable "nonmnpi_bucket_arn" {
  description = "ARN of the non-MNPI data lake S3 bucket (for DataEngineer S3 policy)"
  type        = string
}

variable "query_results_bucket_arn" {
  description = "ARN of the Athena query results S3 bucket"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
