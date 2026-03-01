/**
 * glue-etl — Outputs
 */

output "workflow_name" {
  description = "Glue medallion workflow name"
  value       = aws_glue_workflow.medallion.name
}

output "job_names" {
  description = "Map of logical name to Glue job name"
  value       = { for k, v in aws_glue_job.this : k => v.name }
}
