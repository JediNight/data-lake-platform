output "bucket_id" {
  description = "Local dev Iceberg S3 bucket name"
  value       = aws_s3_bucket.iceberg.id
}

output "bucket_arn" {
  description = "Local dev Iceberg S3 bucket ARN"
  value       = aws_s3_bucket.iceberg.arn
}
