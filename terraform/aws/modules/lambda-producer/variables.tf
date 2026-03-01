variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for Lambda VPC attachment"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security group ID for Lambda"
  type        = string
}

variable "msk_cluster_arn" {
  description = "MSK cluster ARN (for IAM policy)"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK IAM bootstrap broker string"
  type        = string
}

variable "postgres_dsn" {
  description = "Aurora PostgreSQL connection string"
  type        = string
}

variable "aurora_secret_arn" {
  description = "Secrets Manager ARN for Aurora master password"
  type        = string
}

variable "lambda_zip_path" {
  description = "Path to the Lambda deployment ZIP"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
