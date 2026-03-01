/**
 * analytics -- Outputs
 *
 * Exposes Athena workgroup names and ARNs for downstream modules
 * (IAM persona policies, CI/CD query runners, monitoring dashboards).
 */

# =============================================================================
# Athena Workgroups
# =============================================================================

output "workgroup_names" {
  description = "Map of persona key to Athena workgroup name"
  value       = { for k, v in aws_athena_workgroup.this : k => v.name }
}

output "workgroup_arns" {
  description = "Map of persona key to Athena workgroup ARN"
  value       = { for k, v in aws_athena_workgroup.this : k => v.arn }
}
