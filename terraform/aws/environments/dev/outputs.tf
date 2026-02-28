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
  value       = module.streaming.cluster_arn
}

output "msk_bootstrap_brokers_iam" {
  description = "MSK IAM bootstrap broker connection string"
  value       = module.streaming.bootstrap_brokers_iam
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
