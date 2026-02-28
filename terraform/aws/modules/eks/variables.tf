variable "environment" {
  type = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for EKS control plane and nodes"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID for security groups"
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for managed node group"
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Desired number of nodes in managed node group"
  type        = number
  default     = 2
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.29"
}
