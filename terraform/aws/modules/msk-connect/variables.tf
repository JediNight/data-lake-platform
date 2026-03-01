variable "environment" {
  type = string
}

variable "msk_cluster_arn" {
  description = "MSK cluster ARN"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK IAM bootstrap brokers connection string"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for connectors"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for connectors"
  type        = list(string)
}

variable "mnpi_bucket_arn" {
  description = "S3 bucket ARN for MNPI Iceberg data"
  type        = string
}

variable "nonmnpi_bucket_arn" {
  description = "S3 bucket ARN for non-MNPI Iceberg data"
  type        = string
}

variable "kafka_connect_role_arn" {
  description = "IAM role ARN for Kafka Connect execution"
  type        = string
}

variable "postgres_endpoint" {
  description = "Aurora PostgreSQL endpoint for Debezium"
  type        = string
}

variable "postgres_port" {
  description = "Aurora PostgreSQL port"
  type        = number
  default     = 5432
}

variable "debezium_version" {
  description = "Debezium connector version"
  type        = string
  default     = "2.5.0.Final"
}

variable "iceberg_connector_version" {
  description = "Iceberg sink connector version"
  type        = string
  default     = "0.6.19"
}
