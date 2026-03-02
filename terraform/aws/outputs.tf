# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.networking.private_subnet_ids
}

# -----------------------------------------------------------------------------
# Data Lake Storage — S3 buckets
# -----------------------------------------------------------------------------
output "mnpi_bucket_id" {
  description = "MNPI data bucket name"
  value       = module.data_lake_storage.mnpi_bucket_id
}

output "nonmnpi_bucket_id" {
  description = "Non-MNPI data bucket name"
  value       = module.data_lake_storage.nonmnpi_bucket_id
}

output "audit_bucket_id" {
  description = "Audit log bucket name"
  value       = module.data_lake_storage.audit_bucket_id
}

output "query_results_bucket_id" {
  description = "Athena query results bucket name"
  value       = module.data_lake_storage.query_results_bucket_id
}

# -----------------------------------------------------------------------------
# Streaming — MSK
# -----------------------------------------------------------------------------
output "msk_cluster_arn" {
  description = "MSK cluster ARN"
  value       = local.c.enable_msk ? module.streaming[0].cluster_arn : null
}

output "msk_bootstrap_brokers_iam" {
  description = "MSK IAM bootstrap broker connection string"
  value       = local.c.enable_msk ? module.streaming[0].bootstrap_brokers_iam : null
}

# -----------------------------------------------------------------------------
# Glue Catalog
# -----------------------------------------------------------------------------
output "glue_database_names" {
  description = "Glue catalog database names"
  value       = module.glue_catalog.database_names
}

output "glue_registry_arn" {
  description = "Glue Schema Registry ARN"
  value       = module.glue_catalog.registry_arn
}

# -----------------------------------------------------------------------------
# Identity Center — Group IDs
# -----------------------------------------------------------------------------
output "finance_analysts_group_id" {
  description = "Finance analysts Identity Center group ID"
  value       = module.identity_center.finance_analysts_group_id
}

output "data_analysts_group_id" {
  description = "Data analysts Identity Center group ID"
  value       = module.identity_center.data_analysts_group_id
}

output "data_engineers_group_id" {
  description = "Data engineers Identity Center group ID"
  value       = module.identity_center.data_engineers_group_id
}

# -----------------------------------------------------------------------------
# Service Roles
# -----------------------------------------------------------------------------
output "kafka_connect_role_arn" {
  description = "Kafka Connect IRSA role ARN"
  value       = module.service_roles.kafka_connect_role_arn
}

output "glue_etl_role_arn" {
  description = "Glue ETL IAM role ARN"
  value       = module.service_roles.glue_etl_role_arn
}

# -----------------------------------------------------------------------------
# Analytics — Athena
# -----------------------------------------------------------------------------
output "athena_workgroup_names" {
  description = "Athena workgroup names"
  value       = module.analytics.workgroup_names
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------
output "cloudtrail_arn" {
  description = "CloudTrail trail ARN"
  value       = module.observability.cloudtrail_arn
}

# -----------------------------------------------------------------------------
# Aurora PostgreSQL (prod only)
# -----------------------------------------------------------------------------
output "aurora_cluster_endpoint" {
  description = "Aurora PostgreSQL writer endpoint"
  value       = local.c.enable_aurora ? module.aurora_postgres[0].cluster_endpoint : null
}

# -----------------------------------------------------------------------------
# Glue ETL
# -----------------------------------------------------------------------------
output "glue_etl_workflow_name" {
  description = "Glue medallion workflow name"
  value       = local.c.enable_glue_etl ? module.glue_etl[0].workflow_name : null
}

output "glue_etl_job_names" {
  description = "Glue ETL job names"
  value       = local.c.enable_glue_etl ? module.glue_etl[0].job_names : null
}

# -----------------------------------------------------------------------------
# Lambda Trading Simulator (prod only)
# -----------------------------------------------------------------------------
output "lambda_producer_function_name" {
  description = "Lambda trading simulator function name"
  value       = local.c.enable_lambda_producer ? module.lambda_producer[0].function_name : null
}

output "lambda_producer_function_arn" {
  description = "Lambda trading simulator function ARN"
  value       = local.c.enable_lambda_producer ? module.lambda_producer[0].function_arn : null
}

output "lambda_producer_schedule_rule" {
  description = "EventBridge schedule rule name"
  value       = local.c.enable_lambda_producer ? module.lambda_producer[0].eventbridge_rule_name : null
}
