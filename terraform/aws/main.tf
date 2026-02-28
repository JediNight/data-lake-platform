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
      version = "~> 5.0"
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
  ]
  raw_ia_transition_days = local.c.raw_ia_transition_days
}

# =============================================================================
# Streaming (MSK)
# =============================================================================

module "streaming" {
  source                     = "./modules/streaming"
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
  msk_cluster_arn    = module.streaming.cluster_arn

  # Wired from EKS module when enabled (prod), empty strings for dev
  eks_oidc_provider_arn = local.c.enable_eks ? module.eks[0].oidc_provider_arn : ""
  eks_oidc_provider_url = local.c.enable_eks ? module.eks[0].oidc_provider_url : ""
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
  source             = "./modules/observability"
  environment        = local.env
  account_id         = data.aws_caller_identity.current.account_id
  mnpi_bucket_arn    = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn = module.data_lake_storage.nonmnpi_bucket_arn
  audit_bucket_arn   = module.data_lake_storage.audit_bucket_arn
  audit_bucket_id    = module.data_lake_storage.audit_bucket_id
  log_retention_days = local.c.audit_retention_days
  enable_quicksight  = local.c.enable_quicksight
}

# =============================================================================
# EKS Cluster (prod only)
# =============================================================================

module "eks" {
  source = "./modules/eks"
  count  = local.c.enable_eks ? 1 : 0

  environment        = local.env
  cluster_name       = "data-lake-${local.env}"
  subnet_ids         = module.networking.private_subnet_ids
  node_instance_type = local.c.eks_node_instance_type
  node_count         = local.c.eks_node_count
  vpc_id             = module.networking.vpc_id
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

  # Allow ingress from EKS node security group
  allowed_security_group_ids = local.c.enable_eks ? [module.eks[0].node_security_group_id] : []
}

# =============================================================================
# MSK Connect (prod only — managed Debezium source + Iceberg S3 sink)
# =============================================================================

module "msk_connect" {
  source = "./modules/msk-connect"
  count  = local.c.enable_msk_connect ? 1 : 0

  environment            = local.env
  msk_cluster_arn        = module.streaming.cluster_arn
  msk_bootstrap_brokers  = module.streaming.bootstrap_brokers_iam
  subnet_ids             = module.networking.private_subnet_ids
  security_group_ids     = [module.networking.msk_security_group_id]
  mnpi_bucket_arn        = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn     = module.data_lake_storage.nonmnpi_bucket_arn
  kafka_connect_role_arn = module.service_roles.kafka_connect_role_arn

  # Aurora connection info
  postgres_endpoint = local.c.enable_aurora ? module.aurora_postgres[0].cluster_endpoint : ""
  postgres_port     = local.c.enable_aurora ? module.aurora_postgres[0].cluster_port : 5432
}
