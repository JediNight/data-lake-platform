/**
 * service-roles — Machine Identity IAM Roles
 *
 * Contains IAM roles for service-to-service authentication:
 *   1. kafka-connect-irsa — IRSA role for Strimzi KafkaConnect pods;
 *      MSK IAM auth, S3 write, Glue catalog write
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
          replace(var.glue_registry_arn, ":registry/", ":schema/"),
          "${replace(var.glue_registry_arn, ":registry/", ":schema/")}/*",
        ]
      },
    ]
  })
}
