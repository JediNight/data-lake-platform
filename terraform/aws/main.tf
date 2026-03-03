/**
 * data-lake-platform — AWS Infrastructure
 *
 * Workspace-based root module. Uses `terraform.workspace` (dev | prod) to
 * drive per-environment config from locals.tf.
 *
 * Usage:
 *   terraform workspace select dev
 *   terraform plan  -var-file=dev.tfvars
 *   terraform apply -var-file=dev.tfvars
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
    }
  }
}

provider "kind" {}

provider "helm" {
  kubernetes {
    host                   = try(kind_cluster.this[0].endpoint, "")
    client_certificate     = try(kind_cluster.this[0].client_certificate, "")
    client_key             = try(kind_cluster.this[0].client_key, "")
    cluster_ca_certificate = try(kind_cluster.this[0].cluster_ca_certificate, "")
  }
}

provider "kubernetes" {
  host                   = try(kind_cluster.this[0].endpoint, "")
  client_certificate     = try(kind_cluster.this[0].client_certificate, "")
  client_key             = try(kind_cluster.this[0].client_key, "")
  cluster_ca_certificate = try(kind_cluster.this[0].cluster_ca_certificate, "")
}

provider "kubectl" {
  host                   = try(kind_cluster.this[0].endpoint, "")
  client_certificate     = try(kind_cluster.this[0].client_certificate, "")
  client_key             = try(kind_cluster.this[0].client_key, "")
  cluster_ca_certificate = try(kind_cluster.this[0].cluster_ca_certificate, "")
  load_config_file       = false
}

data "aws_caller_identity" "current" {}

# =============================================================================
# Networking
# =============================================================================

module "networking" {
  source      = "./modules/networking"
  environment = local.env
  vpc_cidr    = var.vpc_cidr
}

# =============================================================================
# Data Lake Storage (S3 buckets — MNPI, non-MNPI, audit, query results)
# =============================================================================

module "data_lake_storage" {
  source      = "./modules/data-lake-storage"
  environment = local.env
  allowed_principal_arns = [
    module.identity_center.data_engineer_sso_role_pattern,
    module.service_roles.kafka_connect_role_arn,
    module.service_roles.glue_etl_role_arn,
  ]
  raw_ia_transition_days = local.c.raw_ia_transition_days
}

# =============================================================================
# Streaming (MSK)
# =============================================================================

module "streaming" {
  source = "./modules/streaming"
  count  = local.c.enable_msk ? 1 : 0

  environment                = local.env
  broker_instance_type       = local.c.broker_instance_type
  broker_count               = local.c.broker_count
  default_replication_factor = local.c.default_replication_factor
  subnet_ids                 = module.networking.private_subnet_ids
  msk_security_group_id      = module.networking.msk_security_group_id
}

# =============================================================================
# Glue Catalog
# =============================================================================

module "glue_catalog" {
  source            = "./modules/glue-catalog"
  environment       = local.env
  mnpi_bucket_id    = module.data_lake_storage.mnpi_bucket_id
  nonmnpi_bucket_id = module.data_lake_storage.nonmnpi_bucket_id
}

# =============================================================================
# Identity Center (SSO groups + permission sets)
# =============================================================================

module "identity_center" {
  source                   = "./modules/identity-center"
  environment              = local.env
  mnpi_bucket_arn          = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn       = module.data_lake_storage.nonmnpi_bucket_arn
  query_results_bucket_arn = module.data_lake_storage.query_results_bucket_arn
}

# =============================================================================
# Service Roles (IRSA for Kafka Connect, etc.)
# =============================================================================

module "service_roles" {
  source             = "./modules/service-roles"
  environment        = local.env
  mnpi_bucket_arn    = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn = module.data_lake_storage.nonmnpi_bucket_arn
  glue_registry_arn  = module.glue_catalog.registry_arn
  msk_cluster_arn    = local.c.enable_msk ? module.streaming[0].cluster_arn : ""

  # Glue ETL role needs KMS keys for encrypted S3 data and scripts bucket
  mnpi_kms_key_arn         = module.data_lake_storage.mnpi_kms_key_arn
  nonmnpi_kms_key_arn      = module.data_lake_storage.nonmnpi_kms_key_arn
  query_results_bucket_arn = module.data_lake_storage.query_results_bucket_arn

  # Dev: raw tables live in the local-iceberg bucket (Phase 1 Athena SQL);
  # Glue ETL needs read access to load source Iceberg metadata + data.
  extra_s3_read_bucket_arns = [
    "arn:aws:s3:::datalake-local-iceberg-${local.env}",
  ]

  # Aurora secret for Debezium CDC (Kafka Connect SecretsManagerConfigProvider)
  enable_aurora     = local.c.enable_aurora
  aurora_secret_arn = local.c.enable_aurora ? module.aurora_postgres[0].master_password_secret_arn : ""

  # EKS removed — serverless architecture (Lambda + MSK Connect)
  eks_oidc_provider_arn = ""
  eks_oidc_provider_url = ""
}

# =============================================================================
# Lake Formation
# =============================================================================

module "lake_formation" {
  source                    = "./modules/lake-formation"
  environment               = local.env
  database_names            = module.glue_catalog.database_names
  mnpi_bucket_arn           = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn        = module.data_lake_storage.nonmnpi_bucket_arn
  finance_analysts_group_id = module.identity_center.finance_analysts_group_id
  data_analysts_group_id    = module.identity_center.data_analysts_group_id
  data_engineers_group_id   = module.identity_center.data_engineers_group_id
  admin_role_arn            = var.admin_role_arn
  sso_instance_arn          = module.identity_center.sso_instance_arn
  glue_etl_role_arn         = module.service_roles.glue_etl_role_arn
  kafka_connect_role_arn    = module.service_roles.kafka_connect_role_arn
}

# =============================================================================
# Analytics (Athena workgroups)
# =============================================================================

module "analytics" {
  source                  = "./modules/analytics"
  environment             = local.env
  query_results_bucket_id = module.data_lake_storage.query_results_bucket_id
  kms_key_arn             = module.data_lake_storage.nonmnpi_kms_key_arn
  athena_scan_limit_bytes = local.c.athena_scan_limit_bytes
  enable_result_reuse     = local.c.enable_result_reuse
}

# =============================================================================
# Observability (CloudTrail, CloudWatch, dashboards)
# =============================================================================

module "observability" {
  source                   = "./modules/observability"
  environment              = local.env
  account_id               = data.aws_caller_identity.current.account_id
  mnpi_bucket_arn          = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn       = module.data_lake_storage.nonmnpi_bucket_arn
  audit_bucket_arn         = module.data_lake_storage.audit_bucket_arn
  audit_bucket_id          = module.data_lake_storage.audit_bucket_id
  log_retention_days       = local.c.audit_retention_days
  enable_quicksight        = local.c.enable_quicksight
  query_results_bucket_arn = module.data_lake_storage.query_results_bucket_arn
  athena_workgroup_name    = "data-engineers-${local.env}"
  quicksight_kms_key_arn   = module.data_lake_storage.nonmnpi_kms_key_arn
}

# =============================================================================
# Glue ETL (medallion transforms — raw → curated → analytics)
# =============================================================================

module "glue_etl" {
  source = "./modules/glue-etl"
  count  = local.c.enable_glue_etl ? 1 : 0

  environment         = local.env
  glue_role_arn       = module.service_roles.glue_etl_role_arn
  scripts_bucket_id   = module.data_lake_storage.query_results_bucket_id
  mnpi_bucket_id      = module.data_lake_storage.mnpi_bucket_id
  nonmnpi_bucket_id   = module.data_lake_storage.nonmnpi_bucket_id
  worker_count        = local.c.glue_worker_count
  schedule_expression = local.c.glue_schedule
  tags                = {}
}

# =============================================================================
# Aurora PostgreSQL (prod only)
# =============================================================================

module "aurora_postgres" {
  source = "./modules/aurora-postgres"
  count  = local.c.enable_aurora ? 1 : 0

  environment    = local.env
  vpc_id         = module.networking.vpc_id
  subnet_ids     = module.networking.private_subnet_ids
  instance_class = local.c.aurora_instance_class
  instance_count = local.c.aurora_instance_count

  # Allow ingress from MSK Connect (Debezium) and Lambda producer
  allowed_security_group_ids = compact([
    local.c.enable_msk_connect ? module.networking.msk_security_group_id : "",
    module.networking.lambda_security_group_id,
  ])
}

# =============================================================================
# MSK Connect (prod only — managed Debezium source + Iceberg S3 sink)
# =============================================================================

module "msk_connect" {
  source = "./modules/msk-connect"
  count  = local.c.enable_msk_connect ? 1 : 0

  environment            = local.env
  msk_cluster_arn        = module.streaming[0].cluster_arn
  msk_bootstrap_brokers  = module.streaming[0].bootstrap_brokers_iam
  subnet_ids             = module.networking.private_subnet_ids
  security_group_ids     = [module.networking.msk_security_group_id]
  mnpi_bucket_arn        = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn     = module.data_lake_storage.nonmnpi_bucket_arn
  kafka_connect_role_arn     = module.service_roles.kafka_connect_role_arn
  default_replication_factor = local.c.default_replication_factor

  # Aurora connection — Debezium requires Aurora + CDC setup (replication slot, publication, Secrets Manager)
  enable_debezium_connector = try(local.c.enable_debezium_connector, false)
  postgres_endpoint         = local.c.enable_aurora ? module.aurora_postgres[0].cluster_endpoint : ""
  postgres_port             = local.c.enable_aurora ? module.aurora_postgres[0].cluster_port : 5432
  aurora_secret_arn         = local.c.enable_aurora ? module.aurora_postgres[0].master_password_secret_arn : ""
  aurora_cdc_setup_id       = local.c.enable_aurora ? module.aurora_postgres[0].cdc_setup_complete : ""
}

# =============================================================================
# Lambda Trading Simulator (prod only — EventBridge → Lambda → Aurora + MSK)
# =============================================================================

module "lambda_producer" {
  source = "./modules/lambda-producer"
  count  = local.c.enable_lambda_producer ? 1 : 0

  environment              = local.env
  subnet_ids               = module.networking.private_subnet_ids
  lambda_security_group_id = module.networking.lambda_security_group_id
  msk_cluster_arn          = module.streaming[0].cluster_arn
  msk_bootstrap_brokers    = module.streaming[0].bootstrap_brokers_iam
  aurora_cluster_arn       = module.aurora_postgres[0].cluster_arn
  aurora_secret_arn        = module.aurora_postgres[0].master_password_secret_arn

  function_zip_path = "${path.module}/../../.build/trading-simulator.zip"
  layer_zip_path    = "${path.module}/../../.build/trading-simulator-layer.zip"

  schedule_enabled = true
  tags             = {}
}

# =============================================================================
# Local Dev Environment (dev only — Kind cluster + ArgoCD + Strimzi)
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
        host_path      = abspath("${path.module}/../..")
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
        host_path      = abspath("${path.module}/../..")
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
  source = "./modules/local-dev"
  count  = local.c.enable_local_dev ? 1 : 0

  cluster_name    = var.kind_cluster_name
  kubeconfig_path = kind_cluster.this[0].kubeconfig_path

  depends_on = [kind_cluster.this]
}
