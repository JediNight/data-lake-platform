variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be dev or prod."
  }
}

variable "subnet_ids" {
  description = "Private subnet IDs for Lambda VPC config"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security group ID for Lambda (egress to MSK + Aurora)"
  type        = string
}

variable "msk_cluster_arn" {
  description = "MSK cluster ARN for IAM policy"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK bootstrap broker string (IAM auth)"
  type        = string
}

variable "aurora_cluster_arn" {
  description = "Aurora cluster ARN for RDS Data API IAM policy"
  type        = string
}

variable "aurora_secret_arn" {
  description = "Secrets Manager secret ARN for Aurora credentials"
  type        = string
}

variable "function_zip_path" {
  description = "Path to the Lambda function ZIP file"
  type        = string
}

variable "layer_zip_path" {
  description = "Path to the Lambda layer ZIP file (pip dependencies)"
  type        = string
}

variable "schedule_enabled" {
  description = "Whether the EventBridge schedule is enabled"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
