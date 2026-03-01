locals {
  env = terraform.workspace

  # ---------------------------------------------------------------------------
  # Per-environment config map — the single source of truth for env differences.
  # All module parameters that vary between dev and prod live here.
  # ---------------------------------------------------------------------------
  config = {
    dev = {
      # MSK
      broker_instance_type       = "kafka.t3.small"
      broker_count               = 1
      default_replication_factor = 1

      # S3 lifecycle
      raw_ia_transition_days = 0 # Disabled in dev

      # Athena
      athena_scan_limit_bytes = 10737418240 # 10 GB
      enable_result_reuse     = false

      # QuickSight
      enable_quicksight = false

      # Audit retention
      audit_retention_days = 90

      # Aurora (not used in dev — local Postgres in Kind)
      enable_aurora          = false
      aurora_instance_class  = "db.t4g.medium"
      aurora_instance_count  = 1

      # MSK (not used in dev — Strimzi Kafka locally in Kind)
      enable_msk = false

      # MSK Connect (not used in dev — Strimzi Kafka Connect locally)
      enable_msk_connect = false

      # Lambda producer (not used in dev — producer runs locally)
      enable_lambda_producer = false

      # Glue ETL
      enable_glue_etl  = true
      glue_worker_count = 2
      glue_schedule     = "" # ON_DEMAND for dev
    }

    prod = {
      # MSK
      broker_instance_type       = "kafka.m5.large"
      broker_count               = 3
      default_replication_factor = 3

      # S3 lifecycle
      raw_ia_transition_days = 90

      # Athena
      athena_scan_limit_bytes = 1099511627776 # 1 TB
      enable_result_reuse     = true

      # QuickSight
      enable_quicksight = true

      # Audit retention — 5 years per SEC Rule 204-2
      audit_retention_days = 1825

      # Aurora PostgreSQL
      enable_aurora          = true
      aurora_instance_class  = "db.r6g.large"
      aurora_instance_count  = 2

      # MSK
      enable_msk = true

      # MSK Connect
      enable_msk_connect = true

      # Lambda producer
      enable_lambda_producer = true

      # Glue ETL
      enable_glue_etl   = true
      glue_worker_count = 5
      glue_schedule     = "cron(0 */6 * * ? *)" # Every 6 hours
    }
  }

  # Shorthand — use `local.c.broker_count` throughout
  c = local.config[local.env]
}
