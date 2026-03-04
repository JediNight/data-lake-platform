# Non-deterministic resources from foundation stack (AWS-assigned IDs)
data "terraform_remote_state" "foundation" {
  backend   = "s3"
  workspace = terraform.workspace

  config = {
    bucket = "mayadangelou-datalake-tfstate"
    key    = "foundation/terraform.tfstate"
    region = "us-east-1"
  }
}
