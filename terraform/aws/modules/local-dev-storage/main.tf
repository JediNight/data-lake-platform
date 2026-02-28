/**
 * Local Dev Storage
 *
 * Creates an S3 bucket for local Kind cluster Iceberg sinks.
 * Data written by Kafka Connect Iceberg sink connector in the
 * local dev environment lands here over the network.
 *
 * Run standalone: terraform init && terraform apply
 */

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "data-lake-platform"
      Environment = "localdev"
      ManagedBy   = "terraform"
    }
  }
}

resource "aws_s3_bucket" "iceberg" {
  bucket        = var.bucket_name
  force_destroy = true # Dev bucket — safe to destroy with data
}

resource "aws_s3_bucket_versioning" "iceberg" {
  bucket = aws_s3_bucket.iceberg.id
  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "iceberg" {
  bucket = aws_s3_bucket.iceberg.id

  rule {
    id     = "expire-old-data"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}
