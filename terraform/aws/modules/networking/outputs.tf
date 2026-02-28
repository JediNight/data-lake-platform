/**
 * networking — Outputs
 *
 * Exposes VPC, subnet, security group, and endpoint IDs for downstream
 * modules (MSK streaming, EKS workloads, IAM policies).
 */

# =============================================================================
# VPC
# =============================================================================

output "vpc_id" {
  description = "ID of the data lake VPC"
  value       = aws_vpc.main.id
}

# =============================================================================
# Subnets
# =============================================================================

output "private_subnet_ids" {
  description = "List of private subnet IDs (one per AZ, for MSK and EKS)"
  value       = aws_subnet.private[*].id
}

# =============================================================================
# Security Groups
# =============================================================================

output "msk_security_group_id" {
  description = "Security group ID for MSK brokers"
  value       = aws_security_group.msk.id
}

output "eks_node_security_group_id" {
  description = "Security group ID for EKS worker nodes"
  value       = aws_security_group.eks_node.id
}

# =============================================================================
# VPC Endpoints
# =============================================================================

output "s3_endpoint_id" {
  description = "ID of the S3 VPC gateway endpoint"
  value       = aws_vpc_endpoint.s3.id
}
