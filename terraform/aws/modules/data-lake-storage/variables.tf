/**
 * data-lake-storage — Variables
 *
 * Inputs for S3 buckets, KMS keys, lifecycle rules, and access controls.
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "allowed_principal_arns" {
  description = "IAM role ARNs or ArnLike patterns allowed direct S3 access (bypassing Lake Formation deny). Supports wildcards for SSO-generated roles."
  type        = list(string)

  validation {
    condition     = length(var.allowed_principal_arns) > 0
    error_message = "At least one principal ARN must be provided for direct S3 access."
  }
}

variable "raw_ia_transition_days" {
  description = "Days before transitioning raw layer to STANDARD_IA (0 = disabled)"
  type        = number
  default     = 90

  validation {
    condition     = var.raw_ia_transition_days >= 0
    error_message = "raw_ia_transition_days must be >= 0."
  }
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
