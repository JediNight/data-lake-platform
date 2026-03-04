variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "admin_role_arn" {
  description = "IAM role ARN for Lake Formation admin (defaults to current caller)"
  type        = string
  default     = ""
}
