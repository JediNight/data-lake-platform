output "argocd_admin_password" {
  description = "ArgoCD admin password"
  value       = data.kubernetes_secret_v1.argocd_admin.data["password"]
  sensitive   = true
}

output "argocd_url" {
  description = "ArgoCD UI URL"
  value       = "http://localhost:8080"
}

output "kubeconfig_path" {
  description = "Path to kubeconfig"
  value       = kind_cluster.this.kubeconfig_path
}

data "kubernetes_secret_v1" "argocd_admin" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = var.argocd_namespace
  }
}
