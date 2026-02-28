/**
 * streaming -- Outputs
 *
 * Exposes MSK cluster identifiers and connection strings for downstream
 * modules (Kafka Connect connectors, IAM policies, EKS workloads).
 */

# =============================================================================
# Cluster Identity
# =============================================================================

output "cluster_arn" {
  description = "ARN of the MSK cluster"
  value       = aws_msk_cluster.this.arn
}

output "cluster_name" {
  description = "Name of the MSK cluster"
  value       = aws_msk_cluster.this.cluster_name
}

# =============================================================================
# Connection Strings
# =============================================================================

output "bootstrap_brokers_iam" {
  description = "IAM-authenticated bootstrap broker connection string (port 9098)"
  value       = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
}

output "zookeeper_connect_string" {
  description = "ZooKeeper connection string for the MSK cluster"
  value       = aws_msk_cluster.this.zookeeper_connect_string
}

# =============================================================================
# Configuration
# =============================================================================

output "configuration_arn" {
  description = "ARN of the MSK broker configuration"
  value       = aws_msk_configuration.this.arn
}

# =============================================================================
# Logging
# =============================================================================

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for MSK broker logs"
  value       = aws_cloudwatch_log_group.msk.name
}
