/**
 * identity-center — IAM Identity Center Groups, Permission Sets & Demo Users
 *
 * Replaces iam-personas module with Identity Center-based human identity
 * management. Creates three persona groups with matching permission sets
 * and demo users for each group.
 *
 * Permission sets define the AWS-level access (Athena, Glue, S3). Lake
 * Formation LF-Tag grants (in lake-formation module) control which
 * databases/tables/columns each group can see.
 */

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.17"
    }
  }
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_ssoadmin_instances" "this" {}
data "aws_caller_identity" "current" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  account_id        = data.aws_caller_identity.current.account_id

  common_tags = merge(var.tags, {
    Module      = "identity-center"
    Environment = var.environment
  })

  # Shared analyst policy statements (Athena + Glue read + LF GetDataAccess)
  analyst_policy_statements = [
    {
      Sid    = "AthenaQueryExecution"
      Effect = "Allow"
      Action = [
        "athena:StartQueryExecution",
        "athena:StopQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        "athena:GetWorkGroup",
        "athena:BatchGetQueryExecution",
        "athena:ListQueryExecutions",
      ]
      Resource = "*"
    },
    {
      Sid    = "GlueCatalogRead"
      Effect = "Allow"
      Action = [
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetDatabase",
        "glue:GetDatabases",
        "glue:GetPartition",
        "glue:GetPartitions",
        "glue:BatchGetPartition",
      ]
      Resource = "*"
    },
    {
      Sid    = "S3QueryResultsAccess"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:AbortMultipartUpload",
      ]
      Resource = [
        var.query_results_bucket_arn,
        "${var.query_results_bucket_arn}/*",
      ]
    },
    {
      Sid      = "LakeFormationDataAccess"
      Effect   = "Allow"
      Action   = ["lakeformation:GetDataAccess"]
      Resource = "*"
    },
  ]
}

# =============================================================================
# Identity Center Groups
# =============================================================================

resource "aws_identitystore_group" "finance_analysts" {
  identity_store_id = local.identity_store_id
  display_name      = "FinanceAnalysts"
  description       = "Finance analysts with MNPI + non-MNPI curated/analytics access"
}

resource "aws_identitystore_group" "data_analysts" {
  identity_store_id = local.identity_store_id
  display_name      = "DataAnalysts"
  description       = "Data analysts with non-MNPI curated/analytics access only"
}

resource "aws_identitystore_group" "data_engineers" {
  identity_store_id = local.identity_store_id
  display_name      = "DataEngineers"
  description       = "Data engineers with full access including direct S3"
}

# =============================================================================
# Permission Sets
# =============================================================================

# --- Finance Analyst Permission Set -----------------------------------------

resource "aws_ssoadmin_permission_set" "finance_analyst" {
  name             = "FinanceAnalyst"
  description      = "Athena query access for finance analysts (LF-Tags control data visibility)"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "finance_analyst" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.finance_analyst.arn

  inline_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.analyst_policy_statements
  })
}

# --- Data Analyst Permission Set --------------------------------------------

resource "aws_ssoadmin_permission_set" "data_analyst" {
  name             = "DataAnalyst"
  description      = "Athena query access for data analysts (LF-Tags control data visibility)"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "data_analyst" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.data_analyst.arn

  inline_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.analyst_policy_statements
  })
}

# --- Data Engineer Permission Set -------------------------------------------

resource "aws_ssoadmin_permission_set" "data_engineer" {
  name             = "DataEngineer"
  description      = "Full data lake access: Athena + Glue CRUD + direct S3"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "data_engineer" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.data_engineer.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.analyst_policy_statements, [
      {
        Sid    = "GlueCatalogReadWrite"
        Effect = "Allow"
        Action = [
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable",
          "glue:CreatePartition",
          "glue:UpdatePartition",
          "glue:DeletePartition",
          "glue:BatchCreatePartition",
          "glue:BatchDeletePartition",
          "glue:CreateDatabase",
          "glue:UpdateDatabase",
        ]
        Resource = "*"
      },
      {
        Sid    = "DirectS3DataLakeAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          var.mnpi_bucket_arn,
          "${var.mnpi_bucket_arn}/*",
          var.nonmnpi_bucket_arn,
          "${var.nonmnpi_bucket_arn}/*",
        ]
      },
    ])
  })
}

# =============================================================================
# Account Assignments (Group + Permission Set -> Account)
# =============================================================================

resource "aws_ssoadmin_account_assignment" "finance_analysts" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.finance_analyst.arn
  principal_id       = aws_identitystore_group.finance_analysts.group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "data_analysts" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.data_analyst.arn
  principal_id       = aws_identitystore_group.data_analysts.group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "data_engineers" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.data_engineer.arn
  principal_id       = aws_identitystore_group.data_engineers.group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}

# =============================================================================
# Demo Users (one per persona for interview demonstration)
# =============================================================================

resource "aws_identitystore_user" "finance_demo" {
  identity_store_id = local.identity_store_id
  display_name      = "Jane Finance"
  user_name         = "jane.finance"

  name {
    given_name  = "Jane"
    family_name = "Finance"
  }

  emails {
    value   = "jane.finance@datalake.demo"
    primary = true
  }
}

resource "aws_identitystore_user" "analyst_demo" {
  identity_store_id = local.identity_store_id
  display_name      = "Alex Analyst"
  user_name         = "alex.analyst"

  name {
    given_name  = "Alex"
    family_name = "Analyst"
  }

  emails {
    value   = "alex.analyst@datalake.demo"
    primary = true
  }
}

resource "aws_identitystore_user" "engineer_demo" {
  identity_store_id = local.identity_store_id
  display_name      = "Sam Engineer"
  user_name         = "sam.engineer"

  name {
    given_name  = "Sam"
    family_name = "Engineer"
  }

  emails {
    value   = "sam.engineer@datalake.demo"
    primary = true
  }
}

# =============================================================================
# Group Memberships
# =============================================================================

resource "aws_identitystore_group_membership" "finance_demo" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.finance_analysts.group_id
  member_id         = aws_identitystore_user.finance_demo.user_id
}

resource "aws_identitystore_group_membership" "analyst_demo" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.data_analysts.group_id
  member_id         = aws_identitystore_user.analyst_demo.user_id
}

resource "aws_identitystore_group_membership" "engineer_demo" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.data_engineers.group_id
  member_id         = aws_identitystore_user.engineer_demo.user_id
}
