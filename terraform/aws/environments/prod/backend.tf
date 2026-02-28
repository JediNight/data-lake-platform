terraform {
  backend "s3" {
    bucket         = "datalake-tfstate-prod"
    key            = "data-lake-platform/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "datalake-tfstate-lock"
    encrypt        = true
  }
}
