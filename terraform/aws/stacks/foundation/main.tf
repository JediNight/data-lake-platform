/**
 * Stack 1: Foundation — VPC, subnets, security groups
 *
 * Upstream deps: none
 * Downstream consumers: compute (VPC/SG IDs), pipelines (subnet/SG IDs)
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
      Stack       = "foundation"
    }
  }
}

# =============================================================================
# Networking
# =============================================================================

module "networking" {
  source      = "../../modules/networking"
  environment = local.env
  vpc_cidr    = var.vpc_cidr
}
