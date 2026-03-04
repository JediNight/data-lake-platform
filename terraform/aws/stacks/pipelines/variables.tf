variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

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
