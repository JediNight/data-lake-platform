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
# Lake Formation Data Lake Settings
# =============================================================================
# Set the admin principal and override the default IAMAllowedPrincipals so
# that Lake Formation permissions are actually enforced (rather than falling
# back to IAM-only access control).
# =============================================================================

resource "aws_lakeformation_data_lake_settings" "this" {
  admins = [var.admin_role_arn]

  # Omitting create_database_default_permissions and
  # create_table_default_permissions removes the default
  # IAMAllowedPrincipals grants, forcing all access through
  # Lake Formation grants rather than plain IAM.
}

# =============================================================================
# Identity Center Configuration
# =============================================================================
# Connect Lake Formation to IAM Identity Center for trusted identity
# propagation. This enables granting permissions directly to IC groups
# instead of IAM role ARNs.
# =============================================================================

resource "aws_lakeformation_identity_center_configuration" "this" {
  instance_arn = var.sso_instance_arn
}

# =============================================================================
# LF-Tags (2 tag keys)
# =============================================================================

resource "aws_lakeformation_lf_tag" "sensitivity" {
  key    = "sensitivity"
  values = ["mnpi", "non-mnpi"]
}

resource "aws_lakeformation_lf_tag" "layer" {
  key    = "layer"
  values = ["raw", "curated", "analytics"]
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
# 1. Finance Analyst -- DATABASE-level grant
# -----------------------------------------------------------------------------

resource "aws_lakeformation_permissions" "finance_analyst_db" {
  principal   = "arn:aws:identitystore:::group/${var.finance_analysts_group_id}"
  permissions = ["DESCRIBE"]

  lf_tag_policy {
    resource_type = "DATABASE"

    expression {
      key    = aws_lakeformation_lf_tag.sensitivity.key
      values = ["mnpi", "non-mnpi"]
    }

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["curated", "analytics"]
    }
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

# Finance Analyst -- TABLE-level grant (SELECT)

resource "aws_lakeformation_permissions" "finance_analyst_table" {
  principal   = "arn:aws:identitystore:::group/${var.finance_analysts_group_id}"
  permissions = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"

    expression {
      key    = aws_lakeformation_lf_tag.sensitivity.key
      values = ["mnpi", "non-mnpi"]
    }

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["curated", "analytics"]
    }
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

# -----------------------------------------------------------------------------
# 2. Data Analyst -- DATABASE-level grant
# -----------------------------------------------------------------------------

resource "aws_lakeformation_permissions" "data_analyst_db" {
  principal   = "arn:aws:identitystore:::group/${var.data_analysts_group_id}"
  permissions = ["DESCRIBE"]

  lf_tag_policy {
    resource_type = "DATABASE"

    expression {
      key    = aws_lakeformation_lf_tag.sensitivity.key
      values = ["non-mnpi"]
    }

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["curated", "analytics"]
    }
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

# Data Analyst -- TABLE-level grant (SELECT)

resource "aws_lakeformation_permissions" "data_analyst_table" {
  principal   = "arn:aws:identitystore:::group/${var.data_analysts_group_id}"
  permissions = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"

    expression {
      key    = aws_lakeformation_lf_tag.sensitivity.key
      values = ["non-mnpi"]
    }

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["curated", "analytics"]
    }
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

# -----------------------------------------------------------------------------
# 3. Data Engineer -- DATABASE-level grant (ALL)
# -----------------------------------------------------------------------------

resource "aws_lakeformation_permissions" "data_engineer_db" {
  principal   = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
  permissions = ["ALL"]

  lf_tag_policy {
    resource_type = "DATABASE"

    expression {
      key    = aws_lakeformation_lf_tag.sensitivity.key
      values = ["mnpi", "non-mnpi"]
    }

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["raw", "curated", "analytics"]
    }
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

# Data Engineer -- TABLE-level grant (ALL)

resource "aws_lakeformation_permissions" "data_engineer_table" {
  principal   = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
  permissions = ["ALL"]

  lf_tag_policy {
    resource_type = "TABLE"

    expression {
      key    = aws_lakeformation_lf_tag.sensitivity.key
      values = ["mnpi", "non-mnpi"]
    }

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["raw", "curated", "analytics"]
    }
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

# Data Engineer -- DATA_LOCATION_ACCESS on MNPI bucket

resource "aws_lakeformation_permissions" "data_engineer_location_mnpi" {
  principal   = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = aws_lakeformation_resource.mnpi_bucket.arn
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}

# Data Engineer -- DATA_LOCATION_ACCESS on non-MNPI bucket

resource "aws_lakeformation_permissions" "data_engineer_location_nonmnpi" {
  principal   = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = aws_lakeformation_resource.nonmnpi_bucket.arn
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    aws_lakeformation_identity_center_configuration.this,
  ]
}
