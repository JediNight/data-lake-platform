output "debezium_connector_arn" {
  description = "Debezium source connector ARN (null when disabled)"
  value       = var.enable_debezium_connector ? aws_mskconnect_connector.debezium_source[0].arn : null
}

output "iceberg_sink_connector_arns" {
  description = "Iceberg sink connector ARNs keyed by data zone (mnpi, nonmnpi)"
  value       = { for k, v in aws_mskconnect_connector.iceberg_sink : k => v.arn }
}
