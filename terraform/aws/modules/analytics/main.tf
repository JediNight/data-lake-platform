/**
 * analytics -- Athena Workgroups & Named Queries
 *
 * Provisions per-persona Athena workgroups with isolated S3 result
 * prefixes, per-query scan limits, and SSE-KMS encryption.  Three
 * workgroups are created via for_each:
 *
 *   - finance-analysts  (scan-limited, result reuse in prod)
 *   - data-analysts     (scan-limited, result reuse in prod)
 *   - data-engineers    (unlimited scans for ETL / exploration)
 *
 * Each workgroup writes query results to a distinct S3 prefix so
 * downstream IAM / Lake Formation policies can restrict cross-persona
 * access to result sets.
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
    Module      = "analytics"
    Environment = var.environment
  })

  # Per-persona workgroup definitions.
  # scan_limit_bytes = 0 means unlimited (data-engineers get full access).
  workgroups = {
    finance-analysts = {
      description      = "Athena workgroup for finance analyst persona"
      scan_limit_bytes = var.athena_scan_limit_bytes
    }
    data-analysts = {
      description      = "Athena workgroup for data analyst persona"
      scan_limit_bytes = var.athena_scan_limit_bytes
    }
    data-engineers = {
      description      = "Athena workgroup for data engineer persona"
      scan_limit_bytes = 0 # unlimited for ETL and exploration
    }
  }
}

# =============================================================================
# Athena Workgroups (3 -- one per persona)
# =============================================================================

resource "aws_athena_workgroup" "this" {
  for_each = local.workgroups

  name          = "${each.key}-${var.environment}"
  description   = "${each.value.description} (${var.environment})"
  state         = "ENABLED"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # Per-query byte scan limit (0 = unlimited → null omits the limit)
    bytes_scanned_cutoff_per_query = each.value.scan_limit_bytes > 0 ? each.value.scan_limit_bytes : null

    result_configuration {
      output_location = "s3://${var.query_results_bucket_id}/${each.key}/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }

    # Result reuse -- only enabled in prod to speed up repeated analyst queries
    dynamic "engine_version" {
      for_each = var.enable_result_reuse ? [1] : []
      content {
        selected_engine_version = "AUTO"
      }
    }
  }

  tags = merge(local.common_tags, {
    Name    = "${each.key}-${var.environment}"
    Persona = each.key
  })
}

# =============================================================================
# Named Queries (demo / quick-start queries per persona)
# =============================================================================

resource "aws_athena_named_query" "finance_sample" {
  name        = "finance-portfolio-summary-${var.environment}"
  description = "Sample query: aggregate portfolio positions for finance analysts"
  workgroup   = aws_athena_workgroup.this["finance-analysts"].name
  database    = "analytics_nonmnpi_${var.environment}"

  query = <<-SQL
    -- Finance analyst sample: portfolio position summary
    SELECT
      account_id,
      instrument_id,
      SUM(CASE WHEN side = 'BUY' THEN quantity ELSE -quantity END) AS net_position,
      COUNT(*) AS trade_count
    FROM curated_nonmnpi_${var.environment}.orders
    GROUP BY account_id, instrument_id
    ORDER BY net_position DESC
    LIMIT 100;
  SQL
}

resource "aws_athena_named_query" "data_analyst_sample" {
  name        = "analyst-daily-volume-${var.environment}"
  description = "Sample query: daily trading volume for data analysts"
  workgroup   = aws_athena_workgroup.this["data-analysts"].name
  database    = "analytics_nonmnpi_${var.environment}"

  query = <<-SQL
    -- Data analyst sample: daily trading volume
    SELECT
      DATE(from_unixtime(timestamp_ms / 1000)) AS trade_date,
      instrument_id,
      COUNT(*)   AS trade_count,
      SUM(quantity * price) AS notional_volume
    FROM curated_nonmnpi_${var.environment}.orders
    WHERE status IN ('FILLED', 'PARTIALLY_FILLED')
    GROUP BY 1, 2
    ORDER BY trade_date DESC, notional_volume DESC
    LIMIT 200;
  SQL
}

resource "aws_athena_named_query" "data_engineer_sample" {
  name        = "engineer-data-quality-${var.environment}"
  description = "Sample query: data quality checks for data engineers"
  workgroup   = aws_athena_workgroup.this["data-engineers"].name
  database    = "raw_nonmnpi_${var.environment}"

  query = <<-SQL
    -- Data engineer sample: data quality / freshness check
    SELECT
      '$path'          AS file_path,
      COUNT(*)         AS row_count,
      COUNT(DISTINCT order_id) AS unique_orders,
      MIN(from_unixtime(timestamp_ms / 1000)) AS earliest_event,
      MAX(from_unixtime(timestamp_ms / 1000)) AS latest_event,
      SUM(CASE WHEN order_id IS NULL THEN 1 ELSE 0 END) AS null_order_ids
    FROM raw_nonmnpi_${var.environment}.order_events
    GROUP BY "$path"
    ORDER BY latest_event DESC
    LIMIT 50;
  SQL
}
