/**
 * lake-formation -- LF-Tags, Tag-Based Grants & S3 Location Registrations
 *
 * This is the core security module for the data lake.  It uses Lake
 * Formation's attribute-based access control (ABAC) via LF-Tags to enforce
 * the following access model:
 *
 *   - Finance analysts: SELECT on curated + analytics layers, MNPI + non-MNPI
 *   - Data analysts:    SELECT on curated + analytics layers, non-MNPI only
 *   - Data engineers:   ALL on every layer and sensitivity, plus direct S3
 *
 * Grant principals are IAM Identity Center groups (via trusted identity
 * propagation) rather than IAM role ARNs.
 *
 * When new tables are added to a database they automatically inherit the
 * database's LF-Tags, so grants apply without any Terraform changes.
 */

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# =============================================================================
# Locals
# =============================================================================

locals {
  common_tags = merge(var.tags, {
    Module      = "lake-formation"
    Environment = var.environment
  })

  # Map of logical database name -> LF-Tag values.
  # Keys must match the keys in var.database_names (output of glue-catalog).
  database_tags = {
    raw_mnpi = {
      sensitivity = "mnpi"
      layer       = "raw"
    }
    raw_nonmnpi = {
      sensitivity = "non-mnpi"
      layer       = "raw"
    }
    curated_mnpi = {
      sensitivity = "mnpi"
      layer       = "curated"
    }
    curated_nonmnpi = {
      sensitivity = "non-mnpi"
      layer       = "curated"
    }
    analytics_mnpi = {
      sensitivity = "mnpi"
      layer       = "analytics"
    }
    analytics_nonmnpi = {
      sensitivity = "non-mnpi"
      layer       = "analytics"
    }
  }
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}

# Resolve the STS session ARN to the permanent IAM role ARN.
# Lake Formation rejects assumed-role (temporary credential) ARNs.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# =============================================================================
# Lake Formation Data Lake Settings
# =============================================================================
# Set the admin principal and override the default IAMAllowedPrincipals so
# that Lake Formation permissions are actually enforced (rather than falling
# back to IAM-only access control).
# =============================================================================

resource "aws_lakeformation_data_lake_settings" "this" {
  admins = [var.admin_role_arn != "" ? var.admin_role_arn : data.aws_iam_session_context.current.issuer_arn]

  # Omitting create_database_default_permissions and
  # create_table_default_permissions removes the default
  # IAMAllowedPrincipals grants, forcing all access through
  # Lake Formation grants rather than plain IAM.
}

# =============================================================================
# Identity Center Configuration (Trusted Identity Propagation)
# =============================================================================
# Bridges Lake Formation to IAM Identity Center for trusted identity
# propagation.  Requires provider >= 6.19 (resource shipped Oct 2025,
# hashicorp/terraform-provider-aws PR #44867).
# =============================================================================

resource "aws_lakeformation_identity_center_configuration" "this" {
  instance_arn = var.sso_instance_arn

  # NOTE: The console-configured "AWS account and organization IDs" (ShareRecipients)
  # are NOT managed here because the Terraform provider has not implemented the
  # share_recipients attribute yet (hashicorp/terraform-provider-aws#44866).
  # Current recipients (configured via console):
  #   - Account: 445985103066
  # This is a single-account deployment; cross-account RAM sharing is not used.

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

# =============================================================================
# LF-Tags (2 tag keys)
# =============================================================================

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
# Tag Assignments to Databases (for_each over 6 databases)
# =============================================================================
# Attach both LF-Tags (sensitivity + layer) to each Glue Catalog database.
# This is what makes the tag-based grants below work: tables created inside
# these databases inherit the tags automatically.
# =============================================================================

resource "aws_lakeformation_resource_lf_tags" "database" {
  for_each = local.database_tags

  database {
    name = var.database_names[each.key]
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.sensitivity.key
    value = each.value.sensitivity
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.layer.key
    value = each.value.layer
  }
}

# =============================================================================
# S3 Location Registrations
# =============================================================================
# Register both data-lake S3 buckets with Lake Formation so it can vend
# temporary credentials for data access.  Uses the service-linked role
# (created automatically on first registration).
# =============================================================================

resource "aws_lakeformation_resource" "mnpi_bucket" {
  arn = var.mnpi_bucket_arn
}

resource "aws_lakeformation_resource" "nonmnpi_bucket" {
  arn = var.nonmnpi_bucket_arn
}

# =============================================================================
# Tag-Based Grants
# =============================================================================
#
# The lf_tag_policy block grants permissions to any resource whose LF-Tags
# match ALL expressions (AND logic).  Each expression allows multiple values
# (OR within a single tag key).
#
# Grant structure:
#   1. finance-analyst  -- SELECT on DATABASE & TABLE where
#                          sensitivity IN [mnpi, non-mnpi] AND
#                          layer IN [curated, analytics]
#   2. data-analyst     -- SELECT on DATABASE & TABLE where
#                          sensitivity = [non-mnpi] AND
#                          layer IN [curated, analytics]
#   3. data-engineer    -- ALL on DATABASE & TABLE for all tag values
#                          + DATA_LOCATION_ACCESS on registered S3 locations
# =============================================================================

# -----------------------------------------------------------------------------
# Tag-Based Grants (native aws_lakeformation_permissions)
# -----------------------------------------------------------------------------
# Provider v6.x replaces the old null_resource + local-exec workaround.
# The v5.x provider couldn't read back LF-tag-policy permissions granted to
# Identity Center group principals.  If v6.x still has this issue, these
# resources will fail on apply and we'll revert to the CLI workaround
# (preserved in git history).
# -----------------------------------------------------------------------------

locals {
  # LF-tag-policy grants: each entry maps to one aws_lakeformation_permissions
  lf_tag_policy_grants = {
    # 1. Finance Analyst
    finance_analyst_db = {
      principal     = "arn:aws:identitystore:::group/${var.finance_analysts_group_id}"
      permissions   = ["DESCRIBE"]
      resource_type = "DATABASE"
      expression = [
        { key = "sensitivity", values = ["mnpi", "non-mnpi"] },
        { key = "layer", values = ["curated", "analytics"] },
      ]
    }
    finance_analyst_table = {
      principal     = "arn:aws:identitystore:::group/${var.finance_analysts_group_id}"
      permissions   = ["SELECT", "DESCRIBE"]
      resource_type = "TABLE"
      expression = [
        { key = "sensitivity", values = ["mnpi", "non-mnpi"] },
        { key = "layer", values = ["curated", "analytics"] },
      ]
    }

    # 2. Data Analyst
    data_analyst_db = {
      principal     = "arn:aws:identitystore:::group/${var.data_analysts_group_id}"
      permissions   = ["DESCRIBE"]
      resource_type = "DATABASE"
      expression = [
        { key = "sensitivity", values = ["non-mnpi"] },
        { key = "layer", values = ["curated", "analytics"] },
      ]
    }
    data_analyst_table = {
      principal     = "arn:aws:identitystore:::group/${var.data_analysts_group_id}"
      permissions   = ["SELECT", "DESCRIBE"]
      resource_type = "TABLE"
      expression = [
        { key = "sensitivity", values = ["non-mnpi"] },
        { key = "layer", values = ["curated", "analytics"] },
      ]
    }

    # 3. Data Engineer
    data_engineer_db = {
      principal     = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
      permissions   = ["ALL"]
      resource_type = "DATABASE"
      expression = [
        { key = "sensitivity", values = ["mnpi", "non-mnpi"] },
        { key = "layer", values = ["raw", "curated", "analytics"] },
      ]
    }
    data_engineer_table = {
      principal     = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
      permissions   = ["ALL"]
      resource_type = "TABLE"
      expression = [
        { key = "sensitivity", values = ["mnpi", "non-mnpi"] },
        { key = "layer", values = ["raw", "curated", "analytics"] },
      ]
    }
  }

  # Data-location grants (S3 bucket access for data engineers)
  lf_data_location_grants = {
    data_engineer_location_mnpi = {
      principal = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
      arn       = var.mnpi_bucket_arn
    }
    data_engineer_location_nonmnpi = {
      principal = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
      arn       = var.nonmnpi_bucket_arn
    }
  }
}

resource "aws_lakeformation_permissions" "tag_policy_grant" {
  for_each = local.lf_tag_policy_grants

  principal   = each.value.principal
  permissions = each.value.permissions

  lf_tag_policy {
    resource_type = each.value.resource_type

    dynamic "expression" {
      for_each = each.value.expression
      content {
        key    = expression.value.key
        values = expression.value.values
      }
    }
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
    aws_lakeformation_resource.mnpi_bucket,
    aws_lakeformation_resource.nonmnpi_bucket,
    aws_lakeformation_lf_tag.sensitivity,
    aws_lakeformation_lf_tag.layer,
  ]
}

resource "aws_lakeformation_permissions" "data_location_grant" {
  for_each = local.lf_data_location_grants

  principal   = each.value.principal
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = each.value.arn
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
    aws_lakeformation_resource.mnpi_bucket,
    aws_lakeformation_resource.nonmnpi_bucket,
  ]
}

# =============================================================================
# Glue ETL Role — Database & Table Permissions
# =============================================================================
# The Glue ETL role needs:
#   - DESCRIBE + CREATE_TABLE on all 6 databases
#   - SELECT on tables in raw databases (read sources)
#   - ALL on tables in curated + analytics databases (write targets)
# Uses native aws_lakeformation_permissions (IAM role principals work
# correctly — the historical v5.x bug only affected Identity Center groups).
# =============================================================================

resource "aws_lakeformation_permissions" "glue_etl_databases" {
  for_each = var.database_names

  principal   = var.glue_etl_role_arn
  permissions = ["DESCRIBE", "CREATE_TABLE"]

  database {
    name = each.value
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

resource "aws_lakeformation_permissions" "glue_etl_raw_tables" {
  for_each = {
    for k, v in var.database_names : k => v
    if startswith(k, "raw_")
  }

  principal   = var.glue_etl_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = each.value
    wildcard      = true
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

resource "aws_lakeformation_permissions" "glue_etl_write_tables" {
  for_each = {
    for k, v in var.database_names : k => v
    if startswith(k, "curated_") || startswith(k, "analytics_")
  }

  principal   = var.glue_etl_role_arn
  permissions = ["ALL"]

  table {
    database_name = each.value
    wildcard      = true
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

# =============================================================================
# Kafka Connect Role — Database, Table & Data Location Permissions
# =============================================================================
# The MSK Connect Iceberg sink connector needs:
#   - DESCRIBE + CREATE_TABLE on raw databases (auto-create-enabled=true)
#   - ALL on tables in raw databases (write Iceberg data files)
#   - DATA_LOCATION_ACCESS on both S3 buckets
# =============================================================================

resource "aws_lakeformation_permissions" "kafka_connect_databases" {
  for_each = {
    for k, v in var.database_names : k => v
    if startswith(k, "raw_")
  }

  principal   = var.kafka_connect_role_arn
  permissions = ["DESCRIBE", "CREATE_TABLE"]

  database {
    name = each.value
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

resource "aws_lakeformation_permissions" "kafka_connect_tables" {
  for_each = {
    for k, v in var.database_names : k => v
    if startswith(k, "raw_")
  }

  principal   = var.kafka_connect_role_arn
  permissions = ["ALL"]

  table {
    database_name = each.value
    wildcard      = true
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

resource "aws_lakeformation_permissions" "kafka_connect_data_location" {
  for_each = {
    mnpi    = var.mnpi_bucket_arn
    nonmnpi = var.nonmnpi_bucket_arn
  }

  principal   = var.kafka_connect_role_arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = each.value
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_resource.mnpi_bucket,
    aws_lakeformation_resource.nonmnpi_bucket,
  ]
}

# =============================================================================
# QuickSight Service Role — Read-Only Database & Table Permissions
# =============================================================================
# QuickSight needs DESCRIBE on all databases and SELECT+DESCRIBE on all tables
# to display the Glue catalog in its dataset picker.  Grants are only created
# when a quicksight_role_arn is provided.
# =============================================================================

resource "aws_lakeformation_permissions" "quicksight_databases" {
  for_each = var.quicksight_role_arn != "" ? var.database_names : {}

  principal   = var.quicksight_role_arn
  permissions = ["DESCRIBE"]

  database {
    name = each.value
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

resource "aws_lakeformation_permissions" "quicksight_tables" {
  for_each = var.quicksight_role_arn != "" ? var.database_names : {}

  principal   = var.quicksight_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = each.value
    wildcard      = true
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
  ]
}

# =============================================================================
# Admin Data Access — Full SELECT on All Tables
# =============================================================================
# LF admins can manage grants but do NOT automatically get data access.
# This grants the SSO admin role SELECT+DESCRIBE on all tables so they
# can query curated/analytics layers via Athena.
# =============================================================================

resource "aws_lakeformation_permissions" "admins_databases" {
  for_each = var.admins_group_id != "" ? var.database_names : {}

  principal   = "arn:aws:identitystore:::group/${var.admins_group_id}"
  permissions = ["ALL"]

  database {
    name = each.value
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

resource "aws_lakeformation_permissions" "admins_tables" {
  for_each = var.admins_group_id != "" ? var.database_names : {}

  principal   = "arn:aws:identitystore:::group/${var.admins_group_id}"
  permissions = ["ALL"]

  table {
    database_name = each.value
    wildcard      = true
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

resource "aws_lakeformation_permissions" "admins_data_location" {
  for_each = var.admins_group_id != "" ? {
    mnpi    = var.mnpi_bucket_arn
    nonmnpi = var.nonmnpi_bucket_arn
  } : {}

  principal   = "arn:aws:identitystore:::group/${var.admins_group_id}"
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = each.value
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
    aws_lakeformation_resource.mnpi_bucket,
    aws_lakeformation_resource.nonmnpi_bucket,
  ]
}

# =============================================================================
# Reviewers — Same Access as Admins
# =============================================================================

resource "aws_lakeformation_permissions" "reviewers_databases" {
  for_each = var.reviewers_group_id != "" ? var.database_names : {}

  principal   = "arn:aws:identitystore:::group/${var.reviewers_group_id}"
  permissions = ["ALL"]

  database {
    name = each.value
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

resource "aws_lakeformation_permissions" "reviewers_tables" {
  for_each = var.reviewers_group_id != "" ? var.database_names : {}

  principal   = "arn:aws:identitystore:::group/${var.reviewers_group_id}"
  permissions = ["ALL"]

  table {
    database_name = each.value
    wildcard      = true
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

resource "aws_lakeformation_permissions" "reviewers_data_location" {
  for_each = var.reviewers_group_id != "" ? {
    mnpi    = var.mnpi_bucket_arn
    nonmnpi = var.nonmnpi_bucket_arn
  } : {}

  principal   = "arn:aws:identitystore:::group/${var.reviewers_group_id}"
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = each.value
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
    aws_lakeformation_resource.mnpi_bucket,
    aws_lakeformation_resource.nonmnpi_bucket,
  ]
}
