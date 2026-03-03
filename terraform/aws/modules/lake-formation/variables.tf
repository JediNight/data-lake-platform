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

variable "admin_role_arn" {
  description = "IAM role ARN for Lake Formation admin"
  type        = string
}

variable "sso_instance_arn" {
  description = "IAM Identity Center instance ARN for Trusted Identity Propagation"
  type        = string
}

variable "glue_etl_role_arn" {
  description = "ARN of the Glue ETL IAM role (for database/table permissions)"
  type        = string
}

variable "kafka_connect_role_arn" {
  description = "ARN of the Kafka Connect IAM role (for Iceberg sink LF permissions)"
  type        = string
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
