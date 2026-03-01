output "debezium_connector_arn" {
  description = "Debezium source connector ARN"
  value       = aws_mskconnect_connector.debezium_source.arn
}

output "iceberg_sink_mnpi_connector_arn" {
  description = "Iceberg MNPI sink connector ARN"
  value       = aws_mskconnect_connector.iceberg_sink_mnpi.arn
}

output "iceberg_sink_nonmnpi_connector_arn" {
  description = "Iceberg non-MNPI sink connector ARN"
  value       = aws_mskconnect_connector.iceberg_sink_nonmnpi.arn
}
