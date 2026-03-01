/**
 * glue-catalog -- Glue Databases & Schema Registry
 *
 * Creates the six Glue Catalog databases that map to the medallion
 * architecture (raw / curated / analytics) crossed with the two MNPI
 * sensitivity zones (mnpi / non-mnpi).  Each database points its
 * LOCATION_URI at the corresponding S3 prefix so crawlers, Spark jobs,
 * and Athena can discover data automatically.
 *
 * Also provisions a Glue Schema Registry with placeholder Avro schemas
 * for streaming topics (order-events, market-data).  These schemas will
 * be referenced by Kafka Connect sink connectors and downstream consumers.
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
    Module      = "glue-catalog"
    Environment = var.environment
  })

  # Medallion layers x MNPI zones -- drives the for_each on aws_glue_catalog_database
  databases = {
    raw_mnpi = {
      bucket      = var.mnpi_bucket_id
      prefix      = "raw"
      sensitivity = "mnpi"
    }
    raw_nonmnpi = {
      bucket      = var.nonmnpi_bucket_id
      prefix      = "raw"
      sensitivity = "non-mnpi"
    }
    curated_mnpi = {
      bucket      = var.mnpi_bucket_id
      prefix      = "curated"
      sensitivity = "mnpi"
    }
    curated_nonmnpi = {
      bucket      = var.nonmnpi_bucket_id
      prefix      = "curated"
      sensitivity = "non-mnpi"
    }
    analytics_mnpi = {
      bucket      = var.mnpi_bucket_id
      prefix      = "analytics"
      sensitivity = "mnpi"
    }
    analytics_nonmnpi = {
      bucket      = var.nonmnpi_bucket_id
      prefix      = "analytics"
      sensitivity = "non-mnpi"
    }
  }
}

# =============================================================================
# Glue Catalog Databases (6 -- medallion x MNPI)
# =============================================================================

resource "aws_glue_catalog_database" "this" {
  for_each = local.databases

  name         = "${each.key}_${var.environment}"
  description  = "${replace(each.value.prefix, "/^./", upper(substr(each.value.prefix, 0, 1)))} layer (${each.value.sensitivity}) -- ${var.environment}"
  location_uri = "s3://${each.value.bucket}/${each.value.prefix}/"

  tags = merge(local.common_tags, {
    Name            = "${each.key}_${var.environment}"
    MedallionLayer  = each.value.prefix
    DataSensitivity = each.value.sensitivity
  })
}

# =============================================================================
# Glue Schema Registry
# =============================================================================

resource "aws_glue_registry" "this" {
  registry_name = "datalake-schemas-${var.environment}"
  description   = "Avro schema registry for streaming topics (${var.environment})"

  tags = merge(local.common_tags, {
    Name = "datalake-schemas-${var.environment}"
  })
}

# --- Avro Schemas ------------------------------------------------------------

resource "aws_glue_schema" "order_events" {
  schema_name   = "order-events"
  registry_arn  = aws_glue_registry.this.arn
  data_format   = "AVRO"
  compatibility = "BACKWARD"
  schema_definition = jsonencode({
    type      = "record"
    name      = "OrderEvent"
    namespace = "com.datalake.trading"
    fields = [
      { name = "order_id", type = "string" },
      { name = "instrument_id", type = "string" },
      { name = "account_id", type = "string" },
      { name = "side", type = { type = "enum", name = "Side", symbols = ["BUY", "SELL"] } },
      { name = "order_type", type = { type = "enum", name = "OrderType", symbols = ["MARKET", "LIMIT", "STOP"] } },
      { name = "quantity", type = "double" },
      { name = "price", type = ["null", "double"], default = null },
      { name = "status", type = { type = "enum", name = "OrderStatus", symbols = ["NEW", "FILLED", "PARTIALLY_FILLED", "CANCELLED"] } },
      { name = "timestamp_ms", type = "long" },
    ]
  })

  tags = merge(local.common_tags, {
    SchemaName = "order-events"
  })
}

resource "aws_glue_schema" "market_data" {
  schema_name   = "market-data"
  registry_arn  = aws_glue_registry.this.arn
  data_format   = "AVRO"
  compatibility = "BACKWARD"
  schema_definition = jsonencode({
    type      = "record"
    name      = "MarketData"
    namespace = "com.datalake.market"
    fields = [
      { name = "instrument_id", type = "string" },
      { name = "symbol", type = "string" },
      { name = "bid_price", type = "double" },
      { name = "ask_price", type = "double" },
      { name = "last_price", type = "double" },
      { name = "volume", type = "long" },
      { name = "timestamp_ms", type = "long" },
    ]
  })

  tags = merge(local.common_tags, {
    SchemaName = "market-data"
  })
}
