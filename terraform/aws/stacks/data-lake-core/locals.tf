locals {
  env = terraform.workspace

  config = {
    dev = {
      raw_ia_transition_days = 0
    }
    prod = {
      raw_ia_transition_days = 90
    }
  }

  c = local.config[local.env]
}
