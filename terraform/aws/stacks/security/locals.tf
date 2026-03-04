locals {
  env        = terraform.workspace
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  config = {
    dev = {
      enable_quicksight    = true
      audit_retention_days = 90
      enable_aurora        = false
    }
    prod = {
      enable_quicksight    = true
      audit_retention_days = 1827
      enable_aurora        = true
    }
  }

  c = local.config[local.env]

  # ---------------------------------------------------------------------------
  # Deterministic ARN construction — no terraform_remote_state needed
  # ---------------------------------------------------------------------------

  # S3 bucket ARNs (deterministic from naming convention)
  mnpi_bucket_arn          = "arn:aws:s3:::datalake-mnpi-${local.env}"
  nonmnpi_bucket_arn       = "arn:aws:s3:::datalake-nonmnpi-${local.env}"
  audit_bucket_arn         = "arn:aws:s3:::datalake-audit-${local.env}"
  query_results_bucket_arn = "arn:aws:s3:::datalake-query-results-${local.account_id}-${local.env}"

  # S3 bucket IDs (= bucket name, same as ARN suffix)
  audit_bucket_id = "datalake-audit-${local.env}"

  # KMS alias ARNs (deterministic — NOT key ARNs which are UUIDs)
  mnpi_kms_alias_arn    = "arn:aws:kms:${local.region}:${local.account_id}:alias/datalake-mnpi-${local.env}"
  nonmnpi_kms_alias_arn = "arn:aws:kms:${local.region}:${local.account_id}:alias/datalake-nonmnpi-${local.env}"

  # Glue registry ARN (deterministic)
  glue_registry_arn = "arn:aws:glue:${local.region}:${local.account_id}:registry/datalake-schemas-${local.env}"

  # MSK cluster ARN pattern (contains random UUID suffix — use wildcard)
  msk_cluster_arn = "arn:aws:kafka:${local.region}:${local.account_id}:cluster/datalake-msk-${local.env}/*"

  # Aurora secret ARN pattern (Secrets Manager appends random suffix)
  aurora_secret_arn = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:datalake/aurora/${local.env}/master-password-*"

  # IAM service role ARNs (deterministic)
  kafka_connect_role_arn = "arn:aws:iam::${local.account_id}:role/datalake/datalake-kafka-connect-${local.env}"
  glue_etl_role_arn      = "arn:aws:iam::${local.account_id}:role/datalake/datalake-glue-etl-${local.env}"

  # SSO role patterns (for bucket DENY policy exemption)
  # NOTE: path may or may not include a region segment (e.g. us-east-1/)
  sso_data_engineer_role_pattern = "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_DataEngineer_*"
  sso_admin_role_pattern         = "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_AdministratorAccess_*"
  sso_reviewer_role_arn          = "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_Reviewer_bdf4a9c7ce608ce6"

  # Lake Formation service-linked role (used by Athena for Iceberg writes)
  lf_data_access_role_arn = "arn:aws:iam::${local.account_id}:role/aws-service-role/lakeformation.amazonaws.com/AWSServiceRoleForLakeFormationDataAccess"

  # Exempt principals for bucket DENY policies
  bucket_deny_exempt_arns = [
    local.sso_data_engineer_role_pattern,
    local.sso_admin_role_pattern,
    local.sso_reviewer_role_arn,
    local.kafka_connect_role_arn,
    local.glue_etl_role_arn,
    local.lf_data_access_role_arn,
  ]

  # Glue database names (deterministic from naming convention)
  database_names = {
    raw_mnpi          = "raw_mnpi_${local.env}"
    raw_nonmnpi       = "raw_nonmnpi_${local.env}"
    curated_mnpi      = "curated_mnpi_${local.env}"
    curated_nonmnpi   = "curated_nonmnpi_${local.env}"
    analytics_mnpi    = "analytics_mnpi_${local.env}"
    analytics_nonmnpi = "analytics_nonmnpi_${local.env}"
  }
}
