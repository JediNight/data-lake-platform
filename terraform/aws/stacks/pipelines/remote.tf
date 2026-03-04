data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Non-deterministic resources from foundation stack
data "terraform_remote_state" "foundation" {
  backend   = "s3"
  workspace = terraform.workspace

  config = {
    bucket = "mayadangelou-datalake-tfstate"
    key    = "foundation/terraform.tfstate"
    region = "us-east-1"
  }
}

# Non-deterministic resources from compute stack
data "terraform_remote_state" "compute" {
  backend   = "s3"
  workspace = terraform.workspace

  config = {
    bucket = "mayadangelou-datalake-tfstate"
    key    = "compute/terraform.tfstate"
    region = "us-east-1"
  }
}
