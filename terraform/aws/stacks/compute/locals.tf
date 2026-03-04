locals {
  env = terraform.workspace

  config = {
    dev = {
      enable_msk                 = false
      broker_instance_type       = "kafka.t3.small"
      broker_count               = 1
      default_replication_factor = 1
      enable_aurora              = false
      aurora_instance_class      = "db.t4g.medium"
      aurora_instance_count      = 1
      enable_msk_connect         = false
    }
    prod = {
      enable_msk                 = true
      broker_instance_type       = "kafka.m5.large"
      broker_count               = 2
      default_replication_factor = 2
      enable_aurora              = true
      aurora_instance_class      = "db.r6g.large"
      aurora_instance_count      = 2
      enable_msk_connect         = true
    }
  }

  c = local.config[local.env]
}
