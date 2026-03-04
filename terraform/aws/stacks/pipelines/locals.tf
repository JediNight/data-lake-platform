locals {
  env        = terraform.workspace
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  config = {
    dev = {
      enable_local_dev           = true
      enable_msk                 = false
      enable_msk_connect         = false
      enable_debezium_connector  = false
      enable_lambda_producer     = false
      enable_glue_etl            = true
      enable_aurora              = false
      default_replication_factor = 1
      glue_worker_count          = 2
      glue_schedule              = ""
      athena_scan_limit_bytes    = 10737418240
      enable_result_reuse        = false
    }
    prod = {
      enable_local_dev           = false
      enable_msk                 = true
      enable_msk_connect         = true
      enable_debezium_connector  = true
      enable_lambda_producer     = true
      enable_glue_etl            = true
      enable_aurora              = true
      default_replication_factor = 2
      glue_worker_count          = 5
      glue_schedule              = "cron(0 */6 * * ? *)"
      athena_scan_limit_bytes    = 1099511627776
      enable_result_reuse        = true
    }
  }

  c = local.config[local.env]

  # Deterministic ARNs
  mnpi_bucket_arn          = "arn:aws:s3:::datalake-mnpi-${local.env}"
  nonmnpi_bucket_arn       = "arn:aws:s3:::datalake-nonmnpi-${local.env}"
  mnpi_bucket_id           = "datalake-mnpi-${local.env}"
  nonmnpi_bucket_id        = "datalake-nonmnpi-${local.env}"
  query_results_bucket_id  = "datalake-query-results-${local.account_id}-${local.env}"
  nonmnpi_kms_alias_arn    = "arn:aws:kms:${local.region}:${local.account_id}:alias/datalake-nonmnpi-${local.env}"
  kafka_connect_role_arn   = "arn:aws:iam::${local.account_id}:role/datalake-kafka-connect-${local.env}"
  glue_etl_role_arn        = "arn:aws:iam::${local.account_id}:role/datalake-glue-etl-${local.env}"
}
