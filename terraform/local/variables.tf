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

variable "project_path" {
  description = "Absolute path to data-lake-platform directory (mounted into Kind nodes)"
  type        = string
  default     = "/Users/toksfawibe/Documents/claude-agent-workspace/data-lake-platform"
}

variable "sops_age_key_file" {
  description = "Path to SOPS age key file for secret decryption"
  type        = string
  default     = "~/.config/sops/age/keys.txt"
}
