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
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

module "networking" {
  source      = "../../modules/networking"
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
}

module "data_lake_storage" {
  source      = "../../modules/data-lake-storage"
  environment = var.environment
  allowed_principal_arns = [
    module.identity_center.data_engineer_sso_role_pattern,
    module.service_roles.kafka_connect_role_arn,
  ]
  raw_ia_transition_days = var.raw_ia_transition_days
}

module "streaming" {
  source                     = "../../modules/streaming"
  environment                = var.environment
  broker_instance_type       = var.broker_instance_type
  broker_count               = var.broker_count
  default_replication_factor = var.default_replication_factor
  subnet_ids                 = module.networking.private_subnet_ids
  msk_security_group_id      = module.networking.msk_security_group_id
}

module "glue_catalog" {
  source            = "../../modules/glue-catalog"
  environment       = var.environment
  mnpi_bucket_id    = module.data_lake_storage.mnpi_bucket_id
  nonmnpi_bucket_id = module.data_lake_storage.nonmnpi_bucket_id
}

module "identity_center" {
  source                   = "../../modules/identity-center"
  environment              = var.environment
  mnpi_bucket_arn          = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn       = module.data_lake_storage.nonmnpi_bucket_arn
  query_results_bucket_arn = module.data_lake_storage.query_results_bucket_arn
}

module "service_roles" {
  source                = "../../modules/service-roles"
  environment           = var.environment
  mnpi_bucket_arn       = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn    = module.data_lake_storage.nonmnpi_bucket_arn
  glue_registry_arn     = module.glue_catalog.registry_arn
  msk_cluster_arn       = module.streaming.cluster_arn
  eks_oidc_provider_arn = var.eks_oidc_provider_arn
  eks_oidc_provider_url = var.eks_oidc_provider_url
}

module "lake_formation" {
  source                    = "../../modules/lake-formation"
  environment               = var.environment
  database_names            = module.glue_catalog.database_names
  mnpi_bucket_arn           = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn        = module.data_lake_storage.nonmnpi_bucket_arn
  finance_analysts_group_id = module.identity_center.finance_analysts_group_id
  data_analysts_group_id    = module.identity_center.data_analysts_group_id
  data_engineers_group_id   = module.identity_center.data_engineers_group_id
  admin_role_arn            = var.admin_role_arn
}

module "analytics" {
  source                  = "../../modules/analytics"
  environment             = var.environment
  query_results_bucket_id = module.data_lake_storage.query_results_bucket_id
  kms_key_arn             = module.data_lake_storage.nonmnpi_kms_key_arn
  athena_scan_limit_bytes = var.athena_scan_limit_bytes
  enable_result_reuse     = var.enable_result_reuse
}

module "observability" {
  source             = "../../modules/observability"
  environment        = var.environment
  account_id         = data.aws_caller_identity.current.account_id
  mnpi_bucket_arn    = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn = module.data_lake_storage.nonmnpi_bucket_arn
  audit_bucket_arn   = module.data_lake_storage.audit_bucket_arn
  audit_bucket_id    = module.data_lake_storage.audit_bucket_id
  log_retention_days = var.audit_retention_days
  enable_quicksight  = var.enable_quicksight
}
