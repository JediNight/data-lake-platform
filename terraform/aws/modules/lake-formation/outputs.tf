/**
 * lake-formation -- Outputs
 *
 * Exposes LF-Tag keys and registered S3 locations for downstream
 * modules and root-module wiring.
 */

# =============================================================================
# LF-Tag Keys
# =============================================================================

output "lf_tag_sensitivity_key" {
  description = "Key name of the sensitivity LF-Tag"
  value       = aws_lakeformation_lf_tag.sensitivity.key
}

output "lf_tag_layer_key" {
  description = "Key name of the layer LF-Tag"
  value       = aws_lakeformation_lf_tag.layer.key
}

# =============================================================================
# Registered S3 Locations
# =============================================================================

output "registered_locations" {
  description = "List of S3 bucket ARNs registered with Lake Formation"
  value = [
    aws_lakeformation_resource.mnpi_bucket.arn,
    aws_lakeformation_resource.nonmnpi_bucket.arn,
  ]
}
