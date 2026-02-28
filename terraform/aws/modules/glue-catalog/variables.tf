/**
 * glue-catalog -- Variables
 *
 * Inputs for Glue Catalog databases and Schema Registry.
 * The bucket IDs come from the data-lake-storage module.
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "mnpi_bucket_id" {
  description = "S3 bucket ID (name) for the MNPI data lake zone"
  type        = string
}

variable "nonmnpi_bucket_id" {
  description = "S3 bucket ID (name) for the non-MNPI data lake zone"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
