variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "broker_instance_type" {
  type    = string
  default = "kafka.t3.small"
}

variable "broker_count" {
  type    = number
  default = 1
}

variable "default_replication_factor" {
  type    = number
  default = 1
}

variable "raw_ia_transition_days" {
  type    = number
  default = 0 # Disabled in dev
}

variable "athena_scan_limit_bytes" {
  type    = number
  default = 10737418240 # 10GB
}

variable "enable_result_reuse" {
  type    = bool
  default = false
}

variable "enable_quicksight" {
  type    = bool
  default = false
}

variable "audit_retention_days" {
  type    = number
  default = 90
}

variable "eks_oidc_provider_arn" {
  type    = string
  default = ""
}

variable "eks_oidc_provider_url" {
  type    = string
  default = ""
}

variable "admin_role_arn" {
  description = "IAM role ARN for Lake Formation admin"
  type        = string
}
