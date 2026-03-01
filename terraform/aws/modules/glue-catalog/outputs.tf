/**
 * glue-catalog -- Outputs
 *
 * Exposes database names/ARNs and schema registry details for
 * downstream modules (Lake Formation LF-Tags, IAM personas, Athena).
 */

# =============================================================================
# Glue Catalog Databases
# =============================================================================

output "database_names" {
  description = "Map of logical name to actual Glue Catalog database name"
  value       = { for k, v in aws_glue_catalog_database.this : k => v.name }
}

output "database_arns" {
  description = "Map of logical name to Glue Catalog database ARN"
  value       = { for k, v in aws_glue_catalog_database.this : k => v.arn }
}

# =============================================================================
# Schema Registry
# =============================================================================

output "registry_name" {
  description = "Name of the Glue Schema Registry"
  value       = aws_glue_registry.this.registry_name
}

output "registry_arn" {
  description = "ARN of the Glue Schema Registry"
  value       = aws_glue_registry.this.arn
}
