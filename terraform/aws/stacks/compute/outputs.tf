# Non-deterministic outputs consumed by pipelines stack via terraform_remote_state

output "bootstrap_brokers_iam" {
  description = "MSK IAM bootstrap broker connection string"
  value       = local.c.enable_msk ? module.streaming[0].bootstrap_brokers_iam : null
}

output "msk_cluster_arn" {
  description = "MSK cluster ARN"
  value       = local.c.enable_msk ? module.streaming[0].cluster_arn : null
}

output "cluster_endpoint" {
  description = "Aurora PostgreSQL writer endpoint"
  value       = local.c.enable_aurora ? module.aurora_postgres[0].cluster_endpoint : null
}

output "cluster_port" {
  description = "Aurora PostgreSQL port"
  value       = local.c.enable_aurora ? module.aurora_postgres[0].cluster_port : null
}

output "cluster_arn" {
  description = "Aurora cluster ARN"
  value       = local.c.enable_aurora ? module.aurora_postgres[0].cluster_arn : null
}

output "master_password_secret_arn" {
  description = "Aurora master password Secrets Manager secret ARN"
  value       = local.c.enable_aurora ? module.aurora_postgres[0].master_password_secret_arn : null
}

output "cdc_setup_complete" {
  description = "CDC setup null_resource ID (dependency trigger)"
  value       = local.c.enable_aurora ? module.aurora_postgres[0].cdc_setup_complete : null
}
