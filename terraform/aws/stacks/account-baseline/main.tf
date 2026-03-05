/**
 * Stack 0: Account Baseline — Account-global singletons
 *
 * This stack manages resources that exist once per AWS account and cannot
 * be workspace-isolated. Deploy once (default workspace), then deploy
 * the workspace-based stacks (foundation, data-lake-core, security,
 * compute, pipelines) for each environment.
 *
 * Contains:
 *   - IAM Identity Center groups, permission sets, demo users
 *   - Lake Formation data lake settings + LF-Tags
 *   - Lake Formation Identity Center (trusted identity propagation)
 *   - QuickSight account subscription
 *
 * Upstream deps: none
 * Downstream consumers: security stack (looks up groups via data sources)
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
      Project   = "data-lake-platform"
      ManagedBy = "terraform"
      Stack     = "account-baseline"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_ssoadmin_instances" "this" {}

# =============================================================================
# Identity Center (SSO groups + permission sets + demo users)
# =============================================================================
# Uses wildcard bucket ARN patterns so permission sets work across all
# environments (dev, prod). Fine-grained data access is controlled by
# Lake Formation LF-Tag grants in the security stack.
# =============================================================================

module "identity_center" {
  source                   = "../../modules/identity-center"
  environment              = "shared"
  mnpi_bucket_arn          = local.mnpi_bucket_arn_pattern
  nonmnpi_bucket_arn       = local.nonmnpi_bucket_arn_pattern
  query_results_bucket_arn = local.query_results_bucket_arn_pattern
}

# =============================================================================
# Lake Formation — Account-Level Settings
# =============================================================================
# These are account-global singletons that must be created once. The security
# stack creates environment-scoped resources (tag assignments, grants,
# S3 registrations) that reference these settings.
# =============================================================================

# Resolve the STS session ARN to the permanent IAM role ARN.
# Lake Formation rejects assumed-role (temporary credential) ARNs.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

resource "aws_lakeformation_data_lake_settings" "this" {
  admins = [var.admin_role_arn != "" ? var.admin_role_arn : data.aws_iam_session_context.current.issuer_arn]

  # Omitting create_database_default_permissions and
  # create_table_default_permissions removes the default
  # IAMAllowedPrincipals grants, forcing all access through
  # Lake Formation grants rather than plain IAM.
}

resource "aws_lakeformation_identity_center_configuration" "this" {
  instance_arn = module.identity_center.sso_instance_arn

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

resource "aws_lakeformation_lf_tag" "sensitivity" {
  key    = "sensitivity"
  values = ["mnpi", "non-mnpi"]

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_lf_tag" "layer" {
  key    = "layer"
  values = ["raw", "curated", "analytics"]

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

# =============================================================================
# QuickSight Account Subscription (one per AWS account)
# =============================================================================

resource "aws_quicksight_account_subscription" "this" {
  count = var.enable_quicksight ? 1 : 0

  account_name          = "datalake-${local.account_id}"
  edition               = "STANDARD"
  authentication_method = "IAM_AND_QUICKSIGHT"
  notification_email    = "admin@example.com"

  lifecycle {
    ignore_changes = [account_name, authentication_method]
  }
}
