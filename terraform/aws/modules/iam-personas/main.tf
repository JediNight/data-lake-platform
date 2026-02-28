/**
 * iam-personas — IAM Roles for Data Lake Personas & Kafka Connect IRSA
 *
 * Creates four IAM roles:
 *
 *   1. finance-analyst-role  — Athena query access; Lake Formation LF-Tags
 *                              control MNPI + non-MNPI visibility
 *   2. data-analyst-role     — Athena query access; Lake Formation LF-Tags
 *                              restrict to non-MNPI only
 *   3. data-engineer-role    — Full access: Athena + direct S3 + Glue schema
 *                              management on both data lake buckets
 *   4. kafka-connect-irsa    — IRSA role for Strimzi KafkaConnect pods;
 *                              MSK IAM auth, S3 write, Glue catalog write
 *
 * IMPORTANT: The actual MNPI vs non-MNPI access control is enforced by
 * Lake Formation LF-Tags (see lake-formation module), NOT by these IAM
 * policies. These policies grant the AWS-level permissions needed to USE
 * Athena, Glue, and S3; LF-Tags control which databases/tables/columns
 * each role can see.
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
    Module      = "iam-personas"
    Environment = var.environment
  })
}

# =============================================================================
# 1. Finance Analyst Role
# =============================================================================
# Can query MNPI + non-MNPI curated/analytics via Athena.
# NO direct S3 access to data lake buckets — Lake Formation controls access.
# =============================================================================

resource "aws_iam_role" "finance_analyst" {
  name = "datalake-finance-analyst-${var.environment}"
  path = "/datalake/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountUsersToAssume"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalType" = "User"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "datalake-finance-analyst-${var.environment}"
    Persona = "finance-analyst"
  })
}

resource "aws_iam_role_policy" "finance_analyst_athena" {
  name = "athena-query-access"
  role = aws_iam_role.finance_analyst.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        Sid    = "LakeFormationDataAccess"
        Effect = "Allow"
        Action = [
          "lakeformation:GetDataAccess",
        ]
        Resource = "*"
      },
    ]
  })
}

# =============================================================================
# 2. Data Analyst Role
# =============================================================================
# Can query non-MNPI only via Athena.
# NO direct S3 access to data lake buckets — Lake Formation controls access.
# =============================================================================

resource "aws_iam_role" "data_analyst" {
  name = "datalake-data-analyst-${var.environment}"
  path = "/datalake/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountUsersToAssume"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalType" = "User"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "datalake-data-analyst-${var.environment}"
    Persona = "data-analyst"
  })
}

resource "aws_iam_role_policy" "data_analyst_athena" {
  name = "athena-query-access"
  role = aws_iam_role.data_analyst.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        Sid    = "LakeFormationDataAccess"
        Effect = "Allow"
        Action = [
          "lakeformation:GetDataAccess",
        ]
        Resource = "*"
      },
    ]
  })
}

# =============================================================================
# 3. Data Engineer Role
# =============================================================================
# Full access: Athena + direct S3 on both data lake buckets + Glue schema
# management. This role is listed in data-lake-storage allowed_principal_arns
# so it can bypass the bucket-policy deny for direct S3 access.
# =============================================================================

resource "aws_iam_role" "data_engineer" {
  name = "datalake-data-engineer-${var.environment}"
  path = "/datalake/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountUsersToAssume"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalType" = "User"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "datalake-data-engineer-${var.environment}"
    Persona = "data-engineer"
  })
}

resource "aws_iam_role_policy" "data_engineer_athena" {
  name = "athena-query-access"
  role = aws_iam_role.data_engineer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
    ]
  })
}

resource "aws_iam_role_policy" "data_engineer_glue" {
  name = "glue-catalog-full-access"
  role = aws_iam_role.data_engineer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueCatalogReadWrite"
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition",
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
    ]
  })
}

resource "aws_iam_role_policy" "data_engineer_s3" {
  name = "s3-data-lake-access"
  role = aws_iam_role.data_engineer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        Sid    = "LakeFormationDataAccess"
        Effect = "Allow"
        Action = [
          "lakeformation:GetDataAccess",
        ]
        Resource = "*"
      },
    ]
  })
}

# =============================================================================
# 4. Kafka Connect IRSA Role
# =============================================================================
# For Strimzi KafkaConnect pods on EKS. Uses IRSA (IAM Roles for Service
# Accounts) so pods assume this role without static credentials.
#
# Permissions:
#   - MSK IAM auth (kafka-cluster:Connect, etc.)
#   - S3 write to both data lake buckets (Iceberg sink connector)
#   - Glue catalog write (CreateTable, UpdateTable for Iceberg metadata)
#   - Glue Schema Registry read (GetSchemaVersion for deserialization)
# =============================================================================

resource "aws_iam_role" "kafka_connect" {
  name = "datalake-kafka-connect-${var.environment}"
  path = "/datalake/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEKSServiceAccountAssume"
        Effect = "Allow"
        Principal = {
          Federated = var.eks_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:${var.kafka_connect_namespace}:${var.kafka_connect_service_account}"
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "datalake-kafka-connect-${var.environment}"
    Persona = "kafka-connect"
  })
}

resource "aws_iam_role_policy" "kafka_connect_msk" {
  name = "msk-iam-auth"
  role = aws_iam_role.kafka_connect.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MSKClusterAccess"
        Effect = "Allow"
        Action = [
          "kafka:DescribeCluster",
          "kafka:DescribeClusterV2",
          "kafka:GetBootstrapBrokers",
        ]
        Resource = var.msk_cluster_arn != "" ? var.msk_cluster_arn : "*"
      },
      {
        Sid    = "MSKIAMAuth"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:AlterCluster",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:AlterTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup",
        ]
        Resource = var.msk_cluster_arn != "" ? [
          var.msk_cluster_arn,
          "${replace(var.msk_cluster_arn, ":cluster/", ":topic/")}/*",
          "${replace(var.msk_cluster_arn, ":cluster/", ":group/")}/*",
        ] : ["*"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "kafka_connect_s3" {
  name = "s3-data-lake-write"
  role = aws_iam_role.kafka_connect.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3DataLakeWrite"
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
    ]
  })
}

resource "aws_iam_role_policy" "kafka_connect_glue" {
  name = "glue-catalog-and-registry"
  role = aws_iam_role.kafka_connect.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueCatalogWriteForIceberg"
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:CreatePartition",
          "glue:UpdatePartition",
          "glue:DeletePartition",
          "glue:BatchCreatePartition",
          "glue:BatchDeletePartition",
          "glue:BatchGetPartition",
        ]
        Resource = "*"
      },
      {
        Sid    = "GlueSchemaRegistryRead"
        Effect = "Allow"
        Action = [
          "glue:GetSchemaVersion",
          "glue:GetSchemaByDefinition",
          "glue:GetSchemaVersionsDiff",
          "glue:ListSchemaVersions",
          "glue:GetSchema",
          "glue:ListSchemas",
          "glue:GetRegistry",
          "glue:ListRegistries",
        ]
        Resource = [
          var.glue_registry_arn,
          "${var.glue_registry_arn}/*",
          # Schema resources follow a different ARN pattern
          replace(var.glue_registry_arn, ":registry/", ":schema/"),
          "${replace(var.glue_registry_arn, ":registry/", ":schema/")}/*",
        ]
      },
    ]
  })
}
