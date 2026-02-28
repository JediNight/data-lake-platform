/**
 * lake-formation -- Variables
 *
 * Inputs for LF-Tags, tag-based grants, S3 location registrations,
 * and Lake Formation admin settings.
 */

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "database_names" {
  description = "Map of logical name to Glue database name (from glue-catalog module)"
  type        = map(string)
}

variable "mnpi_bucket_arn" {
  description = "ARN of the MNPI data lake S3 bucket"
  type        = string
}

variable "nonmnpi_bucket_arn" {
  description = "ARN of the non-MNPI data lake S3 bucket"
  type        = string
}

variable "finance_analyst_role_arn" {
  description = "ARN of the finance analyst IAM role"
  type        = string
}

variable "data_analyst_role_arn" {
  description = "ARN of the data analyst IAM role"
  type        = string
}

variable "data_engineer_role_arn" {
  description = "ARN of the data engineer IAM role"
  type        = string
}

variable "admin_role_arn" {
  description = "IAM role ARN for Lake Formation admin"
  type        = string
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
