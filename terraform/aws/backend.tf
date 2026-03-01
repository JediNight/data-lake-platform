terraform {
  backend "s3" {
    bucket         = "mayadangelou-datalake-tfstate"
    key            = "aws/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "datalake-tfstate-lock"
  }
}
