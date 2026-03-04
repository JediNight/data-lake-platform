/**
 * Stack 5: Pipelines — MSK Connect, Lambda, Glue ETL, Analytics, Local Dev
 *
 * Upstream deps:
 *   - foundation (VPC/subnet/SG IDs via terraform_remote_state)
 *   - compute (MSK brokers, Aurora endpoint via terraform_remote_state)
 */

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
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
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "data-lake-platform"
      Environment = local.env
      ManagedBy   = "terraform"
      Stack       = "pipelines"
    }
  }
}

provider "kind" {}

locals {
  # Extract Kind cluster config into locals so provider blocks don't
  # directly reference resource attributes (which blocks terraform import).
  kind_host        = local.c.enable_local_dev ? kind_cluster.this[0].endpoint : ""
  kind_client_cert = local.c.enable_local_dev ? kind_cluster.this[0].client_certificate : ""
  kind_client_key  = local.c.enable_local_dev ? kind_cluster.this[0].client_key : ""
  kind_cluster_ca  = local.c.enable_local_dev ? kind_cluster.this[0].cluster_ca_certificate : ""
}

provider "helm" {
  kubernetes {
    host                   = local.kind_host
    client_certificate     = local.kind_client_cert
    client_key             = local.kind_client_key
    cluster_ca_certificate = local.kind_cluster_ca
  }
}

provider "kubernetes" {
  host                   = local.kind_host
  client_certificate     = local.kind_client_cert
  client_key             = local.kind_client_key
  cluster_ca_certificate = local.kind_cluster_ca
}

provider "kubectl" {
  host                   = local.kind_host
  client_certificate     = local.kind_client_cert
  client_key             = local.kind_client_key
  cluster_ca_certificate = local.kind_cluster_ca
  load_config_file       = false
}

# =============================================================================
# MSK Connect (Debezium source + Iceberg sinks)
# =============================================================================

module "msk_connect" {
  source = "../../modules/msk-connect"
  count  = local.c.enable_msk_connect ? 1 : 0

  environment            = local.env
  msk_cluster_arn        = data.terraform_remote_state.compute.outputs.msk_cluster_arn
  msk_bootstrap_brokers  = data.terraform_remote_state.compute.outputs.bootstrap_brokers_iam
  subnet_ids             = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  security_group_ids     = [data.terraform_remote_state.foundation.outputs.msk_security_group_id]
  mnpi_bucket_arn        = local.mnpi_bucket_arn
  nonmnpi_bucket_arn     = local.nonmnpi_bucket_arn
  kafka_connect_role_arn     = local.kafka_connect_role_arn
  default_replication_factor = local.c.default_replication_factor

  enable_debezium_connector = local.c.enable_debezium_connector
  postgres_endpoint         = local.c.enable_aurora ? data.terraform_remote_state.compute.outputs.cluster_endpoint : ""
  postgres_port             = local.c.enable_aurora ? data.terraform_remote_state.compute.outputs.cluster_port : 5432
  aurora_secret_arn         = local.c.enable_aurora ? data.terraform_remote_state.compute.outputs.master_password_secret_arn : ""
  aurora_cdc_setup_id       = local.c.enable_aurora ? data.terraform_remote_state.compute.outputs.cdc_setup_complete : ""
}

# =============================================================================
# Lambda Trading Simulator
# =============================================================================

module "lambda_producer" {
  source = "../../modules/lambda-producer"
  count  = local.c.enable_lambda_producer ? 1 : 0

  environment              = local.env
  subnet_ids               = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  lambda_security_group_id = data.terraform_remote_state.foundation.outputs.lambda_security_group_id
  msk_cluster_arn          = data.terraform_remote_state.compute.outputs.msk_cluster_arn
  msk_bootstrap_brokers    = data.terraform_remote_state.compute.outputs.bootstrap_brokers_iam
  aurora_cluster_arn       = data.terraform_remote_state.compute.outputs.cluster_arn
  aurora_secret_arn        = data.terraform_remote_state.compute.outputs.master_password_secret_arn

  function_zip_path = "${path.module}/../../../../.build/trading-simulator.zip"
  layer_zip_path    = "${path.module}/../../../../.build/trading-simulator-layer.zip"

  schedule_enabled = true
  tags             = {}
}

# =============================================================================
# Glue ETL (medallion transforms)
# =============================================================================

module "glue_etl" {
  source = "../../modules/glue-etl"
  count  = local.c.enable_glue_etl ? 1 : 0

  environment         = local.env
  glue_role_arn       = local.glue_etl_role_arn
  scripts_bucket_id   = local.query_results_bucket_id
  mnpi_bucket_id      = local.mnpi_bucket_id
  nonmnpi_bucket_id   = local.nonmnpi_bucket_id
  worker_count        = local.c.glue_worker_count
  schedule_expression = local.c.glue_schedule
  tags                = {}
}

# =============================================================================
# Analytics (Athena workgroups)
# =============================================================================

module "analytics" {
  source                  = "../../modules/analytics"
  environment             = local.env
  query_results_bucket_id = local.query_results_bucket_id
  kms_key_arn             = local.nonmnpi_kms_alias_arn
  athena_scan_limit_bytes = local.c.athena_scan_limit_bytes
  enable_result_reuse     = local.c.enable_result_reuse
}

# =============================================================================
# Local Dev Environment (dev only — Kind cluster + ArgoCD)
# =============================================================================

resource "kind_cluster" "this" {
  count           = local.c.enable_local_dev ? 1 : 0
  name            = var.kind_cluster_name
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
      image = "kindest/node:v1.31.2"

      labels = {
        "ingress-ready" = "true"
      }

      extra_port_mappings {
        container_port = 30080
        host_port      = 8080
        protocol       = "TCP"
      }

      extra_mounts {
        host_path      = abspath("${path.module}/../../../..")
        container_path = "/mnt/data-lake-platform"
        read_only      = true
      }
    }

    node {
      role  = "worker"
      image = "kindest/node:v1.31.2"

      labels = {
        "workload" = "applications"
      }

      extra_mounts {
        host_path      = abspath("${path.module}/../../../..")
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

module "local_dev" {
  source = "../../modules/local-dev"
  count  = local.c.enable_local_dev ? 1 : 0

  cluster_name    = var.kind_cluster_name
  kubeconfig_path = kind_cluster.this[0].kubeconfig_path

  depends_on = [kind_cluster.this]
}
