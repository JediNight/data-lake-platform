/**
 * identity-center — Outputs
 *
 * Exposes group IDs for Lake Formation grants and SSO role pattern
 * for bucket policy bypass.
 */

output "finance_analysts_group_id" {
  description = "Identity Center group ID for finance analysts"
  value       = aws_identitystore_group.finance_analysts.group_id
}

output "data_analysts_group_id" {
  description = "Identity Center group ID for data analysts"
  value       = aws_identitystore_group.data_analysts.group_id
}

output "data_engineers_group_id" {
  description = "Identity Center group ID for data engineers"
  value       = aws_identitystore_group.data_engineers.group_id
}

output "data_engineer_sso_role_pattern" {
  description = "ArnLike pattern for SSO-generated DataEngineer role (for bucket policy bypass)"
  value       = "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_DataEngineer_*"
}

output "sso_instance_arn" {
  description = "SSO instance ARN for Lake Formation IC configuration"
  value       = local.sso_instance_arn
}
