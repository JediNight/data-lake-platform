/**
 * Local Dev — ArgoCD + Strimzi bootstrap
 *
 * Deploys into the Kind cluster created by the root module.
 * ArgoCD takes over and manages all ApplicationSets from dev/gitops/.
 */

terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    kubectl = {
      source = "gavinbunney/kubectl"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}

# =============================================================================
# Local Path Provisioner (storage for PVCs)
# =============================================================================

resource "null_resource" "local_path_provisioner" {
  provisioner "local-exec" {
    command = <<-EOF
      kubectl --kubeconfig=${var.kubeconfig_path} \
        apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
      kubectl --kubeconfig=${var.kubeconfig_path} \
        patch storageclass local-path \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    EOF
  }
}

# =============================================================================
# ArgoCD
# =============================================================================

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.argocd_namespace
    labels = {
      "app.kubernetes.io/name"    = "argocd"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }
}

resource "kubernetes_secret_v1" "sops_age_key" {
  metadata {
    name      = "sops-age-key"
    namespace = var.argocd_namespace
  }

  data = {
    "keys.txt" = file(pathexpand(var.sops_age_key_file))
  }

  depends_on = [kubernetes_namespace_v1.argocd]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  version    = var.argocd_chart_version

  values = [file("${path.module}/argocd-values.yaml")]

  depends_on = [
    kubernetes_namespace_v1.argocd,
    null_resource.local_path_provisioner,
    kubernetes_secret_v1.sops_age_key,
  ]
}

resource "null_resource" "wait_for_argocd" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = <<-EOF
      echo "Waiting for ArgoCD to be ready..."
      kubectl --kubeconfig=${var.kubeconfig_path} \
        wait --for=condition=available deployment/argocd-server \
        -n ${var.argocd_namespace} --timeout=300s
      kubectl --kubeconfig=${var.kubeconfig_path} \
        wait --for=condition=available deployment/argocd-repo-server \
        -n ${var.argocd_namespace} --timeout=300s
      kubectl --kubeconfig=${var.kubeconfig_path} \
        rollout status statefulset/argocd-application-controller \
        -n ${var.argocd_namespace} --timeout=300s
      echo "ArgoCD is ready!"
    EOF
  }
}

resource "kubectl_manifest" "appset_management" {
  depends_on = [null_resource.wait_for_argocd]

  yaml_body = file("${path.module}/../../../../dev/appset-management.yaml")
}
