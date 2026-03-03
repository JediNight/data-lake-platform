/**
 * MSK Connect Module
 *
 * Managed Kafka Connect connectors for the data lake platform:
 * 1. Debezium source — CDC from Aurora PostgreSQL to MSK topics
 * 2. Iceberg S3 sink — writes CDC + streaming topics to S3 as Iceberg tables
 *
 * Uses AWS-managed connector infrastructure (no self-hosted Kafka Connect).
 *
 * Iceberg sinks are driven by `local.iceberg_sinks` — a config map keyed by
 * data zone (mnpi / nonmnpi).  Add a new zone by adding a key to the map;
 * all shared connector plumbing (plugin, worker config, VPC, IAM, logging)
 * is applied via a single `for_each` resource.
 */

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Read Aurora master password from Secrets Manager (for Debezium connector config)
data "aws_secretsmanager_secret_version" "aurora" {
  count     = var.enable_debezium_connector ? 1 : 0
  secret_id = var.aurora_secret_arn
}

# =============================================================================
# Locals — Iceberg Sink Config Map
# =============================================================================

locals {
  iceberg_sinks = {
    mnpi = {
      topics        = "cdc.trading.orders,cdc.trading.trades,cdc.trading.positions"
      bucket_arn    = var.mnpi_bucket_arn
      tables        = "raw_mnpi_${var.environment}.orders,raw_mnpi_${var.environment}.trades,raw_mnpi_${var.environment}.positions"
      cdc_transform = true # All topics are Debezium CDC — apply DebeziumTransform
      route_rules = {
        "raw_mnpi_${var.environment}.orders"    = "cdc\\.trading\\.orders"
        "raw_mnpi_${var.environment}.trades"    = "cdc\\.trading\\.trades"
        "raw_mnpi_${var.environment}.positions" = "cdc\\.trading\\.positions"
      }
    }
    nonmnpi = {
      topics        = "cdc.trading.accounts,cdc.trading.instruments,stream.market-data"
      bucket_arn    = var.nonmnpi_bucket_arn
      tables        = "raw_nonmnpi_${var.environment}.accounts,raw_nonmnpi_${var.environment}.instruments,raw_nonmnpi_${var.environment}.market_data"
      cdc_transform = false # Mixed CDC + direct stream — DebeziumTransform would break stream.market-data
      route_rules = {
        "raw_nonmnpi_${var.environment}.accounts"    = "cdc\\.trading\\.accounts"
        "raw_nonmnpi_${var.environment}.instruments"  = "cdc\\.trading\\.instruments"
        "raw_nonmnpi_${var.environment}.market_data"  = "stream\\.market-data"
      }
    }
  }
}

# =============================================================================
# Custom Plugins
# Plugin JARs/ZIPs are uploaded out-of-band via scripts/upload-connector-plugins.sh.
# We only manage the S3 bucket and MSK Connect plugin resources here.
# =============================================================================

resource "aws_s3_bucket" "plugins" {
  bucket        = "datalake-msk-connect-plugins-${data.aws_caller_identity.current.account_id}-${var.environment}"
  force_destroy = true
}

resource "aws_mskconnect_custom_plugin" "debezium" {
  name         = "debezium-postgres-${var.environment}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.plugins.arn
      file_key   = "debezium-postgres/debezium-connector-postgres-${var.debezium_version}-plugin.zip"
    }
  }
}

resource "aws_mskconnect_custom_plugin" "iceberg_sink" {
  name         = "iceberg-sink-${var.environment}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.plugins.arn
      file_key   = "iceberg-sink/iceberg-kafka-connect-runtime-${var.iceberg_connector_version}.zip"
    }
  }
}

# =============================================================================
# Worker Configuration
# =============================================================================

resource "aws_mskconnect_worker_configuration" "this" {
  name                    = "datalake-connect-${var.environment}"
  properties_file_content = <<-EOT
    key.converter=org.apache.kafka.connect.json.JsonConverter
    value.converter=org.apache.kafka.connect.json.JsonConverter
    key.converter.schemas.enable=false
    value.converter.schemas.enable=false
    topic.creation.enable=true
    topic.creation.default.replication.factor=${var.default_replication_factor}
    topic.creation.default.partitions=3
    topic.creation.default.cleanup.policy=delete
  EOT
}

# =============================================================================
# CDC Ready Gate — blocks Debezium until Aurora CDC setup is complete
# =============================================================================

resource "null_resource" "cdc_ready_gate" {
  count = var.enable_debezium_connector ? 1 : 0
  triggers = {
    cdc_setup_id = var.aurora_cdc_setup_id
  }
}

# =============================================================================
# Debezium Source Connector
# Requires Aurora CDC setup: replication slot, publication, Secrets Manager password.
# =============================================================================

resource "aws_mskconnect_connector" "debezium_source" {
  count = var.enable_debezium_connector ? 1 : 0
  name  = "debezium-source-${var.environment}"

  kafkaconnect_version = "3.7.x"

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    # Connector identity
    "connector.class" = "io.debezium.connector.postgresql.PostgresConnector"
    "tasks.max"       = "1"

    # Database connection
    "database.hostname" = var.postgres_endpoint
    "database.port"     = tostring(var.postgres_port)
    "database.user"     = "postgres"
    "database.password" = jsondecode(data.aws_secretsmanager_secret_version.aurora[0].secret_string)["password"]
    "database.dbname"   = "trading"
    "database.sslmode"  = "require" # Aurora PG 15 enforces SSL

    # PostgreSQL logical replication
    "plugin.name"                 = "pgoutput"
    "publication.name"            = "debezium_publication"
    "publication.autocreate.mode" = "disabled" # Publication created by init-aurora-cdc.sh
    "slot.name"                   = "debezium_slot"

    # Topic configuration
    "topic.prefix"          = "cdc.trading"
    "topic.naming.strategy" = "io.debezium.schema.DefaultTopicNamingStrategy" # Omit schema from topic names: cdc.trading.orders (not cdc.trading.public.orders)
    "table.include.list"    = "public.orders,public.trades,public.positions,public.accounts,public.instruments"

    # Converters
    "key.converter"                  = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"   = "false"
    "value.converter.schemas.enable" = "false"

    # Data handling
    "decimal.handling.mode" = "string"
    "snapshot.mode"         = "initial"

    # Heartbeat — prevents WAL bloat on RDS (sends heartbeat every 5 min)
    "heartbeat.interval.ms" = "300000"

    # Error handling
    "errors.log.enable" = "true"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = var.msk_bootstrap_brokers
      vpc {
        subnets         = var.subnet_ids
        security_groups = var.security_group_ids
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.debezium.arn
      revision = aws_mskconnect_custom_plugin.debezium.latest_revision
    }
  }

  worker_configuration {
    arn      = aws_mskconnect_worker_configuration.this.arn
    revision = aws_mskconnect_worker_configuration.this.latest_revision
  }

  service_execution_role_arn = var.kafka_connect_role_arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.connector_logs.name
      }
    }
  }

  depends_on = [
    null_resource.cdc_ready_gate,
  ]
}

# =============================================================================
# Iceberg S3 Sink Connectors (one per data zone via for_each)
# =============================================================================

resource "aws_mskconnect_connector" "iceberg_sink" {
  for_each = local.iceberg_sinks

  name = "iceberg-sink-${each.key}-${var.environment}"

  kafkaconnect_version = "3.7.x"

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = merge(
    {
      "connector.class"                      = "org.apache.iceberg.connect.IcebergSinkConnector"
      "tasks.max"                            = "1"
      "topics"                               = each.value.topics
      "iceberg.catalog.type"                 = "glue"
      "iceberg.catalog.warehouse"            = "s3://${replace(each.value.bucket_arn, "arn:aws:s3:::", "")}"
      "iceberg.catalog.io-impl"              = "org.apache.iceberg.aws.s3.S3FileIO"
      "iceberg.catalog.client.region"        = data.aws_region.current.name
      "iceberg.tables"                       = each.value.tables
      "iceberg.tables.auto-create-enabled"   = "true"
      "iceberg.tables.evolve-schema-enabled" = "true"
      "iceberg.tables.upsert-mode-enabled"   = "false"
      "iceberg.control.topic"                = "control-iceberg-${each.key}"
      "iceberg.control.commit.interval-ms"   = "120000"
      "key.converter"                        = "org.apache.kafka.connect.json.JsonConverter"
      "value.converter"                      = "org.apache.kafka.connect.json.JsonConverter"
      "key.converter.schemas.enable"         = "false"
      "value.converter.schemas.enable"       = "false"

      # Topic-to-table routing — InsertField SMT injects Kafka topic name,
      # then route-field + per-table route-regex directs each record to
      # the correct Iceberg table. Without this, ALL records fan-out to ALL tables.
      "iceberg.tables.route-field" = "_topic"
    },
    # Transform chain:
    #   CDC zones:   DebeziumTransform (unwrap envelope) → InsertField (add _topic)
    #   Mixed zones: InsertField only (CDC records stored as envelope; curated layer extracts)
    each.value.cdc_transform ? {
      "transforms"                         = "debezium,insertTopic"
      "transforms.debezium.type"           = "org.apache.iceberg.connect.transforms.DebeziumTransform"
      "transforms.insertTopic.type"        = "org.apache.kafka.connect.transforms.InsertField$Value"
      "transforms.insertTopic.topic.field" = "_topic"
    } : {
      "transforms"                         = "insertTopic"
      "transforms.insertTopic.type"        = "org.apache.kafka.connect.transforms.InsertField$Value"
      "transforms.insertTopic.topic.field" = "_topic"
    },
    # Per-table route-regex: matches _topic field value to target table
    { for table, regex in each.value.route_rules :
      "iceberg.table.${table}.route-regex" => regex
    }
  )

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = var.msk_bootstrap_brokers
      vpc {
        subnets         = var.subnet_ids
        security_groups = var.security_group_ids
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.iceberg_sink.arn
      revision = aws_mskconnect_custom_plugin.iceberg_sink.latest_revision
    }
  }

  worker_configuration {
    arn      = aws_mskconnect_worker_configuration.this.arn
    revision = aws_mskconnect_worker_configuration.this.latest_revision
  }

  service_execution_role_arn = var.kafka_connect_role_arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.connector_logs.name
      }
    }
  }
}

# =============================================================================
# CloudWatch Logs
# =============================================================================

resource "aws_cloudwatch_log_group" "connector_logs" {
  name              = "/msk-connect/datalake-${var.environment}"
  retention_in_days = 14
}
