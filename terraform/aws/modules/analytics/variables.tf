/**
 * analytics -- Variables
 *
 * Inputs for Athena workgroup configuration including scan limits,
 * result encryption, and query result reuse settings.
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "query_results_bucket_id" {
  description = "S3 bucket ID (name) for Athena query results"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encrypting query results (SSE-KMS)"
  type        = string
}

variable "athena_scan_limit_bytes" {
  description = "Max bytes per query scan for analyst workgroups (0 = unlimited)"
  type        = number
  default     = 10737418240 # 10 GB
}

variable "enable_result_reuse" {
  description = "Enable Athena query result reuse (recommended for prod only)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
