/**
 * glue-etl — Variables
 *
 * Inputs for Glue ETL jobs, workflow, and script uploads.
 * IAM role lives in service-roles module (not here).
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "glue_role_arn" {
  description = "IAM role ARN for Glue jobs (from service-roles module)"
  type        = string
}

variable "scripts_bucket_id" {
  description = "S3 bucket ID for Glue scripts (query-results bucket, no DENY policy)"
  type        = string
}

variable "worker_count" {
  description = "Number of Glue workers per job"
  type        = number
  default     = 2
}

variable "schedule_expression" {
  description = "Cron expression for the start trigger (empty string = ON_DEMAND)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
