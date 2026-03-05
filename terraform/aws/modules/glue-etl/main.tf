/**
 * glue-etl — Glue Jobs, Workflow, Triggers, S3 Script Uploads
 *
 * Creates the production ETL pipeline for the medallion architecture:
 *   - 4 Glue PySpark jobs (2 curated + 2 analytics)
 *   - 1 Glue workflow orchestrating the dependency chain
 *   - ON_DEMAND trigger for curated jobs (parallel)
 *   - CONDITIONAL trigger: curated success -> analytics jobs (parallel)
 *   - S3 script uploads (from scripts/glue/ to query-results bucket)
 *
 * IAM role is NOT in this module — it lives in service-roles/
 * to avoid circular dependencies with S3 bucket DENY policies.
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
    Module      = "glue-etl"
    Environment = var.environment
  })

  # Zone-to-bucket mapping for Iceberg warehouse paths
  zone_buckets = {
    mnpi    = var.mnpi_bucket_id
    nonmnpi = var.nonmnpi_bucket_id
  }

  # Job config map — drives for_each on aws_s3_object and aws_glue_job
  jobs = {
    curated_order_events = {
      script = "curated_order_events.py"
      layer  = "curated"
      zone   = "mnpi"
    }
    curated_market_ticks = {
      script = "curated_market_ticks.py"
      layer  = "curated"
      zone   = "nonmnpi"
    }
    analytics_order_summary = {
      script = "analytics_order_summary.py"
      layer  = "analytics"
      zone   = "mnpi"
    }
    analytics_market_summary = {
      script = "analytics_market_summary.py"
      layer  = "analytics"
      zone   = "nonmnpi"
    }
  }
}

# =============================================================================
# S3 Script Uploads
# =============================================================================
# Scripts stored in query-results bucket (no DENY policy).
# source_hash triggers re-upload when the local file content changes,
# without comparing against S3 ETags (which differ under SSE encryption).
# =============================================================================

resource "aws_s3_object" "scripts" {
  for_each = local.jobs

  bucket      = var.scripts_bucket_id
  key         = "glue-scripts/${each.value.script}"
  source      = "${path.module}/../../../../scripts/glue/${each.value.script}"
  source_hash = filemd5("${path.module}/../../../../scripts/glue/${each.value.script}")

  tags = local.common_tags
}

# Shared helper library — referenced by all jobs via --extra-py-files
resource "aws_s3_object" "incremental_lib" {
  bucket      = var.scripts_bucket_id
  key         = "glue-scripts/lib/incremental.py"
  source      = "${path.module}/../../../../scripts/glue/lib/incremental.py"
  source_hash = filemd5("${path.module}/../../../../scripts/glue/lib/incremental.py")

  tags = local.common_tags
}

# =============================================================================
# Glue Jobs (for_each over 4 jobs)
# =============================================================================

resource "aws_glue_job" "this" {
  for_each = local.jobs

  name     = "datalake-${replace(each.key, "_", "-")}-${var.environment}"
  role_arn = var.glue_role_arn

  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = var.worker_count

  command {
    name            = "glueetl"
    script_location = "s3://${var.scripts_bucket_id}/glue-scripts/${each.value.script}"
    python_version  = "3"
  }

  default_arguments = {
    "--datalake-formats"                 = "iceberg"
    "--environment"                      = var.environment
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${var.scripts_bucket_id}/glue-temp/"
    "--iceberg-warehouse"                = "s3://${local.zone_buckets[each.value.zone]}/"
    "--extra-py-files"                   = "s3://${var.scripts_bucket_id}/glue-scripts/lib/incremental.py"
    "--full-refresh"                     = "false"
  }

  tags = merge(local.common_tags, {
    Name     = "datalake-${replace(each.key, "_", "-")}-${var.environment}"
    Layer    = each.value.layer
    DataZone = each.value.zone
  })

  depends_on = [aws_s3_object.scripts, aws_s3_object.incremental_lib]
}

# =============================================================================
# Workflow — Medallion pipeline orchestration
# =============================================================================

resource "aws_glue_workflow" "medallion" {
  name = "datalake-medallion-${var.environment}"

  tags = merge(local.common_tags, {
    Name = "datalake-medallion-${var.environment}"
  })
}

# =============================================================================
# Triggers
# =============================================================================

# Start trigger — fires both curated jobs in parallel (SCHEDULED in prod, ON_DEMAND in dev)
resource "aws_glue_trigger" "start_curated" {
  name              = "datalake-start-curated-${var.environment}"
  type              = var.schedule_expression != "" ? "SCHEDULED" : "ON_DEMAND"
  workflow_name     = aws_glue_workflow.medallion.name
  schedule          = var.schedule_expression != "" ? var.schedule_expression : null
  start_on_creation = var.schedule_expression != "" ? true : null

  actions {
    job_name = aws_glue_job.this["curated_order_events"].name
  }

  actions {
    job_name = aws_glue_job.this["curated_market_ticks"].name
  }

  tags = local.common_tags
}

# Conditional trigger — when BOTH curated jobs succeed, fire analytics jobs
resource "aws_glue_trigger" "curated_to_analytics" {
  name          = "datalake-curated-to-analytics-${var.environment}"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.medallion.name

  predicate {
    conditions {
      job_name = aws_glue_job.this["curated_order_events"].name
      state    = "SUCCEEDED"
    }

    conditions {
      job_name = aws_glue_job.this["curated_market_ticks"].name
      state    = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.this["analytics_order_summary"].name
  }

  actions {
    job_name = aws_glue_job.this["analytics_market_summary"].name
  }

  tags = local.common_tags
}
