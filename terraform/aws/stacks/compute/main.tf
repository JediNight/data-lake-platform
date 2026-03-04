/**
 * Stack 4: Compute — MSK cluster + Aurora PostgreSQL
 *
 * Upstream deps: foundation (VPC/subnet/SG IDs via terraform_remote_state)
 * Downstream consumers: pipelines (MSK brokers, Aurora endpoint)
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
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "data-lake-platform"
      Environment = local.env
      ManagedBy   = "terraform"
      Stack       = "compute"
    }
  }
}

# =============================================================================
# Streaming (MSK)
# =============================================================================

module "streaming" {
  source = "../../modules/streaming"
  count  = local.c.enable_msk ? 1 : 0

  environment                = local.env
  broker_instance_type       = local.c.broker_instance_type
  broker_count               = local.c.broker_count
  default_replication_factor = local.c.default_replication_factor
  subnet_ids                 = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  msk_security_group_id      = data.terraform_remote_state.foundation.outputs.msk_security_group_id
}

# =============================================================================
# Aurora PostgreSQL
# =============================================================================

module "aurora_postgres" {
  source = "../../modules/aurora-postgres"
  count  = local.c.enable_aurora ? 1 : 0

  environment    = local.env
  vpc_id         = data.terraform_remote_state.foundation.outputs.vpc_id
  subnet_ids     = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  instance_class = local.c.aurora_instance_class
  instance_count = local.c.aurora_instance_count

  allowed_security_group_ids = compact([
    local.c.enable_msk_connect ? data.terraform_remote_state.foundation.outputs.msk_security_group_id : "",
    data.terraform_remote_state.foundation.outputs.lambda_security_group_id,
  ])
}
