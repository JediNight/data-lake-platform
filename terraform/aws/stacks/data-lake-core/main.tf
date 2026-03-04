/**
 * Stack 2: Data Lake Core — S3 buckets, KMS keys, Glue catalog
 *
 * Upstream deps: none (S3/KMS/Glue are account-level, zero VPC dependency)
 * Note: Bucket DENY policies moved to security stack.
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
      Stack       = "data-lake-core"
    }
  }
}

# =============================================================================
# Data Lake Storage (S3 buckets + KMS — without bucket DENY policies)
# =============================================================================

module "data_lake_storage" {
  source                 = "../../modules/data-lake-storage"
  environment            = local.env
  raw_ia_transition_days = local.c.raw_ia_transition_days
}

# =============================================================================
# Glue Catalog (databases + schema registry)
# =============================================================================

module "glue_catalog" {
  source            = "../../modules/glue-catalog"
  environment       = local.env
  mnpi_bucket_id    = module.data_lake_storage.mnpi_bucket_id
  nonmnpi_bucket_id = module.data_lake_storage.nonmnpi_bucket_id
}
