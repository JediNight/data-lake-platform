locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Wildcard bucket patterns — permission sets must work across all environments
  mnpi_bucket_arn_pattern          = "arn:aws:s3:::datalake-mnpi-*"
  nonmnpi_bucket_arn_pattern       = "arn:aws:s3:::datalake-nonmnpi-*"
  query_results_bucket_arn_pattern = "arn:aws:s3:::datalake-query-results-*"
}
