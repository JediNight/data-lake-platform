terraform {
  backend "s3" {
    bucket       = "mayadangelou-datalake-tfstate"
    key          = "compute/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
