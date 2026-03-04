# These outputs are consumed by compute and pipelines stacks
# via terraform_remote_state (non-deterministic, AWS-assigned IDs).

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = module.networking.public_subnet_id
}

output "msk_security_group_id" {
  description = "MSK security group ID"
  value       = module.networking.msk_security_group_id
}

output "lambda_security_group_id" {
  description = "Lambda security group ID"
  value       = module.networking.lambda_security_group_id
}
