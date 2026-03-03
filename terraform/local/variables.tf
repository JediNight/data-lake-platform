variable "cluster_name" {
  description = "Name of the Kind cluster"
  type        = string
  default     = "data-lake"
}

variable "kubeconfig_path" {
  description = "Path to save kubeconfig"
  type        = string
  default     = "~/.kube/config"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.7.16"
}

variable "argocd_namespace" {
  description = "Namespace for ArgoCD"
  type        = string
  default     = "argocd"
}

variable "kind_node_image" {
  description = "Kind node image (pins Kubernetes version). Strimzi 0.44 requires K8s <=1.31."
  type        = string
  default     = "kindest/node:v1.31.2"
}

variable "project_path" {
  description = "Absolute path to data-lake-platform repo root (mounted into Kind nodes)"
  type        = string
  default     = null # Auto-detected from Terraform working directory
}

locals {
  project_path = coalesce(var.project_path, abspath("${path.module}/../.."))
}

variable "sops_age_key_file" {
  description = "Path to SOPS age key file for secret decryption"
  type        = string
  default     = "~/.config/sops/age/keys.txt"
}
