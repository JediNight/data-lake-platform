variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "admin_role_arn" {
  description = "IAM role ARN for Lake Formation admin (defaults to current caller)"
  type        = string
  default     = ""
}

# Local dev variables (Kind cluster — dev workspace only)
variable "kind_cluster_name" {
  description = "Name of the Kind cluster for local dev"
  type        = string
  default     = "data-lake"
}

variable "kubeconfig_path" {
  description = "Path to save Kind kubeconfig"
  type        = string
  default     = "~/.kube/config"
}
