/**
 * streaming -- MSK Provisioned Cluster (IAM Auth, TLS Encryption)
 *
 * Creates an Amazon MSK Provisioned cluster for the data lake streaming layer:
 *   1. MSK Configuration with broker-level settings (topic auto-create,
 *      replication factor, retention)
 *   2. CloudWatch log group for broker logs
 *   3. MSK Provisioned cluster with IAM authentication and TLS encryption
 *
 * DESIGN DECISIONS:
 *   - Provisioned (not Serverless) because Debezium requires per-topic
 *     configuration for its schema history topic, which MSK Serverless
 *     does not support.
 *   - IAM authentication is used instead of SASL/SCRAM so that Kafka Connect
 *     pods can authenticate via IRSA (IAM Roles for Service Accounts) without
 *     managing static credentials.
 *   - TLS is enforced both client-to-broker and inter-broker. Plaintext
 *     listeners are disabled.
 *   - Encryption at rest uses the default AWS managed key unless a custom
 *     KMS key ARN is provided.
 *   - auto.create.topics.enable is set to true so that Debezium can create
 *     its internal topics (connect-offsets, connect-configs, connect-status,
 *     schema-changes) automatically on first connect.
 *   - Dev uses kafka.t3.small with 1 broker; prod uses kafka.m5.large with
 *     3 brokers. This is controlled by broker_instance_type and broker_count
 *     variables.
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
# Local Values
# =============================================================================

locals {
  cluster_name = "datalake-msk-${var.environment}"

  common_tags = merge(var.tags, {
    Module      = "streaming"
    Environment = var.environment
  })
}

# =============================================================================
# MSK Configuration
# =============================================================================
#
# Pre-configures broker-level settings. These are applied to every broker in
# the cluster. Changes to the configuration create a new revision; MSK rolls
# brokers one at a time to apply it.
# =============================================================================

resource "aws_msk_configuration" "this" {
  name           = "${local.cluster_name}-config"
  kafka_versions = [var.kafka_version]
  description    = "Broker configuration for ${local.cluster_name}"

  server_properties = <<-PROPERTIES
    auto.create.topics.enable = true
    default.replication.factor = ${var.default_replication_factor}
    min.insync.replicas = 1
    num.partitions = 3
    log.retention.hours = 168
  PROPERTIES

  tags = local.common_tags
}

# =============================================================================
# CloudWatch Log Group -- Broker Logs
# =============================================================================
#
# MSK broker logs are shipped to CloudWatch for operational visibility.
# The log group is created explicitly so we control retention and naming.
# =============================================================================

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${local.cluster_name}"
  retention_in_days = 30

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-broker-logs"
  })
}

# =============================================================================
# MSK Provisioned Cluster
# =============================================================================

resource "aws_msk_cluster" "this" {
  cluster_name           = local.cluster_name
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.broker_count

  # ---------------------------------------------------------------------------
  # Broker Node Configuration
  # ---------------------------------------------------------------------------

  broker_node_group_info {
    instance_type   = var.broker_instance_type
    client_subnets  = var.subnet_ids
    security_groups = [var.msk_security_group_id]

    storage_info {
      ebs_storage_info {
        volume_size = var.broker_ebs_volume_size
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Apply Broker Configuration
  # ---------------------------------------------------------------------------

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  # ---------------------------------------------------------------------------
  # Authentication -- IAM Only
  # ---------------------------------------------------------------------------
  #
  # IAM auth enables IRSA-based authentication for Kafka Connect pods running
  # on EKS. No static credentials to rotate.
  # ---------------------------------------------------------------------------

  client_authentication {
    unauthenticated = false

    sasl {
      iam = true
    }
  }

  # ---------------------------------------------------------------------------
  # Encryption
  # ---------------------------------------------------------------------------
  #
  # TLS is enforced for all traffic:
  #   - client_broker = "TLS" disables plaintext listeners
  #   - in_cluster    = true encrypts inter-broker replication
  #   - encryption_at_rest uses default AWS managed key or custom KMS
  # ---------------------------------------------------------------------------

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }

    encryption_at_rest_kms_key_arn = var.kms_key_arn
  }

  # ---------------------------------------------------------------------------
  # Monitoring -- Enhanced
  # ---------------------------------------------------------------------------
  #
  # JMX and Node exporters are enabled so that Prometheus can scrape broker
  # metrics. DEFAULT monitoring level gives us per-broker metrics at no
  # additional cost. PER_TOPIC_PER_BROKER gives topic-level granularity.
  # ---------------------------------------------------------------------------

  open_monitoring {
    prometheus {
      jmx_exporter {
        enabled_in_broker = true
      }

      node_exporter {
        enabled_in_broker = true
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Logging -- Broker Logs to CloudWatch
  # ---------------------------------------------------------------------------

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  tags = merge(local.common_tags, {
    Name = local.cluster_name
  })
}
