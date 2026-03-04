# Bucket IDs/ARNs are NOT needed as remote_state outputs —
# downstream stacks construct deterministic ARNs from naming conventions.
# These outputs exist for operational convenience (e.g. CLI queries).

output "mnpi_bucket_id" {
  value = module.data_lake_storage.mnpi_bucket_id
}

output "nonmnpi_bucket_id" {
  value = module.data_lake_storage.nonmnpi_bucket_id
}

output "audit_bucket_id" {
  value = module.data_lake_storage.audit_bucket_id
}

output "query_results_bucket_id" {
  value = module.data_lake_storage.query_results_bucket_id
}

output "glue_database_names" {
  value = module.glue_catalog.database_names
}

output "glue_registry_arn" {
  value = module.glue_catalog.registry_arn
}
