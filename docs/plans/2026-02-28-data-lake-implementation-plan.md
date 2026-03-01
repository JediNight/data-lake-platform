# Data Lake Platform Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a secure, auditable AWS Data Lake with MNPI isolation, CDC and Kafka ingestion, and role-based query access — deployable locally via Kind + ArgoCD and on AWS via Terraform modules.

**Architecture:** Kafka-centric pipeline: PostgreSQL → Debezium (Strimzi/EKS) → MSK Provisioned → Iceberg Sink → S3 (MNPI/non-MNPI buckets) → Glue Catalog → Athena + Lake Formation LF-Tags. Local dev uses Tilt + Kind + ArgoCD GitOps bridge pattern replicated from iac-local.

**Tech Stack:** Terraform, Helm, Kustomize, Kind, ArgoCD, Tilt, Taskfile, Strimzi, Debezium, MSK, S3, Glue, Lake Formation, Athena, Iceberg, SOPS/KSOPS

**Reference:** Design doc at `docs/plans/2026-02-28-data-lake-platform-design.md`. Pattern reference at `/Users/toksfawibe/Documents/claude-agent-workspace/iac-local/`.

---

## Phase 1: Project Scaffold & Local Dev Bootstrap

Build order: root config files → terraform/local → verify Kind + ArgoCD boots.

### Task 1: Root Project Files

**Files:**
- Create: `README.md`
- Create: `kind-config.yaml`
- Create: `.sops.yaml`
- Create: `.gitignore`

**Step 1: Create .gitignore**

```gitignore
# Terraform
**/.terraform/
*.tfstate
*.tfstate.*
*.tfvars.bak
.terraform.lock.hcl

# SOPS
*.dec
keys.txt

# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store

# Tilt
tilt_modules/
```

**Step 2: Create kind-config.yaml**

Mirror iac-local pattern. 1 CP + 1 worker. Mount project dir for ArgoCD. Port 8080 for ArgoCD UI.

```yaml
# Kind Cluster Configuration for data-lake-platform
# Mirrors iac-local pattern: Terraform bootstraps Kind + ArgoCD
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: data-lake

nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # ArgoCD UI
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
    extraMounts:
      - hostPath: /Users/toksfawibe/Documents/claude-agent-workspace/data-lake-platform
        containerPath: /mnt/data-lake-platform
        readOnly: true

  - role: worker
    labels:
      workload: applications
    extraMounts:
      - hostPath: /Users/toksfawibe/Documents/claude-agent-workspace/data-lake-platform
        containerPath: /mnt/data-lake-platform
        readOnly: true
      - hostPath: /Users/toksfawibe/.aws
        containerPath: /mnt/aws
        readOnly: true

networking:
  disableDefaultCNI: false
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
```

**Step 3: Create .sops.yaml**

```yaml
creation_rules:
  - path_regex: .*secret.*\.yaml$
    encrypted_regex: "^(data|stringData)$"
    age: >-
      age1...
```

Note: Replace `age1...` with actual age public key from `~/.config/sops/age/keys.txt`.

**Step 4: Create README.md**

```markdown
# Data Lake Platform

Secure, auditable AWS Data Lake with MNPI/non-MNPI isolation for an asset management firm.

## Prerequisites

- [Terraform](https://terraform.io) >= 1.7.0
- [Kind](https://kind.sigs.k8s.io/) >= 0.20
- [Tilt](https://tilt.dev/) >= 0.33
- [Task](https://taskfile.dev/) >= 3.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/) >= 1.28
- [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)
- AWS CLI v2 with SSO configured

## Quick Start

```bash
task up          # Bootstrap Kind + ArgoCD + deploy workloads
task status      # Check all resources
task down        # Tear down everything
```

## Architecture

See [Architecture Design](docs/plans/2026-02-28-data-lake-platform-design.md) for full details.

## Project Structure

- `terraform/local/` — Kind cluster + ArgoCD bootstrap (GitOps bridge)
- `terraform/aws/` — AWS infrastructure modules + environments
- `strimzi/` — Kafka Connect (Debezium CDC + Iceberg sinks)
- `sample-postgres/` — Source RDBMS for CDC demo
- `scripts/` — SQL transforms and validation queries
- `docs/` — Architecture docs and plans
```

**Step 5: Commit**

```bash
git add .gitignore README.md kind-config.yaml .sops.yaml
git commit -m "feat: add project scaffold (kind config, README, gitignore, SOPS)"
```

---

### Task 2: Taskfile.yml

**Files:**
- Create: `Taskfile.yml`

**Step 1: Create Taskfile.yml**

Mirror iac-local Taskfile structure. Lifecycle tasks + infra + tilt + status.

```yaml
version: '3'

vars:
  CLUSTER_NAME: data-lake
  TF_LOCAL_DIR: terraform/local
  TF_AWS_DIR: terraform/aws/environments/dev

tasks:
  # =========================================================================
  # Lifecycle
  # =========================================================================

  up:
    desc: Start data-lake-platform (Terraform bootstrap + Tilt dev loop)
    cmds:
      - task: infra
      - task: tilt

  down:
    desc: Tear down data-lake-platform completely
    cmds:
      - tilt down || true
      - terraform -chdir={{.TF_LOCAL_DIR}} destroy -auto-approve

  reset:
    desc: Full reset (destroy + recreate)
    cmds:
      - task: down
      - task: up

  # =========================================================================
  # Local Infrastructure (Kind + ArgoCD)
  # =========================================================================

  infra:
    desc: Bootstrap Kind cluster + ArgoCD via Terraform
    cmds:
      - terraform -chdir={{.TF_LOCAL_DIR}} init -upgrade
      - terraform -chdir={{.TF_LOCAL_DIR}} apply -auto-approve

  infra:plan:
    desc: Preview local infrastructure changes
    cmds:
      - terraform -chdir={{.TF_LOCAL_DIR}} init -upgrade
      - terraform -chdir={{.TF_LOCAL_DIR}} plan

  infra:destroy:
    desc: Destroy local infrastructure only
    cmds:
      - terraform -chdir={{.TF_LOCAL_DIR}} destroy -auto-approve

  # =========================================================================
  # AWS Infrastructure
  # =========================================================================

  aws:init:
    desc: Initialize AWS Terraform modules
    cmds:
      - terraform -chdir={{.TF_AWS_DIR}} init -upgrade

  aws:plan:
    desc: Preview AWS infrastructure changes
    cmds:
      - terraform -chdir={{.TF_AWS_DIR}} plan

  aws:apply:
    desc: Apply AWS infrastructure
    cmds:
      - terraform -chdir={{.TF_AWS_DIR}} apply

  aws:destroy:
    desc: Destroy AWS infrastructure
    cmds:
      - terraform -chdir={{.TF_AWS_DIR}} destroy

  # =========================================================================
  # Tilt Dev Loop
  # =========================================================================

  tilt:
    desc: Start Tilt dev loop (Kind cluster must exist)
    cmds:
      - tilt up

  tilt:ci:
    desc: Run Tilt in CI mode (non-interactive)
    cmds:
      - tilt ci --timeout 10m

  # =========================================================================
  # ArgoCD
  # =========================================================================

  argocd:password:
    desc: Get ArgoCD admin password
    cmds:
      - |
        kubectl -n argocd get secret argocd-initial-admin-secret \
          -o jsonpath='{.data.password}' | base64 -d && echo

  argocd:sync:
    desc: Force refresh all ArgoCD applications
    cmds:
      - |
        for app in $(kubectl -n argocd get applications -o jsonpath='{.items[*].metadata.name}'); do
          echo "Refreshing: $app"
          kubectl -n argocd annotate app "$app" \
            argocd.argoproj.io/refresh=hard --overwrite
        done

  # =========================================================================
  # Status & Debugging
  # =========================================================================

  status:
    desc: Show status of all resources
    cmds:
      - |
        echo "=== Kind Cluster ==="
        kind get clusters 2>/dev/null | grep {{.CLUSTER_NAME}} || echo "NOT RUNNING"
        echo ""
        echo "=== ArgoCD ApplicationSets ==="
        kubectl -n argocd get applicationsets 2>/dev/null || echo "ArgoCD not ready"
        echo ""
        echo "=== ArgoCD Applications ==="
        kubectl -n argocd get applications 2>/dev/null || echo "ArgoCD not ready"
        echo ""
        echo "=== Strimzi Namespace ==="
        kubectl -n strimzi get pods 2>/dev/null || echo "Strimzi not ready"
        echo ""
        echo "=== Data Namespace ==="
        kubectl -n data get pods 2>/dev/null || echo "Data namespace not ready"

  logs:postgres:
    desc: Stream sample-postgres logs
    cmds:
      - kubectl -n data logs -f -l app=sample-postgres

  logs:connect:
    desc: Stream Kafka Connect logs
    cmds:
      - kubectl -n strimzi logs -f -l strimzi.io/kind=KafkaConnect

  # =========================================================================
  # Database
  # =========================================================================

  db:shell:
    desc: Open psql shell to sample trading database
    cmds:
      - |
        kubectl -n data exec -it statefulset/sample-postgres -- \
          psql -U postgres -d trading

  db:seed:
    desc: Seed sample financial data
    cmds:
      - |
        kubectl -n data exec -i statefulset/sample-postgres -- \
          psql -U postgres -d trading < scripts/00_seed/seed-data.sql

  # =========================================================================
  # Cleanup
  # =========================================================================

  cleanup:
    desc: Clean up stuck pods
    cmds:
      - kubectl delete pods --field-selector=status.phase=Failed --all-namespaces 2>/dev/null || true
      - echo "Cleanup complete"
```

**Step 2: Commit**

```bash
git add Taskfile.yml
git commit -m "feat: add Taskfile with lifecycle, infra, AWS, and debug tasks"
```

---

### Task 3: Terraform Local Bootstrap

**Files:**
- Create: `terraform/local/providers.tf`
- Create: `terraform/local/variables.tf`
- Create: `terraform/local/main.tf`
- Create: `terraform/local/outputs.tf`
- Create: `terraform/local/argocd-values.yaml`
- Create: `appset-management.yaml`

**Step 1: Create providers.tf**

Replicate iac-local providers exactly (tehcyx/kind, hashicorp/helm, hashicorp/kubernetes, gavinbunney/kubectl).

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.7"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.18"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "kind" {}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}

provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}

provider "kubectl" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  load_config_file       = false
}
```

**Step 2: Create variables.tf**

```hcl
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
```

**Step 3: Create main.tf**

Replicate iac-local GitOps bridge: Kind cluster → Local Path Provisioner → ArgoCD namespace → SOPS age key → ArgoCD Helm → wait for readiness → apply root Application.

```hcl
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
      role = "control-plane"

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
      role = "worker"

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

# =============================================================================
# Strimzi Namespace (for Kafka Connect workloads)
# =============================================================================

resource "kubernetes_namespace_v1" "strimzi" {
  metadata {
    name = "strimzi"
  }

  depends_on = [kind_cluster.this]
}

# =============================================================================
# Data Namespace (for sample-postgres and other data workloads)
# =============================================================================

resource "kubernetes_namespace_v1" "data" {
  metadata {
    name = "data"
  }

  depends_on = [kind_cluster.this]
}

# =============================================================================
# Strimzi Operator (Helm)
# =============================================================================

resource "helm_release" "strimzi" {
  name       = "strimzi"
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  namespace  = kubernetes_namespace_v1.strimzi.metadata[0].name
  version    = "0.44.0"

  set {
    name  = "watchAnyNamespace"
    value = "true"
  }

  depends_on = [
    kubernetes_namespace_v1.strimzi,
    null_resource.local_path_provisioner,
  ]
}
```

**Step 4: Create argocd-values.yaml**

```yaml
# ArgoCD values for data-lake-platform local dev
# Mirrors iac-local/terraform/argocd-values.yaml

global:
  logging:
    level: warn

configs:
  params:
    server.insecure: true
    application.namespaces: "*"
    applicationsetcontroller.namespaces: "*"
  cm:
    timeout.reconciliation: 5s
    kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"

server:
  service:
    type: NodePort
    nodePortHttp: 30080
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi

controller:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

repoServer:
  volumes:
    - name: sops-age-key
      secret:
        secretName: sops-age-key
    - name: custom-tools
      emptyDir: {}
  initContainers:
    - name: install-ksops
      image: viaductoss/ksops:v4.3.2
      command: ["/bin/sh", "-c"]
      args:
        - echo "Installing KSOPS...";
          mv /usr/local/bin/ksops /custom-tools/ksops;
          mv /usr/local/bin/kustomize /custom-tools/kustomize;
          echo "KSOPS installed successfully"
      volumeMounts:
        - mountPath: /custom-tools
          name: custom-tools
  volumeMounts:
    - mountPath: /usr/local/bin/ksops
      name: custom-tools
      subPath: ksops
    - mountPath: /usr/local/bin/kustomize
      name: custom-tools
      subPath: kustomize
    - mountPath: /home/argocd/.config/sops/age
      name: sops-age-key
  env:
    - name: SOPS_AGE_KEY_FILE
      value: /home/argocd/.config/sops/age/keys.txt
    - name: XDG_CONFIG_HOME
      value: /home/argocd/.config
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi

redis:
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 128Mi

applicationSet:
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

**Step 5: Create outputs.tf**

```hcl
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
```

**Step 6: Create appset-management.yaml**

```yaml
# Root Application — Application of ApplicationSets
# Mirrors iac-local/appset-management.yaml pattern
#
# Auto-discovers all */applicationset.yaml files and syncs to ArgoCD.
# Adding a new service: create myservice/applicationset.yaml, commit, done.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: appset-management
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: file:///mnt/data-lake-platform
    targetRevision: HEAD
    path: .
    directory:
      recurse: true
      include: '*/applicationset.yaml'
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

**Step 7: Verify bootstrap works**

```bash
task infra
# Expected: Kind cluster "data-lake" created, ArgoCD deployed, appset-management applied
task status
# Expected: Kind cluster running, ArgoCD apps listed, strimzi/data namespaces created
task argocd:password
# Expected: ArgoCD admin password printed
# Visit http://localhost:8080 and verify ArgoCD UI loads
```

**Step 8: Commit**

```bash
git add terraform/local/ appset-management.yaml
git commit -m "feat: add terraform local bootstrap (Kind + ArgoCD + Strimzi operator)"
```

---

### Task 4: Tiltfile

**Files:**
- Create: `Tiltfile`

**Step 1: Create Tiltfile**

```python
# data-lake-platform Tiltfile
# Inner dev loop — assumes Terraform has bootstrapped Kind + ArgoCD (run `task up`)

print("""
========================================
  data-lake-platform: Dev Loop
  Tilt watches -> ArgoCD deploys
========================================
""")

# ==========================================================================
# File Watchers (ArgoCD syncs on commit, Tilt watches for awareness)
# ==========================================================================

watch_file('strimzi/')
watch_file('sample-postgres/')
watch_file('appset-management.yaml')

# ==========================================================================
# Utility Resources
# ==========================================================================

local_resource(
    'argocd-password',
    cmd='echo "ArgoCD Admin Password:" && ' +
        "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && " +
        'echo "" && echo "ArgoCD UI: http://localhost:8080"',
    labels=['info'],
    auto_init=True,
    trigger_mode=TRIGGER_MODE_MANUAL,
)

local_resource(
    'sync-status',
    cmd='echo "=== ApplicationSets ===" && ' +
        'kubectl -n argocd get applicationsets 2>/dev/null && ' +
        'echo "" && echo "=== Applications ===" && ' +
        'kubectl -n argocd get applications 2>/dev/null && ' +
        'echo "" && echo "=== Strimzi Namespace ===" && ' +
        'kubectl -n strimzi get pods 2>/dev/null && ' +
        'echo "" && echo "=== Data Namespace ===" && ' +
        'kubectl -n data get pods 2>/dev/null',
    labels=['info'],
    auto_init=False,
    trigger_mode=TRIGGER_MODE_MANUAL,
)

local_resource(
    'kafka-connect-status',
    cmd='kubectl -n strimzi get kafkaconnects,kafkaconnectors 2>/dev/null || echo "No Kafka Connect resources"',
    labels=['kafka'],
    auto_init=False,
    trigger_mode=TRIGGER_MODE_MANUAL,
)

local_resource(
    'cleanup',
    cmd='kubectl delete pods --field-selector=status.phase=Failed --all-namespaces 2>/dev/null || true && ' +
        'echo "Cleaned up failed pods"',
    labels=['utils'],
    auto_init=False,
    trigger_mode=TRIGGER_MODE_MANUAL,
)
```

**Step 2: Commit**

```bash
git add Tiltfile
git commit -m "feat: add Tiltfile for local dev loop"
```

---

## Phase 2: Sample PostgreSQL (CDC Source)

### Task 5: Sample PostgreSQL with Trading Schema

**Files:**
- Create: `sample-postgres/applicationset.yaml`
- Create: `sample-postgres/base/kustomization.yaml`
- Create: `sample-postgres/base/statefulset.yaml`
- Create: `sample-postgres/base/service.yaml`
- Create: `sample-postgres/base/init-schema.sql`
- Create: `sample-postgres/overlays/localdev/kustomization.yaml`

**Step 1: Create applicationset.yaml**

Mirror iac-local/postgres/applicationset.yaml pattern.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: sample-postgres
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          - cluster: localdev
  template:
    metadata:
      name: 'sample-postgres-{{ .cluster }}'
    spec:
      project: default
      source:
        repoURL: file:///mnt/data-lake-platform
        targetRevision: HEAD
        path: 'sample-postgres/overlays/{{ .cluster }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: data
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**Step 2: Create base/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - statefulset.yaml
  - service.yaml
configMapGenerator:
  - name: postgres-init
    files:
      - init-schema.sql
```

**Step 3: Create base/statefulset.yaml**

PostgreSQL 16 with WAL level `logical` (required for Debezium CDC).

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sample-postgres
  labels:
    app: sample-postgres
spec:
  serviceName: sample-postgres
  replicas: 1
  selector:
    matchLabels:
      app: sample-postgres
  template:
    metadata:
      labels:
        app: sample-postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: trading
            - name: POSTGRES_USER
              value: postgres
            - name: POSTGRES_PASSWORD
              value: postgres
          args:
            - "-c"
            - "wal_level=logical"
            - "-c"
            - "max_replication_slots=4"
            - "-c"
            - "max_wal_senders=4"
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init
              mountPath: /docker-entrypoint-initdb.d
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: init
          configMap:
            name: postgres-init
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

**Step 4: Create base/service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sample-postgres
  labels:
    app: sample-postgres
spec:
  type: ClusterIP
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
  selector:
    app: sample-postgres
```

**Step 5: Create base/init-schema.sql**

5 source tables matching the data model from the design doc. Primary keys on all tables (required by Debezium). `updated_at` columns for ordering.

```sql
-- Trading Platform Schema
-- 5 source tables for CDC ingestion to data lake

-- MNPI Tables (orders, trades, positions)

CREATE TABLE orders (
    order_id        SERIAL PRIMARY KEY,
    account_id      INTEGER NOT NULL,
    instrument_id   INTEGER NOT NULL,
    side            VARCHAR(4) NOT NULL CHECK (side IN ('BUY', 'SELL')),
    quantity        DECIMAL(18,4) NOT NULL,
    order_type      VARCHAR(10) NOT NULL CHECK (order_type IN ('MARKET', 'LIMIT', 'STOP')),
    limit_price     DECIMAL(18,4),
    status          VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING', 'FILLED', 'PARTIAL', 'CANCELLED')),
    disclosure_status VARCHAR(10) NOT NULL DEFAULT 'MNPI'
                    CHECK (disclosure_status IN ('MNPI', 'DISCLOSED', 'PUBLIC')),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TABLE trades (
    trade_id        SERIAL PRIMARY KEY,
    order_id        INTEGER NOT NULL REFERENCES orders(order_id),
    instrument_id   INTEGER NOT NULL,
    quantity        DECIMAL(18,4) NOT NULL,
    price           DECIMAL(18,4) NOT NULL,
    execution_venue VARCHAR(20) NOT NULL DEFAULT 'NYSE',
    settlement_date DATE,
    disclosure_status VARCHAR(10) NOT NULL DEFAULT 'MNPI'
                    CHECK (disclosure_status IN ('MNPI', 'DISCLOSED', 'PUBLIC')),
    executed_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TABLE positions (
    position_id     SERIAL PRIMARY KEY,
    account_id      INTEGER NOT NULL,
    instrument_id   INTEGER NOT NULL,
    quantity        DECIMAL(18,4) NOT NULL DEFAULT 0,
    market_value    DECIMAL(18,2),
    position_date   DATE NOT NULL DEFAULT CURRENT_DATE,
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (account_id, instrument_id, position_date)
);

-- Non-MNPI Tables (accounts, instruments)

CREATE TABLE accounts (
    account_id      SERIAL PRIMARY KEY,
    account_name    VARCHAR(100) NOT NULL,
    account_type    VARCHAR(20) NOT NULL CHECK (account_type IN ('INDIVIDUAL', 'INSTITUTIONAL', 'FUND')),
    status          VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TABLE instruments (
    instrument_id   SERIAL PRIMARY KEY,
    ticker          VARCHAR(10) NOT NULL UNIQUE,
    cusip           CHAR(9),
    isin            CHAR(12),
    name            VARCHAR(200) NOT NULL,
    instrument_type VARCHAR(10) NOT NULL CHECK (instrument_type IN ('EQUITY', 'BOND', 'ETF', 'OPTION')),
    exchange        VARCHAR(10) NOT NULL DEFAULT 'NYSE',
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Indexes for query performance
CREATE INDEX idx_orders_account ON orders(account_id);
CREATE INDEX idx_orders_instrument ON orders(instrument_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_trades_order ON trades(order_id);
CREATE INDEX idx_trades_instrument ON trades(instrument_id);
CREATE INDEX idx_positions_account ON positions(account_id);
CREATE INDEX idx_positions_instrument ON positions(instrument_id);
CREATE INDEX idx_instruments_cusip ON instruments(cusip);
CREATE INDEX idx_instruments_isin ON instruments(isin);

-- Publication for Debezium CDC (all tables)
CREATE PUBLICATION debezium_publication FOR ALL TABLES;
```

**Step 6: Create overlays/localdev/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: data
resources:
  - ../../base
```

**Step 7: Verify ArgoCD picks up sample-postgres**

```bash
# Commit so ArgoCD can read from the mounted filesystem
git add sample-postgres/
git commit -m "feat: add sample-postgres with trading schema (5 tables, WAL logical)"

# Check ArgoCD discovered the ApplicationSet
task status
# Expected: sample-postgres-localdev application appears
# Expected: sample-postgres pod running in data namespace

# Verify schema
task db:shell
# In psql: \dt  — should show 5 tables
# In psql: \q
```

---

### Task 6: Seed Data

**Files:**
- Create: `scripts/00_seed/seed-data.sql`

**Step 1: Create seed-data.sql**

Sample financial data that demonstrates MNPI concepts.

```sql
-- Seed data for trading platform demo
-- Provides realistic financial data for CDC and query demos

-- Instruments (non-MNPI: publicly available reference data)
INSERT INTO instruments (ticker, cusip, isin, name, instrument_type, exchange) VALUES
('AAPL',  '037833100', 'US0378331005', 'Apple Inc.',                  'EQUITY', 'NASDAQ'),
('MSFT',  '594918104', 'US5949181045', 'Microsoft Corporation',       'EQUITY', 'NASDAQ'),
('GOOGL', '02079K305', 'US02079K3059', 'Alphabet Inc.',               'EQUITY', 'NASDAQ'),
('JPM',   '46625H100', 'US46625H1005', 'JPMorgan Chase & Co.',       'EQUITY', 'NYSE'),
('GS',    '38141G104', 'US38141G1040', 'The Goldman Sachs Group',    'EQUITY', 'NYSE'),
('BRK.B', '084670702', 'US0846707026', 'Berkshire Hathaway Inc.',    'EQUITY', 'NYSE'),
('SPY',   '78462F103', 'US78462F1030', 'SPDR S&P 500 ETF Trust',    'ETF',    'NYSE'),
('AGG',   '464287226', 'US4642872265', 'iShares Core US Agg Bond',  'ETF',    'NYSE');

-- Accounts (non-MNPI: account metadata)
INSERT INTO accounts (account_name, account_type, status) VALUES
('Alpha Growth Fund',       'FUND',          'ACTIVE'),
('Beta Income Portfolio',   'FUND',          'ACTIVE'),
('J. Smith Individual',     'INDIVIDUAL',    'ACTIVE'),
('Gamma Institutional',     'INSTITUTIONAL', 'ACTIVE'),
('Dormant Holdings LLC',    'INSTITUTIONAL', 'SUSPENDED');

-- Orders (MNPI: non-public trading intent)
INSERT INTO orders (account_id, instrument_id, side, quantity, order_type, limit_price, status, disclosure_status) VALUES
(1, 1, 'BUY',  1000.0000, 'LIMIT',  185.50, 'FILLED',    'DISCLOSED'),
(1, 2, 'BUY',  500.0000,  'MARKET', NULL,    'FILLED',    'DISCLOSED'),
(2, 4, 'BUY',  2000.0000, 'LIMIT',  198.00, 'FILLED',    'MNPI'),
(2, 7, 'BUY',  5000.0000, 'MARKET', NULL,    'FILLED',    'MNPI'),
(3, 1, 'SELL', 200.0000,  'LIMIT',  190.00, 'PENDING',   'MNPI'),
(4, 5, 'BUY',  1500.0000, 'LIMIT',  450.00, 'PARTIAL',   'MNPI'),
(1, 3, 'BUY',  300.0000,  'MARKET', NULL,    'CANCELLED', 'DISCLOSED');

-- Trades (MNPI: non-public execution data)
INSERT INTO trades (order_id, instrument_id, quantity, price, execution_venue, settlement_date, disclosure_status) VALUES
(1, 1, 1000.0000, 185.25, 'NASDAQ', CURRENT_DATE + INTERVAL '2 days', 'DISCLOSED'),
(2, 2, 500.0000,  420.10, 'NASDAQ', CURRENT_DATE + INTERVAL '2 days', 'DISCLOSED'),
(3, 4, 2000.0000, 197.85, 'NYSE',   CURRENT_DATE + INTERVAL '2 days', 'MNPI'),
(4, 7, 5000.0000, 525.30, 'NYSE',   CURRENT_DATE + INTERVAL '2 days', 'MNPI'),
(6, 5, 750.0000,  449.50, 'NYSE',   CURRENT_DATE + INTERVAL '2 days', 'MNPI');

-- Positions (MNPI: non-public holdings)
INSERT INTO positions (account_id, instrument_id, quantity, market_value, position_date) VALUES
(1, 1, 1000.0000, 185250.00, CURRENT_DATE),
(1, 2, 500.0000,  210050.00, CURRENT_DATE),
(2, 4, 2000.0000, 395700.00, CURRENT_DATE),
(2, 7, 5000.0000, 2626500.00, CURRENT_DATE),
(3, 1, 800.0000,  148200.00, CURRENT_DATE),
(4, 5, 750.0000,  337125.00, CURRENT_DATE);
```

**Step 2: Commit**

```bash
git add scripts/00_seed/seed-data.sql
git commit -m "feat: add seed data (instruments, accounts, orders, trades, positions)"
```

**Step 3: Seed the database**

```bash
task db:seed
# Expected: INSERT 0 8, INSERT 0 5, INSERT 0 7, INSERT 0 5, INSERT 0 6

# Verify
task db:shell
# SELECT count(*) FROM orders;  -> 7
# SELECT count(*) FROM trades;  -> 5
# \q
```

---

## Phase 3: Strimzi Kafka Connect (CDC + Iceberg Sinks)

### Task 7: Strimzi KafkaConnect + Debezium Source

**Files:**
- Create: `strimzi/applicationset.yaml`
- Create: `strimzi/base/kustomization.yaml`
- Create: `strimzi/base/kafka-connect.yaml`
- Create: `strimzi/base/debezium-source.yaml`
- Create: `strimzi/overlays/localdev/kustomization.yaml`
- Create: `strimzi/overlays/localdev/debezium-source-patch.yaml`

**Step 1: Create applicationset.yaml**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: strimzi-connect
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          - cluster: localdev
  template:
    metadata:
      name: 'strimzi-connect-{{ .cluster }}'
    spec:
      project: default
      source:
        repoURL: file:///mnt/data-lake-platform
        targetRevision: HEAD
        path: 'strimzi/overlays/{{ .cluster }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: strimzi
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**Step 2: Create base/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kafka-connect.yaml
  - debezium-source.yaml
```

**Step 3: Create base/kafka-connect.yaml**

KafkaConnect CRD with Debezium PostgreSQL connector plugin and Iceberg sink plugin. For local dev, this connects to a local Kafka (we'll need to add a local Kafka or use a Strimzi Kafka cluster for local dev).

Note: For local dev, we deploy a small Strimzi Kafka cluster alongside KafkaConnect. For AWS, KafkaConnect points to MSK.

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnect
metadata:
  name: data-lake-connect
  annotations:
    strimzi.io/use-connector-resources: "true"
spec:
  version: 3.6.0
  replicas: 1
  bootstrapServers: data-lake-kafka-bootstrap:9092
  config:
    group.id: data-lake-connect
    offset.storage.topic: connect-offsets
    config.storage.topic: connect-configs
    status.storage.topic: connect-status
    offset.storage.replication.factor: 1
    config.storage.replication.factor: 1
    status.storage.replication.factor: 1
    key.converter: org.apache.kafka.connect.json.JsonConverter
    value.converter: org.apache.kafka.connect.json.JsonConverter
    key.converter.schemas.enable: false
    value.converter.schemas.enable: false
  build:
    output:
      type: docker
      image: localhost/data-lake-connect:latest
      pushSecret: ""
    plugins:
      - name: debezium-postgres
        artifacts:
          - type: tgz
            url: https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/2.5.0.Final/debezium-connector-postgres-2.5.0.Final-plugin.tar.gz
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
```

**Step 4: Create base/debezium-source.yaml**

Environment-agnostic base: connector class, transforms, snapshot mode. Connection-specific fields go in overlay patches.

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: debezium-postgres-source
  labels:
    strimzi.io/cluster: data-lake-connect
spec:
  class: io.debezium.connector.postgresql.PostgresConnector
  tasksMax: 1
  config:
    # Connection (overridden per environment via Kustomize patch)
    database.hostname: "PLACEHOLDER"
    database.port: "5432"
    database.user: "PLACEHOLDER"
    database.password: "PLACEHOLDER"
    database.dbname: "trading"

    # CDC config
    plugin.name: pgoutput
    publication.name: debezium_publication
    topic.prefix: cdc.trading
    slot.name: debezium_slot

    # Snapshot
    snapshot.mode: initial

    # Schema history
    schema.history.internal.kafka.bootstrap.servers: data-lake-kafka-bootstrap:9092
    schema.history.internal.kafka.topic: debezium-schema-history

    # Tables to capture (all 5)
    table.include.list: "public.orders,public.trades,public.positions,public.accounts,public.instruments"
```

**Step 5: Create overlays/localdev/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: strimzi
resources:
  - ../../base
  - kafka-cluster.yaml
patches:
  - path: debezium-source-patch.yaml
    target:
      kind: KafkaConnector
      name: debezium-postgres-source
```

**Step 6: Create overlays/localdev/kafka-cluster.yaml**

Local Kafka cluster for dev (replaces MSK Provisioned in AWS).

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: data-lake-kafka
spec:
  kafka:
    version: 3.6.0
    replicas: 1
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
      auto.create.topics.enable: true
    storage:
      type: ephemeral
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1Gi
  zookeeper:
    replicas: 1
    storage:
      type: ephemeral
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

**Step 7: Create overlays/localdev/debezium-source-patch.yaml**

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: debezium-postgres-source
spec:
  config:
    database.hostname: "sample-postgres.data.svc.cluster.local"
    database.port: "5432"
    database.user: "postgres"
    database.password: "postgres"
```

**Step 8: Commit and verify**

```bash
git add strimzi/
git commit -m "feat: add Strimzi Kafka Connect with Debezium source connector"

# Wait for ArgoCD to sync
task status
# Expected: strimzi-connect-localdev application appears
# Expected: data-lake-kafka and data-lake-connect pods in strimzi namespace

# Verify Debezium is running
kubectl -n strimzi get kafkaconnectors
# Expected: debezium-postgres-source with READY=True

# Verify topics created
kubectl -n strimzi exec -it data-lake-kafka-0 -- bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list
# Expected: cdc.trading.orders, cdc.trading.trades, etc.
```

---

### Task 8: Iceberg Sink Connectors

**Note:** For local dev, the Iceberg sink writes to a local MinIO S3-compatible store or local filesystem. For AWS, it writes to real S3 via IRSA. This task sets up the connector CRDs; the actual Iceberg sink plugin requires additional build config.

**Files:**
- Modify: `strimzi/base/kustomization.yaml` — add sink YAMLs
- Create: `strimzi/base/iceberg-sink-mnpi.yaml`
- Create: `strimzi/base/iceberg-sink-nonmnpi.yaml`
- Create: `strimzi/overlays/localdev/iceberg-sink-mnpi-patch.yaml`
- Create: `strimzi/overlays/localdev/iceberg-sink-nonmnpi-patch.yaml`
- Modify: `strimzi/overlays/localdev/kustomization.yaml` — add sink patches

This task requires research into the current Iceberg Kafka Connect Sink plugin availability and configuration. The implementation should:
1. Add the Iceberg sink plugin JAR to the KafkaConnect build
2. Create two KafkaConnector CRDs (MNPI and non-MNPI) with topic subscriptions per the design
3. Configure append-only mode (`iceberg.tables.upsert-mode-enabled=false`)
4. Configure partition spec (`days(source_timestamp)`)
5. For local dev, use a local catalog (Hadoop/JDBC) instead of Glue

**Step 1: Update base/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kafka-connect.yaml
  - debezium-source.yaml
  - iceberg-sink-mnpi.yaml
  - iceberg-sink-nonmnpi.yaml
```

**Step 2: Create MNPI sink connector**

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: iceberg-sink-mnpi
  labels:
    strimzi.io/cluster: data-lake-connect
spec:
  class: io.tabular.iceberg.connect.IcebergSinkConnector
  tasksMax: 1
  config:
    # Topics: MNPI CDC tables + MNPI streaming
    topics: "cdc.trading.orders,cdc.trading.trades,cdc.trading.positions,stream.order-events"

    # Iceberg catalog (overridden per environment)
    iceberg.catalog.type: "PLACEHOLDER"
    iceberg.catalog.warehouse: "PLACEHOLDER"

    # Table mapping
    iceberg.tables.auto-create-enabled: "true"
    iceberg.tables.upsert-mode-enabled: "false"

    # Key/value converters
    key.converter: org.apache.kafka.connect.json.JsonConverter
    value.converter: org.apache.kafka.connect.json.JsonConverter
    key.converter.schemas.enable: "false"
    value.converter.schemas.enable: "false"
```

**Step 3: Create non-MNPI sink connector**

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: iceberg-sink-nonmnpi
  labels:
    strimzi.io/cluster: data-lake-connect
spec:
  class: io.tabular.iceberg.connect.IcebergSinkConnector
  tasksMax: 1
  config:
    topics: "cdc.trading.accounts,cdc.trading.instruments,stream.market-data"

    iceberg.catalog.type: "PLACEHOLDER"
    iceberg.catalog.warehouse: "PLACEHOLDER"

    iceberg.tables.auto-create-enabled: "true"
    iceberg.tables.upsert-mode-enabled: "false"

    key.converter: org.apache.kafka.connect.json.JsonConverter
    value.converter: org.apache.kafka.connect.json.JsonConverter
    key.converter.schemas.enable: "false"
    value.converter.schemas.enable: "false"
```

**Step 4: Create overlay patches for local dev**

For local dev, use Hadoop catalog writing to a local filesystem path (or MinIO). This placeholder will be refined during implementation based on available Iceberg sink plugin versions.

**Step 5: Commit**

```bash
git add strimzi/
git commit -m "feat: add Iceberg sink connectors (MNPI and non-MNPI topic routing)"
```

---

## Phase 4: Terraform AWS Modules

Build order: modules first (bottom-up by dependency), then dev environment.

### Task 9: Module — data-lake-storage

**Files:**
- Create: `terraform/aws/modules/data-lake-storage/main.tf`
- Create: `terraform/aws/modules/data-lake-storage/variables.tf`
- Create: `terraform/aws/modules/data-lake-storage/outputs.tf`

S3 buckets (MNPI + non-MNPI + audit + query-results), KMS keys per zone, bucket policies with Lake Formation bypass prevention, lifecycle rules.

**Key implementation details:**
- Two data lake buckets: `datalake-mnpi-{env}` and `datalake-nonmnpi-{env}`
- One audit bucket: `datalake-audit-{env}`
- One query results bucket: `datalake-query-results-{env}`
- Separate KMS CMK per MNPI zone
- Bucket policy on data lake buckets: deny all `s3:GetObject`/`s3:PutObject` except Lake Formation service role, Kafka Connect IRSA role, Data Engineer role, and admin role (ARNs passed as variables)
- Server-side encryption with KMS
- Versioning enabled on data lake buckets
- Lifecycle rule: transition raw layer to IA after 90 days (prod), no transition (dev)

**Commit after implementation:**

```bash
git add terraform/aws/modules/data-lake-storage/
git commit -m "feat: add data-lake-storage module (S3, KMS, bucket policies)"
```

---

### Task 10: Module — networking

**Files:**
- Create: `terraform/aws/modules/networking/main.tf`
- Create: `terraform/aws/modules/networking/variables.tf`
- Create: `terraform/aws/modules/networking/outputs.tf`

VPC with private subnets, S3 gateway endpoint, security groups for MSK and EKS.

**Commit:**

```bash
git add terraform/aws/modules/networking/
git commit -m "feat: add networking module (VPC, subnets, S3 endpoint, security groups)"
```

---

### Task 11: Module — streaming

**Files:**
- Create: `terraform/aws/modules/streaming/main.tf`
- Create: `terraform/aws/modules/streaming/variables.tf`
- Create: `terraform/aws/modules/streaming/outputs.tf`

MSK Provisioned cluster with IAM auth, TLS in-transit, topic pre-creation for Debezium schema history.

**Key implementation details:**
- `aws_msk_cluster` with `kafka.t3.small` (dev) / `kafka.m5.large` (prod)
- IAM authentication enabled
- TLS encryption in-transit
- Pre-create Debezium internal topics via `aws_msk_configuration`
- Security group allowing port 9098 from EKS node SG
- CloudWatch log group for broker logs

**Commit:**

```bash
git add terraform/aws/modules/streaming/
git commit -m "feat: add streaming module (MSK Provisioned, IAM auth, TLS)"
```

---

### Task 12: Module — glue-catalog

**Files:**
- Create: `terraform/aws/modules/glue-catalog/main.tf`
- Create: `terraform/aws/modules/glue-catalog/variables.tf`
- Create: `terraform/aws/modules/glue-catalog/outputs.tf`

6 Glue databases, Glue Schema Registry for Avro schemas.

**Key implementation details:**
- 6 `aws_glue_catalog_database`: raw_mnpi, raw_nonmnpi, curated_mnpi, curated_nonmnpi, analytics_mnpi, analytics_nonmnpi
- `aws_glue_registry` for Avro schemas
- `aws_glue_schema` resources for order-events and market-data Avro schemas
- Database location pointing to corresponding S3 paths

**Commit:**

```bash
git add terraform/aws/modules/glue-catalog/
git commit -m "feat: add glue-catalog module (6 databases, schema registry)"
```

---

### Task 13: Module — iam-personas

**Files:**
- Create: `terraform/aws/modules/iam-personas/main.tf`
- Create: `terraform/aws/modules/iam-personas/variables.tf`
- Create: `terraform/aws/modules/iam-personas/outputs.tf`

3 persona IAM roles + Kafka Connect IRSA role.

**Key implementation details:**
- `finance-analyst-role`: Athena query permissions, no direct S3
- `data-analyst-role`: Athena query permissions, no direct S3
- `data-engineer-role`: Athena query + S3 direct access on data lake buckets
- `kafka-connect-irsa-role`: MSK IAM auth, S3 write to data lake buckets, Glue Schema Registry read, Glue Catalog write
- All roles have trust policies for their respective use (console users for analysts, EKS IRSA for connect role)

**Commit:**

```bash
git add terraform/aws/modules/iam-personas/
git commit -m "feat: add iam-personas module (3 personas + IRSA service role)"
```

---

### Task 14: Module — lake-formation

**Files:**
- Create: `terraform/aws/modules/lake-formation/main.tf`
- Create: `terraform/aws/modules/lake-formation/variables.tf`
- Create: `terraform/aws/modules/lake-formation/outputs.tf`

LF-Tags, tag-based grants, S3 location registrations.

**Key implementation details:**
- `aws_lakeformation_lf_tag`: sensitivity (mnpi, non-mnpi), layer (raw, curated, analytics)
- `aws_lakeformation_resource_lf_tags`: assign tags to each of the 6 Glue databases
- `aws_lakeformation_permissions`: tag-based grants per the design:
  - finance-analyst: SELECT on sensitivity=[mnpi,non-mnpi] + layer=[curated,analytics]
  - data-analyst: SELECT on sensitivity=[non-mnpi] + layer=[curated,analytics]
  - data-engineer: ALL on all tags + DATA_LOCATION_ACCESS
- `aws_lakeformation_resource`: register S3 locations

**Commit:**

```bash
git add terraform/aws/modules/lake-formation/
git commit -m "feat: add lake-formation module (LF-Tags, grants, S3 registrations)"
```

---

### Task 15: Module — analytics

**Files:**
- Create: `terraform/aws/modules/analytics/main.tf`
- Create: `terraform/aws/modules/analytics/variables.tf`
- Create: `terraform/aws/modules/analytics/outputs.tf`

Athena workgroups with query result locations and scan limits.

**Key implementation details:**
- 3 `aws_athena_workgroup` resources: finance-analysts, data-analysts, data-engineers
- Each with separate S3 result location prefix
- Data scan limits (10GB dev, 1TB prod via variable)
- Result reuse enabled (prod only)
- `aws_athena_named_query` for sample queries from `scripts/validation/`

**Commit:**

```bash
git add terraform/aws/modules/analytics/
git commit -m "feat: add analytics module (Athena workgroups, named queries)"
```

---

### Task 16: Module — observability

**Files:**
- Create: `terraform/aws/modules/observability/main.tf`
- Create: `terraform/aws/modules/observability/variables.tf`
- Create: `terraform/aws/modules/observability/outputs.tf`

CloudTrail with S3 data events, optional QuickSight.

**Key implementation details:**
- `aws_cloudtrail` with S3 data event selectors on both data lake buckets
- Management events enabled
- Log file validation enabled
- Trail writes to audit bucket
- `aws_glue_catalog_table` over CloudTrail logs for Athena querying
- QuickSight resources gated behind `var.enable_quicksight` using `count`
- Retention managed by audit bucket lifecycle rules (90 days dev, 1825 days prod)

**Commit:**

```bash
git add terraform/aws/modules/observability/
git commit -m "feat: add observability module (CloudTrail, optional QuickSight)"
```

---

### Task 17: Dev Environment

**Files:**
- Create: `terraform/aws/environments/dev/main.tf`
- Create: `terraform/aws/environments/dev/variables.tf`
- Create: `terraform/aws/environments/dev/terraform.tfvars`
- Create: `terraform/aws/environments/dev/backend.tf`
- Create: `terraform/aws/environments/dev/outputs.tf`

Wire all modules together with dev-specific values.

**Key implementation details in main.tf:**

```hcl
module "networking" {
  source = "../../modules/networking"
  environment = var.environment
  # ... dev-specific networking vars
}

module "data_lake_storage" {
  source = "../../modules/data-lake-storage"
  environment = var.environment
  mnpi_kms_key_arn    = ... # created within module
  allowed_principal_arns = [
    module.iam_personas.data_engineer_role_arn,
    module.iam_personas.kafka_connect_role_arn,
  ]
}

module "streaming" {
  source = "../../modules/streaming"
  environment = var.environment
  broker_instance_type = "kafka.t3.small"
  broker_count = 1
  vpc_id = module.networking.vpc_id
  subnet_ids = module.networking.private_subnet_ids
  allowed_sg_ids = [module.networking.eks_node_sg_id]
}

# ... etc for all modules
```

**terraform.tfvars:**

```hcl
environment              = "dev"
broker_instance_type     = "kafka.t3.small"
broker_count             = 1
enable_quicksight        = false
audit_retention_days     = 90
athena_scan_limit_bytes  = 10737418240  # 10GB
```

**backend.tf:**

```hcl
terraform {
  backend "s3" {
    bucket         = "datalake-tfstate-dev"
    key            = "data-lake-platform/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "datalake-tfstate-lock"
    encrypt        = true
  }
}
```

**Commit:**

```bash
git add terraform/aws/
git commit -m "feat: add dev environment wiring all Terraform modules"
```

---

### Task 18: Prod Environment Placeholder

**Files:**
- Create: `terraform/aws/environments/prod/main.tf`
- Create: `terraform/aws/environments/prod/terraform.tfvars`
- Create: `terraform/aws/environments/prod/backend.tf`
- Create: `terraform/aws/environments/prod/outputs.tf`

Same module calls as dev, different tfvars. Documented as placeholder.

**terraform.tfvars:**

```hcl
environment              = "prod"
broker_instance_type     = "kafka.m5.large"
broker_count             = 3
enable_quicksight        = true
audit_retention_days     = 1825  # 5 years per SEC Rule 204-2
athena_scan_limit_bytes  = 1099511627776  # 1TB
```

**Commit:**

```bash
git add terraform/aws/environments/prod/
git commit -m "feat: add prod environment placeholder (documented scaling values)"
```

---

## Phase 5: SQL Transforms & Validation

### Task 19: Curated Layer Transforms

**Files:**
- Create: `scripts/01_curated/curated_orders.sql`
- Create: `scripts/01_curated/curated_trades.sql`
- Create: `scripts/01_curated/curated_positions.sql`
- Create: `scripts/01_curated/curated_accounts.sql`
- Create: `scripts/01_curated/curated_instruments.sql`

Athena `MERGE INTO` statements that produce current-state tables from raw CDC event log. Each script reads from `raw_{mnpi|nonmnpi}.{table}` and writes to `curated_{mnpi|nonmnpi}.{table}`.

Example for `curated_orders.sql`:

```sql
-- Curated Orders: Current-state table from raw CDC events
-- Source: raw_mnpi.orders (append-only Iceberg with Debezium CDC events)
-- Target: curated_mnpi.orders (current state via MERGE)

MERGE INTO curated_mnpi.orders AS target
USING (
    -- Deduplicate: take latest event per order_id
    SELECT *
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY after.order_id
                ORDER BY source_timestamp DESC
            ) AS rn
        FROM raw_mnpi.orders
        WHERE op != 'd'  -- Exclude deletes for current state
    )
    WHERE rn = 1
) AS source
ON target.order_id = source.after.order_id
WHEN MATCHED THEN UPDATE SET
    account_id = source.after.account_id,
    instrument_id = source.after.instrument_id,
    side = source.after.side,
    quantity = source.after.quantity,
    order_type = source.after.order_type,
    limit_price = source.after.limit_price,
    status = source.after.status,
    disclosure_status = source.after.disclosure_status,
    updated_at = from_unixtime(source.source_timestamp / 1000)
WHEN NOT MATCHED THEN INSERT (
    order_id, account_id, instrument_id, side, quantity,
    order_type, limit_price, status, disclosure_status,
    created_at, updated_at
) VALUES (
    source.after.order_id, source.after.account_id,
    source.after.instrument_id, source.after.side,
    source.after.quantity, source.after.order_type,
    source.after.limit_price, source.after.status,
    source.after.disclosure_status,
    from_unixtime(source.source_timestamp / 1000),
    from_unixtime(source.source_timestamp / 1000)
);
```

Similar pattern for trades, positions (MNPI) and accounts, instruments (non-MNPI).

**Commit:**

```bash
git add scripts/01_curated/
git commit -m "feat: add curated layer MERGE transforms for all 5 tables"
```

---

### Task 20: Analytics Layer Transforms

**Files:**
- Create: `scripts/02_analytics/analytics_trade_summary.sql`
- Create: `scripts/02_analytics/analytics_position_report.sql`

CTAS queries that produce aggregated reporting tables.

**Commit:**

```bash
git add scripts/02_analytics/
git commit -m "feat: add analytics layer aggregation queries"
```

---

### Task 21: Validation & Demo Queries

**Files:**
- Create: `scripts/validation/access_validation.sql`
- Create: `scripts/validation/iceberg_time_travel.sql`

Access validation: queries per persona showing grant/deny behavior.
Time travel: demonstrate Iceberg snapshot queries.

**Commit:**

```bash
git add scripts/validation/
git commit -m "feat: add access validation and Iceberg time-travel demo queries"
```

---

## Phase 6: Documentation

### Task 22: Full Documentation

**Files:**
- Create: `docs/documentation.md`

Comprehensive documentation deliverable covering:
- Architecture overview with diagram reference
- Data model and MNPI classification rationale
- Security architecture (LF-Tags, bucket policies, endpoint security)
- Deployment guide (local dev + AWS)
- Query examples per persona
- Production considerations (MSK sizing, dbt, multi-AZ, retention)
- Decision log (from design doc)

**Commit:**

```bash
git add docs/documentation.md
git commit -m "docs: add comprehensive documentation deliverable"
```

---

### Task 23: Architecture Diagram

**Files:**
- Create: `docs/architecture-diagram.png` (or `.drawio` / `.excalidraw`)

Generate a visual architecture diagram from the ASCII diagram in the design doc. Use draw.io, Excalidraw, or similar tool.

**Commit:**

```bash
git add docs/architecture-diagram.*
git commit -m "docs: add visual architecture diagram"
```

---

## Phase 7: Integration Verification

### Task 24: End-to-End Local Verification

**Steps:**

1. `task reset` — clean slate
2. `task status` — verify Kind + ArgoCD + Strimzi operator + Kafka cluster + PostgreSQL
3. `task db:seed` — seed data
4. Verify Debezium captures CDC events:
   ```bash
   kubectl -n strimzi exec -it data-lake-kafka-0 -- bin/kafka-console-consumer.sh \
     --bootstrap-server localhost:9092 --topic cdc.trading.orders --from-beginning --max-messages 5
   ```
5. Verify topic-per-table routing (MNPI topics separate from non-MNPI)
6. Insert a new trade via `task db:shell` and verify CDC event appears on `cdc.trading.trades` topic

**Commit:**

```bash
git commit --allow-empty -m "chore: end-to-end local verification complete"
```

---

### Task 25: Terraform Validate

**Steps:**

1. `task aws:init` — initialize all modules
2. `terraform -chdir=terraform/aws/environments/dev validate` — syntax + type validation
3. Fix any validation errors
4. `terraform -chdir=terraform/aws/environments/prod validate` — same for prod

**Commit if fixes needed:**

```bash
git add terraform/
git commit -m "fix: resolve Terraform validation errors"
```

---

## Summary

| Phase | Tasks | Description |
|-------|-------|-------------|
| 1 | 1-4 | Project scaffold, Taskfile, Terraform local bootstrap, Tiltfile |
| 2 | 5-6 | Sample PostgreSQL with trading schema + seed data |
| 3 | 7-8 | Strimzi Kafka Connect, Debezium source, Iceberg sinks |
| 4 | 9-18 | All 8 Terraform AWS modules + dev/prod environments |
| 5 | 19-21 | SQL transforms (curated MERGE, analytics CTAS, validation) |
| 6 | 22-23 | Documentation + architecture diagram |
| 7 | 24-25 | End-to-end verification |

**Total: 25 tasks across 7 phases**

**Estimated commits: ~25 (one per task)**

**Critical path:** Phase 1 → Phase 2 → Phase 3 (local dev must work before AWS modules). Phase 4 can be parallelized across modules (tasks 9-16 are independent).
