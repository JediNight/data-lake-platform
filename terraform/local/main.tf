/**
 * data-lake-platform GitOps Bridge
 *
 * Implements the GitOps Bridge pattern for local development:
 * Terraform creates Kind cluster → installs ArgoCD → applies root Application
 * → ArgoCD takes over and manages all ApplicationSets.
 *
 * Mirrors: iac-local/terraform/main.tf
 */

# =============================================================================
# Kind Cluster
# =============================================================================

resource "kind_cluster" "this" {
  name            = var.cluster_name
  wait_for_ready  = true
  kubeconfig_path = pathexpand(var.kubeconfig_path)

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      pod_subnet     = "10.244.0.0/16"
      service_subnet = "10.96.0.0/12"
    }

    node {
      role  = "control-plane"
      image = var.kind_node_image

      labels = {
        "ingress-ready" = "true"
      }

      extra_port_mappings {
        container_port = 30080
        host_port      = 8080
        protocol       = "TCP"
      }

      extra_mounts {
        host_path      = var.project_path
        container_path = "/mnt/data-lake-platform"
        read_only      = true
      }
    }

    node {
      role  = "worker"
      image = var.kind_node_image

      labels = {
        "workload" = "applications"
      }

      extra_mounts {
        host_path      = var.project_path
        container_path = "/mnt/data-lake-platform"
        read_only      = true
      }

      extra_mounts {
        host_path      = pathexpand("~/.aws")
        container_path = "/mnt/aws"
        read_only      = true
      }
    }
  }
}

# =============================================================================
# Local Path Provisioner (storage for PVCs)
# =============================================================================

resource "null_resource" "local_path_provisioner" {
  depends_on = [kind_cluster.this]

  provisioner "local-exec" {
    command = <<-EOF
      kubectl --kubeconfig=${kind_cluster.this.kubeconfig_path} \
        apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
      kubectl --kubeconfig=${kind_cluster.this.kubeconfig_path} \
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

  depends_on = [kind_cluster.this]
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
      kubectl --kubeconfig=${kind_cluster.this.kubeconfig_path} \
        wait --for=condition=available deployment/argocd-server \
        -n ${var.argocd_namespace} --timeout=300s
      kubectl --kubeconfig=${kind_cluster.this.kubeconfig_path} \
        wait --for=condition=available deployment/argocd-repo-server \
        -n ${var.argocd_namespace} --timeout=300s
      kubectl --kubeconfig=${kind_cluster.this.kubeconfig_path} \
        rollout status statefulset/argocd-application-controller \
        -n ${var.argocd_namespace} --timeout=300s
      echo "ArgoCD is ready!"
    EOF
  }
}

resource "kubectl_manifest" "appset_management" {
  depends_on = [null_resource.wait_for_argocd]

  yaml_body = file("${path.module}/../../appset-management.yaml")
}

# Strimzi operator, strimzi namespace, and data namespace are all managed by
# ArgoCD via ApplicationSets with sync waves (see strimzi-operator/ directory).
# Terraform only bootstraps: Kind cluster + ArgoCD + root Application.
