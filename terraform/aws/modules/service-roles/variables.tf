/**
 * service-roles — Variables
 *
 * Inputs for machine identity IAM roles (Kafka Connect IRSA).
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "mnpi_bucket_arn" {
  description = "ARN of the MNPI data lake S3 bucket"
  type        = string
}

variable "nonmnpi_bucket_arn" {
  description = "ARN of the non-MNPI data lake S3 bucket"
  type        = string
}

variable "glue_registry_arn" {
  description = "ARN of the Glue Schema Registry"
  type        = string
}

variable "msk_cluster_arn" {
  description = "ARN of the MSK cluster for Kafka Connect IAM auth"
  type        = string
  default     = ""
}

variable "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA"
  type        = string
  default     = ""
}

variable "eks_oidc_provider_url" {
  description = "EKS OIDC provider URL (without https://)"
  type        = string
  default     = ""
}

variable "kafka_connect_namespace" {
  description = "Kubernetes namespace where KafkaConnect pods run"
  type        = string
  default     = "strimzi"
}

variable "kafka_connect_service_account" {
  description = "Kubernetes service account name for KafkaConnect pods"
  type        = string
  default     = "data-lake-connect"
}

variable "mnpi_kms_key_arn" {
  description = "ARN of the KMS CMK for MNPI zone encryption"
  type        = string
}

variable "nonmnpi_kms_key_arn" {
  description = "ARN of the KMS CMK for non-MNPI zone encryption"
  type        = string
}

variable "query_results_bucket_arn" {
  description = "ARN of the query results bucket (used for Glue ETL scripts)"
  type        = string
}

variable "aurora_secret_arn" {
  description = "ARN of the Aurora master password Secrets Manager secret (for Debezium CDC)"
  type        = string
  default     = ""
}

variable "extra_s3_read_bucket_arns" {
  description = "Additional S3 bucket ARNs the Glue ETL role needs read access to (e.g. local Iceberg dev bucket)"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
