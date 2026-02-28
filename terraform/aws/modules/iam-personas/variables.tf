/**
 * iam-personas — Variables
 *
 * Inputs for IAM persona roles (console users) and the Kafka Connect
 * IRSA service role. Bucket ARNs, Glue registry, MSK cluster, and
 * EKS OIDC provider details are passed in from the root module.
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
  description = "AWS account ID for trust policies"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
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

variable "query_results_bucket_arn" {
  description = "ARN of the Athena query results S3 bucket"
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

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
