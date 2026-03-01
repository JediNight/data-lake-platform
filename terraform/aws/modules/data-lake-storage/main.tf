/**
 * data-lake-storage — S3 Buckets, KMS Keys, Bucket Policies, Lifecycle Rules
 *
 * Creates the four-bucket data lake layout:
 *   1. MNPI data lake bucket        (SSE-KMS with MNPI CMK, versioned)
 *   2. Non-MNPI data lake bucket    (SSE-KMS with non-MNPI CMK, versioned)
 *   3. Audit / CloudTrail bucket    (SSE-KMS with non-MNPI CMK)
 *   4. Athena query results bucket  (SSE-KMS with non-MNPI CMK)
 *
 * CRITICAL SECURITY CONTROL:
 *   Both data lake buckets carry a bucket policy that DENIES s3:GetObject
 *   and s3:PutObject for all principals EXCEPT:
 *     - Lake Formation service
 *     - Roles listed in var.allowed_principal_arns (Kafka Connect IRSA,
 *       data engineer, admin)
 *   This prevents direct S3 access that would bypass Lake Formation
 *   column/row-level security.
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
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  bucket_names = {
    mnpi          = "datalake-mnpi-${var.environment}"
    nonmnpi       = "datalake-nonmnpi-${var.environment}"
    audit         = "datalake-audit-${var.environment}"
    query_results = "datalake-query-results-${local.account_id}-${var.environment}"
  }

  common_tags = merge(var.tags, {
    Module      = "data-lake-storage"
    Environment = var.environment
  })
}

# =============================================================================
# KMS Keys
# =============================================================================

resource "aws_kms_key" "mnpi" {
  description             = "CMK for MNPI data lake zone (${var.environment})"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  is_enabled              = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "mnpi-key-policy"
    Statement = [
      {
        Sid    = "EnableRootAccountFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowLakeFormationService"
        Effect = "Allow"
        Principal = {
          Service = "lakeformation.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowS3Service"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name     = "datalake-mnpi-cmk-${var.environment}"
    DataZone = "mnpi"
  })
}

resource "aws_kms_alias" "mnpi" {
  name          = "alias/datalake-mnpi-${var.environment}"
  target_key_id = aws_kms_key.mnpi.key_id
}

resource "aws_kms_key" "nonmnpi" {
  description             = "CMK for non-MNPI data lake zone (${var.environment})"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  is_enabled              = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "nonmnpi-key-policy"
    Statement = [
      {
        Sid    = "EnableRootAccountFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowLakeFormationService"
        Effect = "Allow"
        Principal = {
          Service = "lakeformation.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowS3Service"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name     = "datalake-nonmnpi-cmk-${var.environment}"
    DataZone = "nonmnpi"
  })
}

resource "aws_kms_alias" "nonmnpi" {
  name          = "alias/datalake-nonmnpi-${var.environment}"
  target_key_id = aws_kms_key.nonmnpi.key_id
}

# =============================================================================
# S3 Buckets
# =============================================================================

# --- MNPI Data Lake Bucket ---------------------------------------------------

resource "aws_s3_bucket" "mnpi" {
  bucket        = local.bucket_names.mnpi
  force_destroy = var.environment == "dev"

  tags = merge(local.common_tags, {
    Name     = local.bucket_names.mnpi
    DataZone = "mnpi"
  })
}

resource "aws_s3_bucket_versioning" "mnpi" {
  bucket = aws_s3_bucket.mnpi.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mnpi" {
  bucket = aws_s3_bucket.mnpi.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.mnpi.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "mnpi" {
  bucket = aws_s3_bucket.mnpi.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "mnpi" {
  count  = var.raw_ia_transition_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.mnpi.id

  rule {
    id     = "raw-layer-ia-transition"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    transition {
      days          = var.raw_ia_transition_days
      storage_class = "STANDARD_IA"
    }
  }
}

# --- Non-MNPI Data Lake Bucket -----------------------------------------------

resource "aws_s3_bucket" "nonmnpi" {
  bucket        = local.bucket_names.nonmnpi
  force_destroy = var.environment == "dev"

  tags = merge(local.common_tags, {
    Name     = local.bucket_names.nonmnpi
    DataZone = "nonmnpi"
  })
}

resource "aws_s3_bucket_versioning" "nonmnpi" {
  bucket = aws_s3_bucket.nonmnpi.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "nonmnpi" {
  bucket = aws_s3_bucket.nonmnpi.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.nonmnpi.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "nonmnpi" {
  bucket = aws_s3_bucket.nonmnpi.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "nonmnpi" {
  count  = var.raw_ia_transition_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.nonmnpi.id

  rule {
    id     = "raw-layer-ia-transition"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    transition {
      days          = var.raw_ia_transition_days
      storage_class = "STANDARD_IA"
    }
  }
}

# --- Audit / CloudTrail Bucket ------------------------------------------------

resource "aws_s3_bucket" "audit" {
  bucket        = local.bucket_names.audit
  force_destroy = var.environment == "dev"

  tags = merge(local.common_tags, {
    Name     = local.bucket_names.audit
    DataZone = "audit"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.nonmnpi.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Athena Query Results Bucket ----------------------------------------------

resource "aws_s3_bucket" "query_results" {
  bucket        = local.bucket_names.query_results
  force_destroy = var.environment == "dev"

  tags = merge(local.common_tags, {
    Name     = local.bucket_names.query_results
    DataZone = "query-results"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "query_results" {
  bucket = aws_s3_bucket.query_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.nonmnpi.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "query_results" {
  bucket = aws_s3_bucket.query_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# Bucket Policies — Lake Formation Bypass Prevention
# =============================================================================
#
# CRITICAL: These policies DENY s3:GetObject and s3:PutObject for all
# principals EXCEPT the Lake Formation service and explicitly allowed roles.
# Without this, any IAM principal with s3:GetObject permissions could read
# data directly from S3, bypassing Lake Formation column/row-level security.
# =============================================================================

resource "aws_s3_bucket_policy" "mnpi" {
  bucket = aws_s3_bucket.mnpi.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDirectS3AccessExceptAllowed"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.mnpi.arn}/*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalServiceName" = "lakeformation.amazonaws.com"
          }
          ArnNotLike = {
            "aws:PrincipalArn" = var.allowed_principal_arns
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.mnpi]
}

resource "aws_s3_bucket_policy" "nonmnpi" {
  bucket = aws_s3_bucket.nonmnpi.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDirectS3AccessExceptAllowed"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.nonmnpi.arn}/*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalServiceName" = "lakeformation.amazonaws.com"
          }
          ArnNotLike = {
            "aws:PrincipalArn" = var.allowed_principal_arns
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.nonmnpi]
}
