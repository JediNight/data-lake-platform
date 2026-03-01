variable "environment" {
  type = string
}

variable "vpc_id" {
  description = "VPC ID for the DB security group"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "instance_class" {
  description = "Aurora instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "instance_count" {
  description = "Number of Aurora instances (1 writer + N-1 readers)"
  type        = number
  default     = 1
}

variable "database_name" {
  description = "Name of the default database"
  type        = string
  default     = "trading"
}

variable "master_username" {
  description = "Master username"
  type        = string
  default     = "postgres"
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "15.4"
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to connect (e.g., EKS nodes)"
  type        = list(string)
  default     = []
}
