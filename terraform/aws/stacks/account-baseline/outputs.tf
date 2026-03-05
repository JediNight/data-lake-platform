/**
 * Account Baseline — Outputs
 *
 * These outputs are informational. The security stack uses AWS data sources
 * (not terraform_remote_state) to look up Identity Center groups and SSO
 * instance, keeping the stacks decoupled.
 */

output "finance_analysts_group_id" {
  description = "Identity Center group ID for finance analysts"
  value       = module.identity_center.finance_analysts_group_id
}

output "data_analysts_group_id" {
  description = "Identity Center group ID for data analysts"
  value       = module.identity_center.data_analysts_group_id
}

output "data_engineers_group_id" {
  description = "Identity Center group ID for data engineers"
  value       = module.identity_center.data_engineers_group_id
}

output "sso_instance_arn" {
  description = "IAM Identity Center instance ARN"
  value       = module.identity_center.sso_instance_arn
}

output "lf_tag_keys" {
  description = "Lake Formation LF-Tag keys created"
  value       = ["sensitivity", "layer"]
}
