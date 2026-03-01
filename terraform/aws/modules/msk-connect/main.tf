/**
 * MSK Connect Module
 *
 * Managed Kafka Connect connectors for the data lake platform:
 * 1. Debezium source — CDC from Aurora PostgreSQL to MSK topics
 * 2. Iceberg S3 sink — writes CDC + streaming topics to S3 as Iceberg tables
 *
 * Uses AWS-managed connector infrastructure (no self-hosted Kafka Connect).
 */

# =============================================================================
# Custom Plugins
# Plugin JARs/ZIPs are uploaded out-of-band via scripts/upload-connector-plugins.sh.
# We only manage the S3 bucket and MSK Connect plugin resources here.
# =============================================================================

data "aws_caller_identity" "current" {}

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
      file_key   = "debezium-postgres/debezium-connector-postgres-${var.debezium_version}-plugin.tar.gz"
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
    value.converter.schemas.enable=true
  EOT
}

# =============================================================================
# Debezium Source Connector
# =============================================================================

resource "aws_mskconnect_connector" "debezium_source" {
  name = "debezium-source-${var.environment}"

  kafkaconnect_version = "3.7.x"

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class"                = "io.debezium.connector.postgresql.PostgresConnector"
    "tasks.max"                      = "1"
    "database.hostname"              = var.postgres_endpoint
    "database.port"                  = tostring(var.postgres_port)
    "database.user"                  = "postgres"
    "database.dbname"                = "trading"
    "topic.prefix"                   = "cdc.trading"
    "plugin.name"                    = "pgoutput"
    "publication.name"               = "debezium_publication"
    "slot.name"                      = "debezium_slot"
    "table.include.list"             = "public.orders,public.trades,public.positions,public.accounts,public.instruments"
    "key.converter"                  = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"   = "false"
    "value.converter.schemas.enable" = "true"
    "database.password"              = "$${secretManager:datalake/aurora/${var.environment}/master-password}"
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
}

# =============================================================================
# Iceberg S3 Sink Connector (MNPI topics)
# =============================================================================

resource "aws_mskconnect_connector" "iceberg_sink_mnpi" {
  name = "iceberg-sink-mnpi-${var.environment}"

  kafkaconnect_version = "3.7.x"

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class"                    = "org.apache.iceberg.connect.IcebergSinkConnector"
    "tasks.max"                          = "1"
    "topics"                             = "cdc.trading.orders,cdc.trading.trades,cdc.trading.positions"
    "iceberg.catalog.type"               = "glue"
    "iceberg.catalog.warehouse"          = "${var.mnpi_bucket_arn}/"
    "iceberg.tables.auto-create-enabled" = "true"
    "iceberg.tables.upsert-mode-enabled" = "false"
    "key.converter"                      = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"                    = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"       = "false"
    "value.converter.schemas.enable"     = "true"
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
# Iceberg S3 Sink Connector (non-MNPI topics)
# =============================================================================

resource "aws_mskconnect_connector" "iceberg_sink_nonmnpi" {
  name = "iceberg-sink-nonmnpi-${var.environment}"

  kafkaconnect_version = "3.7.x"

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class"                    = "org.apache.iceberg.connect.IcebergSinkConnector"
    "tasks.max"                          = "1"
    "topics"                             = "cdc.trading.accounts,cdc.trading.instruments,stream.market-data"
    "iceberg.catalog.type"               = "glue"
    "iceberg.catalog.warehouse"          = "${var.nonmnpi_bucket_arn}/"
    "iceberg.tables.auto-create-enabled" = "true"
    "iceberg.tables.upsert-mode-enabled" = "false"
    "key.converter"                      = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"                    = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"       = "false"
    "value.converter.schemas.enable"     = "true"
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
