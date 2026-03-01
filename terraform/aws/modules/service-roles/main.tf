/**
 * service-roles — Machine Identity IAM Roles
 *
 * Contains IAM roles for service-to-service authentication:
 *   1. kafka-connect-irsa — IRSA role for Strimzi KafkaConnect pods;
 *      MSK IAM auth, S3 write, Glue catalog write
 *   2. glue-etl — Role assumed by Glue ETL PySpark jobs;
 *      S3 data lake read/write, Glue catalog CRUD, KMS, CloudWatch logs
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

locals {
  common_tags = merge(var.tags, {
    Module      = "service-roles"
    Environment = var.environment
  })
}

# =============================================================================
# Kafka Connect IRSA Role
# =============================================================================

resource "aws_iam_role" "kafka_connect" {
  name = "datalake-kafka-connect-${var.environment}"
  path = "/datalake/"

  # MSK Connect (AWS-managed) always needs kafkaconnect.amazonaws.com.
  # When EKS is also enabled, add IRSA for Strimzi (self-hosted) connectors.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "AllowMSKConnect"
          Effect    = "Allow"
          Principal = { Service = "kafkaconnect.amazonaws.com" }
          Action    = "sts:AssumeRole"
        },
      ],
      var.eks_oidc_provider_arn != "" ? [
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
      ] : [],
    )
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
          replace(var.glue_registry_arn, ":registry/", ":schema/"),
          "${replace(var.glue_registry_arn, ":registry/", ":schema/")}/*",
        ]
      },
    ]
  })
}

# =============================================================================
# Glue ETL Role
# =============================================================================
# PySpark jobs running medallion transforms (raw → curated → analytics).
# Needs: S3 data lake R/W, Glue catalog CRUD, KMS for encrypted buckets,
# CloudWatch logs, and S3 read for script files in query-results bucket.
# =============================================================================

resource "aws_iam_role" "glue_etl" {
  name = "datalake-glue-etl-${var.environment}"
  path = "/datalake/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowGlueAssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name    = "datalake-glue-etl-${var.environment}"
    Persona = "glue-etl"
  })
}

resource "aws_iam_role_policy" "glue_etl_s3" {
  name = "s3-data-lake-read-write"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "S3DataLakeReadWrite"
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
      Resource = concat(
        [
          var.mnpi_bucket_arn, "${var.mnpi_bucket_arn}/*",
          var.nonmnpi_bucket_arn, "${var.nonmnpi_bucket_arn}/*",
        ],
        flatten([for arn in var.extra_s3_read_bucket_arns : [arn, "${arn}/*"]]),
      )
    }]
  })
}

resource "aws_iam_role_policy" "glue_etl_kms" {
  name = "kms-decrypt-encrypt"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "KMSDecryptEncrypt"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      Resource = [var.mnpi_kms_key_arn, var.nonmnpi_kms_key_arn]
    }]
  })
}

resource "aws_iam_role_policy" "glue_etl_glue" {
  name = "glue-catalog-access"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GlueCatalogAccess"
      Effect = "Allow"
      Action = [
        "glue:GetDatabase", "glue:GetDatabases",
        "glue:GetTable", "glue:GetTables", "glue:CreateTable",
        "glue:UpdateTable", "glue:DeleteTable",
        "glue:GetPartition", "glue:GetPartitions",
        "glue:CreatePartition", "glue:UpdatePartition",
        "glue:BatchCreatePartition", "glue:BatchDeletePartition",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "glue_etl_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:/aws-glue/*"
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "glue_etl_scripts" {
  name = "s3-scripts-read"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "S3ScriptsRead"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${var.query_results_bucket_arn}/glue-scripts/*"
    }]
  })
}
