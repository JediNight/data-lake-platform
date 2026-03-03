variable "cluster_name" {
  description = "Name of the Kind cluster"
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to Kind kubeconfig (written by kind_cluster resource in root)"
  type        = string
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

variable "sops_age_key_file" {
  description = "Path to SOPS age key file for secret decryption"
  type        = string
  default     = "~/.config/sops/age/keys.txt"
}
