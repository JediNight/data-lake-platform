/**
 * Stack 3: Security — IAM, Lake Formation, observability, bucket policies
 *
 * Upstream deps: none (all references use deterministic ARN construction)
 * Contains: identity_center, service_roles, lake_formation, observability,
 *           plus S3 bucket DENY policies (extracted from data-lake-storage)
 */

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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
      Stack       = "security"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# Identity Center (SSO groups + permission sets)
# =============================================================================

module "identity_center" {
  source                   = "../../modules/identity-center"
  environment              = local.env
  mnpi_bucket_arn          = local.mnpi_bucket_arn
  nonmnpi_bucket_arn       = local.nonmnpi_bucket_arn
  query_results_bucket_arn = local.query_results_bucket_arn
}

# =============================================================================
# Service Roles (Kafka Connect + Glue ETL IAM roles)
# =============================================================================

module "service_roles" {
  source             = "../../modules/service-roles"
  environment        = local.env
  mnpi_bucket_arn    = local.mnpi_bucket_arn
  nonmnpi_bucket_arn = local.nonmnpi_bucket_arn
  glue_registry_arn  = local.glue_registry_arn
  msk_cluster_arn    = local.msk_cluster_arn

  # KMS alias ARNs (not key ARNs — key IDs are non-deterministic UUIDs)
  mnpi_kms_key_arn         = local.mnpi_kms_alias_arn
  nonmnpi_kms_key_arn      = local.nonmnpi_kms_alias_arn
  query_results_bucket_arn = local.query_results_bucket_arn

  extra_s3_read_bucket_arns = [
    "arn:aws:s3:::datalake-local-iceberg-${local.env}",
  ]

  enable_aurora     = local.c.enable_aurora
  aurora_secret_arn = local.aurora_secret_arn

  # EKS removed — serverless architecture
  eks_oidc_provider_arn = ""
  eks_oidc_provider_url = ""
}

# =============================================================================
# Lake Formation (LF-tags, ABAC grants, S3 location registration)
# =============================================================================

# Identity Center group IDs are non-deterministic (AWS-assigned UUIDs).
# Look them up by display name instead of terraform_remote_state.
data "aws_ssoadmin_instances" "this" {}

data "aws_identitystore_group" "finance_analysts" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "FinanceAnalysts"
    }
  }
}

data "aws_identitystore_group" "data_analysts" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "DataAnalysts"
    }
  }
}

data "aws_identitystore_group" "data_engineers" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "DataEngineers"
    }
  }
}

module "lake_formation" {
  source                    = "../../modules/lake-formation"
  environment               = local.env
  database_names            = local.database_names
  mnpi_bucket_arn           = local.mnpi_bucket_arn
  nonmnpi_bucket_arn        = local.nonmnpi_bucket_arn
  finance_analysts_group_id = data.aws_identitystore_group.finance_analysts.group_id
  data_analysts_group_id    = data.aws_identitystore_group.data_analysts.group_id
  data_engineers_group_id   = data.aws_identitystore_group.data_engineers.group_id
  admin_role_arn            = var.admin_role_arn
  sso_instance_arn          = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  glue_etl_role_arn         = module.service_roles.glue_etl_role_arn
  kafka_connect_role_arn    = module.service_roles.kafka_connect_role_arn
}

# =============================================================================
# Observability (CloudTrail, CloudWatch, QuickSight)
# =============================================================================

module "observability" {
  source                   = "../../modules/observability"
  environment              = local.env
  account_id               = local.account_id
  mnpi_bucket_arn          = local.mnpi_bucket_arn
  nonmnpi_bucket_arn       = local.nonmnpi_bucket_arn
  audit_bucket_arn         = local.audit_bucket_arn
  audit_bucket_id          = local.audit_bucket_id
  log_retention_days       = local.c.audit_retention_days
  enable_quicksight        = local.c.enable_quicksight
  query_results_bucket_arn = local.query_results_bucket_arn
  athena_workgroup_name    = "data-engineers-${local.env}"
  quicksight_kms_key_arn   = local.nonmnpi_kms_alias_arn
}

# =============================================================================
# Bucket DENY Policies — Lake Formation Bypass Prevention
# =============================================================================
# Migrated from data-lake-storage module. These DENY direct S3 access
# for all principals EXCEPT Lake Formation service and exempt roles.
# All ARNs are constructed deterministically — no cross-stack dependency.
# =============================================================================

resource "aws_s3_bucket_policy" "mnpi" {
  bucket = "datalake-mnpi-${local.env}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDirectS3AccessExceptAllowed"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${local.mnpi_bucket_arn}/*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalServiceName" = "lakeformation.amazonaws.com"
          }
          ArnNotLike = {
            "aws:PrincipalArn" = local.bucket_deny_exempt_arns
          }
        }
      },
    ]
  })
}

resource "aws_s3_bucket_policy" "nonmnpi" {
  bucket = "datalake-nonmnpi-${local.env}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDirectS3AccessExceptAllowed"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${local.nonmnpi_bucket_arn}/*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalServiceName" = "lakeformation.amazonaws.com"
          }
          ArnNotLike = {
            "aws:PrincipalArn" = local.bucket_deny_exempt_arns
          }
        }
      },
    ]
  })
}
