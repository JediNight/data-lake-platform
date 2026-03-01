/**
 * streaming -- Variables
 *
 * Inputs for MSK Provisioned cluster configuration. Dev and prod differ
 * primarily in broker_instance_type (t3.small vs m5.large), broker_count
 * (1 vs 3), and default_replication_factor (1 vs 3).
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "broker_instance_type" {
  description = "MSK broker instance type (dev: kafka.t3.small, prod: kafka.m5.large)"
  type        = string
  default     = "kafka.t3.small"
}

variable "broker_count" {
  description = "Number of MSK broker nodes (must be a multiple of the number of subnets)"
  type        = number
  default     = 1

  validation {
    condition     = var.broker_count >= 1
    error_message = "Broker count must be at least 1."
  }
}

variable "broker_ebs_volume_size" {
  description = "EBS volume size in GiB per broker (min 1, max 16384)"
  type        = number
  default     = 100

  validation {
    condition     = var.broker_ebs_volume_size >= 1 && var.broker_ebs_volume_size <= 16384
    error_message = "EBS volume size must be between 1 and 16384 GiB."
  }
}

variable "kafka_version" {
  description = "Apache Kafka version for the MSK cluster"
  type        = string
  default     = "3.6.0"
}

variable "subnet_ids" {
  description = "List of private subnet IDs for MSK broker placement (from networking module)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one subnet ID is required."
  }
}

variable "msk_security_group_id" {
  description = "Security group ID for MSK brokers (from networking module)"
  type        = string
}

variable "default_replication_factor" {
  description = "Default replication factor for auto-created topics (dev: 1, prod: 3)"
  type        = number
  default     = 1

  validation {
    condition     = var.default_replication_factor >= 1 && var.default_replication_factor <= 5
    error_message = "Replication factor must be between 1 and 5."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption at rest (null = AWS managed key)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
