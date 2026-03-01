/**
 * Aurora PostgreSQL Module
 *
 * Aurora PostgreSQL cluster for the data lake platform prod environment.
 * Stores the trading database (orders, trades, positions, accounts, instruments).
 * Debezium reads CDC events via logical replication.
 */

# -----------------------------------------------------------------------------
# DB Subnet Group
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "datalake-aurora-${var.environment}"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "datalake-aurora-${var.environment}"
  }
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name_prefix = "datalake-aurora-${var.environment}-"
  vpc_id      = var.vpc_id
  description = "Aurora PostgreSQL security group"

  # Allow ingress from EKS nodes on port 5432
  dynamic "ingress" {
    for_each = var.allowed_security_group_ids
    content {
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------------------
# Master Password (stored in Secrets Manager)
# -----------------------------------------------------------------------------

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "master_password" {
  name                    = "datalake/aurora/${var.environment}/master-password"
  recovery_window_in_days = var.environment == "prod" ? 7 : 0
}

resource "aws_secretsmanager_secret_version" "master_password" {
  secret_id     = aws_secretsmanager_secret.master_password.id
  secret_string = random_password.master.result
}

# -----------------------------------------------------------------------------
# Aurora Cluster
# -----------------------------------------------------------------------------

resource "aws_rds_cluster" "this" {
  cluster_identifier = "datalake-${var.environment}"
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version

  database_name   = var.database_name
  master_username = var.master_username
  master_password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]

  # Enable logical replication for Debezium CDC
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  storage_encrypted   = true
  skip_final_snapshot = true
  deletion_protection = var.environment == "prod" ? true : false

  tags = {
    Name = "datalake-${var.environment}"
  }
}

# -----------------------------------------------------------------------------
# Parameter Group (enable logical replication for Debezium)
# -----------------------------------------------------------------------------

resource "aws_rds_cluster_parameter_group" "this" {
  name   = "datalake-aurora-${var.environment}"
  family = "aurora-postgresql15"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

}

# -----------------------------------------------------------------------------
# Aurora Instances
# -----------------------------------------------------------------------------

resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier         = "datalake-${var.environment}-${count.index}"
  cluster_identifier = aws_rds_cluster.this.id
  instance_class     = var.instance_class
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version
}
