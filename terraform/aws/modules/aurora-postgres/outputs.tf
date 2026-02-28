output "cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.this.endpoint
}

output "cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.this.reader_endpoint
}

output "cluster_port" {
  description = "Aurora cluster port"
  value       = aws_rds_cluster.this.port
}

output "database_name" {
  description = "Database name"
  value       = aws_rds_cluster.this.database_name
}

output "master_password_secret_arn" {
  description = "Secrets Manager ARN for master password"
  value       = aws_secretsmanager_secret.master_password.arn
}

output "security_group_id" {
  description = "Aurora security group ID"
  value       = aws_security_group.this.id
}
