/**
 * lake-formation -- Variables
 *
 * Inputs for LF-Tags, tag-based grants, S3 location registrations,
 * Lake Formation admin settings, and Identity Center configuration.
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

variable "finance_analysts_group_id" {
  description = "Identity Center group ID for finance analysts"
  type        = string
}

variable "data_analysts_group_id" {
  description = "Identity Center group ID for data analysts"
  type        = string
}

variable "data_engineers_group_id" {
  description = "Identity Center group ID for data engineers"
  type        = string
}

variable "sso_instance_arn" {
  description = "SSO instance ARN for Lake Formation IC configuration"
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
