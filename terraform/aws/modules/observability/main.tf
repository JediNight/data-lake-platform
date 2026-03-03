/**
 * observability -- CloudTrail, CloudWatch, Glue Audit Table, optional QuickSight
 *
 * Creates the audit-trail infrastructure for SEC compliance:
 *
 *   1. CloudTrail trail with S3 data event selectors on BOTH data lake
 *      buckets (MNPI + non-MNPI).  Every ReadObject / WriteObject is
 *      logged with principal, action, timestamp, and source IP.
 *
 *   2. CloudWatch Logs integration so trail events stream to a log
 *      group for real-time alerting and metric filters.
 *
 *   3. Audit bucket policy allowing CloudTrail to write log files.
 *
 *   4. Glue Catalog table over the CloudTrail JSON logs so analysts
 *      can query access patterns via Athena.
 *
 *   5. (Optional) QuickSight resources gated behind var.enable_quicksight.
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

data "aws_region" "current" {}

# =============================================================================
# Locals
# =============================================================================

locals {
  trail_name = "datalake-trail-${var.environment}"

  common_tags = merge(var.tags, {
    Module      = "observability"
    Environment = var.environment
  })
}

# =============================================================================
# CloudWatch Log Group (for CloudTrail delivery)
# =============================================================================

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/datalake-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name = "cloudtrail-datalake-${var.environment}"
  })
}

# =============================================================================
# IAM Role — CloudTrail -> CloudWatch Logs delivery
# =============================================================================

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name = "datalake-cloudtrail-cw-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudTrailAssume"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "datalake-cloudtrail-cw-${var.environment}"
  })
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name = "cloudtrail-to-cloudwatch-logs"
  role = aws_iam_role.cloudtrail_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLogStreamCreation"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      },
      {
        Sid    = "AllowPutLogEvents"
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      },
    ]
  })
}

# =============================================================================
# Audit Bucket Policy — Allow CloudTrail to write logs
# =============================================================================

resource "aws_s3_bucket_policy" "audit_cloudtrail" {
  bucket = var.audit_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = var.audit_bucket_arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${data.aws_region.current.id}:${var.account_id}:trail/${local.trail_name}"
          }
        }
      },
      {
        Sid    = "CloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${var.audit_bucket_arn}/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${data.aws_region.current.id}:${var.account_id}:trail/${local.trail_name}"
          }
        }
      },
    ]
  })
}

# =============================================================================
# CloudTrail — S3 data events on both data lake buckets
# =============================================================================

resource "aws_cloudtrail" "datalake" {
  name                          = local.trail_name
  s3_bucket_name                = var.audit_bucket_id
  is_multi_region_trail         = false
  include_global_service_events = true
  enable_log_file_validation    = true
  enable_logging                = true

  # CloudWatch Logs integration
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn

  # S3 data event selectors — audit every object read/write on data lake buckets
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type = "AWS::S3::Object"
      values = [
        "${var.mnpi_bucket_arn}/",
        "${var.nonmnpi_bucket_arn}/",
      ]
    }
  }

  tags = merge(local.common_tags, {
    Name = local.trail_name
  })

  depends_on = [aws_s3_bucket_policy.audit_cloudtrail]
}

# =============================================================================
# Glue Catalog Database + Table — CloudTrail logs for Athena querying
# =============================================================================

resource "aws_glue_catalog_database" "audit" {
  name        = "audit_cloudtrail_${var.environment}"
  description = "CloudTrail audit logs for Athena analysis (${var.environment})"

  tags = merge(local.common_tags, {
    Name = "audit_cloudtrail_${var.environment}"
  })
}

resource "aws_glue_catalog_table" "cloudtrail_logs" {
  name          = "cloudtrail_logs"
  database_name = aws_glue_catalog_database.audit.name
  description   = "CloudTrail S3 data event logs — who accessed what data and when"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    "classification"     = "cloudtrail"
    "projection.enabled" = "false"
  }

  storage_descriptor {
    location      = "s3://${var.audit_bucket_id}/AWSLogs/${var.account_id}/CloudTrail/"
    input_format  = "com.amazon.emr.cloudtrail.CloudTrailInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "cloudtrail-serde"
      serialization_library = "org.apache.hive.hcatalog.data.JsonSerDe"

      parameters = {
        "serialization.format" = "1"
        "paths"                = "awsRegion,errorCode,errorMessage,eventID,eventName,eventSource,eventTime,eventType,eventVersion,readOnly,recipientAccountId,requestID,requestParameters,resources,responseElements,sharedEventID,sourceIPAddress,userAgent,userIdentity"
      }
    }

    columns {
      name = "eventversion"
      type = "string"
    }

    columns {
      name = "useridentity"
      type = "struct<type:string,principalid:string,arn:string,accountid:string,invokedby:string,accesskeyid:string,username:string,sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,sessionissuer:struct<type:string,principalid:string,arn:string,accountid:string,username:string>,ec2roledelivery:string,webidfederationdata:struct<federatedprovider:string,attributes:string>>>"
    }

    columns {
      name = "eventtime"
      type = "string"
    }

    columns {
      name = "eventsource"
      type = "string"
    }

    columns {
      name = "eventname"
      type = "string"
    }

    columns {
      name = "awsregion"
      type = "string"
    }

    columns {
      name = "sourceipaddress"
      type = "string"
    }

    columns {
      name = "useragent"
      type = "string"
    }

    columns {
      name = "errorcode"
      type = "string"
    }

    columns {
      name = "errormessage"
      type = "string"
    }

    columns {
      name = "requestparameters"
      type = "string"
    }

    columns {
      name = "responseelements"
      type = "string"
    }

    columns {
      name = "additionaleventdata"
      type = "string"
    }

    columns {
      name = "requestid"
      type = "string"
    }

    columns {
      name = "eventid"
      type = "string"
    }

    columns {
      name = "eventtype"
      type = "string"
    }

    columns {
      name = "recipientaccountid"
      type = "string"
    }

    columns {
      name = "sharedeventid"
      type = "string"
    }

    columns {
      name = "readonly"
      type = "string"
    }

    columns {
      name = "resources"
      type = "array<struct<arn:string,accountid:string,type:string>>"
    }
  }
}

# =============================================================================
# QuickSight (optional — gated behind var.enable_quicksight)
# =============================================================================
#
# QuickSight account subscription and example data source.  Gated with
# count so nothing is created unless explicitly opted in.  Actual
# dashboards are out of scope for this module; the subscription and
# data source are placeholders for future build-out.
# =============================================================================

resource "aws_quicksight_account_subscription" "this" {
  count = var.enable_quicksight ? 1 : 0

  account_name          = "datalake-${var.account_id}-${var.environment}"
  edition               = "STANDARD"
  authentication_method = "IAM_AND_QUICKSIGHT"
  notification_email    = "admin@example.com"

  lifecycle {
    ignore_changes = [authentication_method]
  }
}

# -----------------------------------------------------------------------------
# QuickSight Service Role Policies
# QuickSight uses the AWS-managed role aws-quicksight-service-role-v0 (created
# automatically when the account subscription is provisioned).  We attach
# additional IAM policies to it for S3, KMS, and Glue access.
# -----------------------------------------------------------------------------

data "aws_iam_role" "quicksight_service" {
  count = var.enable_quicksight ? 1 : 0
  name  = "aws-quicksight-service-role-v0"

  depends_on = [aws_quicksight_account_subscription.this]
}

resource "aws_iam_role_policy" "quicksight_s3_and_glue" {
  count = var.enable_quicksight ? 1 : 0

  name = "datalake-s3-glue-access"
  role = data.aws_iam_role.quicksight_service[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetDatabases",
          "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions",
          "glue:BatchGetPartition",
        ]
        Resource = "*"
      },
      {
        Sid    = "S3DataLakeRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation",
        ]
        Resource = [
          var.mnpi_bucket_arn, "${var.mnpi_bucket_arn}/*",
          var.nonmnpi_bucket_arn, "${var.nonmnpi_bucket_arn}/*",
        ]
      },
      {
        Sid    = "S3QueryResultsReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:ListBucket",
          "s3:GetBucketLocation", "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts", "s3:ListBucketMultipartUploads",
        ]
        Resource = [
          var.query_results_bucket_arn,
          "${var.query_results_bucket_arn}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "quicksight_kms" {
  count = var.enable_quicksight && var.quicksight_kms_key_arn != "" ? 1 : 0

  name = "datalake-kms-access"
  role = data.aws_iam_role.quicksight_service[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "KMSForAthenaQueryResults"
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      Resource = var.quicksight_kms_key_arn
    }]
  })
}

# -----------------------------------------------------------------------------
# QuickSight Data Source — Athena with correct workgroup
# Uses null_resource + AWS CLI because the Terraform aws provider does not
# support the RoleArn parameter in AthenaParameters (required for
# programmatic data source creation).
# depends_on ensures IAM policies propagate before data source creation.
# -----------------------------------------------------------------------------

resource "null_resource" "quicksight_athena_datasource" {
  count = var.enable_quicksight ? 1 : 0

  triggers = {
    workgroup  = var.athena_workgroup_name
    account_id = var.account_id
    role_arn   = data.aws_iam_role.quicksight_service[0].arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for IAM policy propagation
      sleep 10
      # Delete existing failed data source if present
      aws quicksight delete-data-source \
        --aws-account-id ${var.account_id} \
        --data-source-id "datalake-athena-${var.environment}" 2>/dev/null || true
      sleep 2
      # Create with RoleArn (not supported by Terraform aws provider)
      aws quicksight create-data-source \
        --aws-account-id ${var.account_id} \
        --data-source-id "datalake-athena-${var.environment}" \
        --name "Data Lake Athena (${var.environment})" \
        --type ATHENA \
        --data-source-parameters '{"AthenaParameters":{"WorkGroup":"${var.athena_workgroup_name}","RoleArn":"${data.aws_iam_role.quicksight_service[0].arn}"}}' \
        --permissions '[{"Principal":"arn:aws:quicksight:${data.aws_region.current.id}:${var.account_id}:user/default/AWSReservedSSO_AdministratorAccess_acf5dc9d63ba965c/tfawibe","Actions":["quicksight:DescribeDataSource","quicksight:DescribeDataSourcePermissions","quicksight:PassDataSource","quicksight:UpdateDataSource","quicksight:DeleteDataSource","quicksight:UpdateDataSourcePermissions"]}]'
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws quicksight delete-data-source \
        --aws-account-id ${self.triggers.account_id} \
        --data-source-id "datalake-athena-${self.triggers.account_id}" 2>/dev/null || true
    EOT
  }

  depends_on = [
    aws_quicksight_account_subscription.this,
    aws_iam_role_policy.quicksight_s3_and_glue,
    aws_iam_role_policy.quicksight_kms,
  ]
}
