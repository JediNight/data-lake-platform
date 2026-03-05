terraform {
  backend "s3" {
    bucket       = "mayadangelou-datalake-tfstate"
    key          = "account-baseline/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
