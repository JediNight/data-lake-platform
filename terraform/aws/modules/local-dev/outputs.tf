output "argocd_namespace" {
  description = "ArgoCD namespace name"
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}
