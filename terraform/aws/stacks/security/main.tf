/**
 * Stack 3: Security — IAM, Lake Formation, observability, bucket policies
 *
 * Upstream deps: account-baseline (Identity Center groups, LF settings, LF-Tags)
 *                — referenced via AWS data sources, not terraform_remote_state
 * Contains: service_roles, lake_formation (grants/registrations only),
 *           observability, plus S3 bucket DENY policies
 *
 * Account-global singletons (Identity Center groups, LF data lake settings,
 * LF-Tags, QuickSight subscription) live in the account-baseline stack.
 * This stack only creates environment-scoped resources.
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
data "aws_ssoadmin_instances" "this" {}

data "aws_identitystore_group" "admins" {
  identity_store_id = data.aws_ssoadmin_instances.this.identity_store_ids[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "Admins"
    }
  }
}

data "aws_identitystore_group" "reviewers" {
  identity_store_id = data.aws_ssoadmin_instances.this.identity_store_ids[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "Reviewers"
    }
  }
}

# =============================================================================
# Identity Center Group Lookups
# =============================================================================
# Groups are created by the account-baseline stack. This stack looks them up
# via data sources to pass their IDs to Lake Formation for ABAC grants.
# =============================================================================

data "aws_identitystore_group" "finance_analysts" {
  identity_store_id = data.aws_ssoadmin_instances.this.identity_store_ids[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "FinanceAnalysts"
    }
  }
}

data "aws_identitystore_group" "data_analysts" {
  identity_store_id = data.aws_ssoadmin_instances.this.identity_store_ids[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "DataAnalysts"
    }
  }
}

data "aws_identitystore_group" "data_engineers" {
  identity_store_id = data.aws_ssoadmin_instances.this.identity_store_ids[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "DataEngineers"
    }
  }
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

  # KMS variables are no longer used for IAM policy Resource elements —
  # the module uses key/* with kms:ViaService condition instead.
  # These are kept for interface compatibility.
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
# Lake Formation (ABAC grants, S3 location registration, tag assignments)
# =============================================================================
# Account-global singletons (data_lake_settings, identity_center_configuration,
# LF-Tags) are managed by the account-baseline stack. This module only creates
# environment-scoped resources: tag assignments, S3 registrations, and grants.
# =============================================================================

module "lake_formation" {
  source                    = "../../modules/lake-formation"
  environment               = local.env
  create_account_settings   = false
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
  quicksight_role_arn       = local.c.enable_quicksight ? "arn:aws:iam::${local.account_id}:role/service-role/aws-quicksight-service-role-v0" : ""
  admins_group_id           = data.aws_identitystore_group.admins.group_id
  reviewers_group_id        = data.aws_identitystore_group.reviewers.group_id
}

# =============================================================================
# Observability (CloudTrail, CloudWatch, QuickSight)
# =============================================================================

module "observability" {
  source                         = "../../modules/observability"
  environment                    = local.env
  account_id                     = local.account_id
  mnpi_bucket_arn                = local.mnpi_bucket_arn
  nonmnpi_bucket_arn             = local.nonmnpi_bucket_arn
  audit_bucket_arn               = local.audit_bucket_arn
  audit_bucket_id                = local.audit_bucket_id
  log_retention_days             = local.c.audit_retention_days
  enable_quicksight              = local.c.enable_quicksight
  create_quicksight_subscription = false # managed by account-baseline stack
  query_results_bucket_arn       = local.query_results_bucket_arn
  athena_workgroup_name          = "data-engineers-${local.env}"
  quicksight_kms_key_arn         = local.nonmnpi_kms_alias_arn
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
