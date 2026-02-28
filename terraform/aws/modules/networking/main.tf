/**
 * networking — VPC, Subnets, S3 Gateway Endpoint, Security Groups
 *
 * Creates the network foundation for the data lake platform:
 *   1. VPC with DNS support and hostnames enabled
 *   2. Two private subnets across two AZs (for MSK and EKS workloads)
 *   3. S3 VPC gateway endpoint (keeps Iceberg writes within AWS network)
 *   4. Security groups for MSK brokers and EKS worker nodes
 *
 * DESIGN DECISION:
 *   Subnets are purely private with no internet gateway. The S3 gateway
 *   endpoint is associated with the private route table so that Kafka
 *   Connect Iceberg sink writes flow directly to S3 without traversing
 *   the public internet. This is both a cost optimization and a security
 *   hardening measure.
 */

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnet_cidrs = [
    cidrsubnet(var.vpc_cidr, 8, 1), # 10.0.1.0/24 (with default VPC CIDR)
    cidrsubnet(var.vpc_cidr, 8, 2), # 10.0.2.0/24 (with default VPC CIDR)
  ]

  common_tags = merge(var.tags, {
    Module      = "networking"
    Environment = var.environment
  })
}

# =============================================================================
# VPC
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "datalake-vpc-${var.environment}"
  })
}

# =============================================================================
# Private Subnets
# =============================================================================

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Private subnets — no public IPs
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "datalake-private-${local.azs[count.index]}-${var.environment}"
    Tier = "private"
  })
}

# =============================================================================
# Route Table — Private (no internet gateway)
# =============================================================================

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "datalake-private-rt-${var.environment}"
    Tier = "private"
  })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# =============================================================================
# S3 Gateway Endpoint
# =============================================================================
#
# CRITICAL: This gateway endpoint ensures that all S3 traffic (especially
# Iceberg writes from Kafka Connect) stays within the AWS network. Gateway
# endpoints are free and add a route to the specified route tables.
# =============================================================================

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"

  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, {
    Name = "datalake-s3-endpoint-${var.environment}"
  })
}

# =============================================================================
# Security Groups
# =============================================================================

# --- MSK Broker Security Group -----------------------------------------------
#
# Allows inbound Kafka traffic (port 9098, IAM auth) from EKS worker nodes.
# Port 9098 is the MSK IAM authentication listener.

resource "aws_security_group" "msk" {
  name_prefix = "datalake-msk-${var.environment}-"
  description = "MSK broker security group — allows Kafka IAM auth from EKS nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "datalake-msk-sg-${var.environment}"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_eks" {
  security_group_id = aws_security_group.msk.id
  description       = "Kafka IAM auth (9098) from EKS worker nodes"

  from_port                    = 9098
  to_port                      = 9098
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.eks_node.id

  tags = merge(local.common_tags, {
    Name = "msk-ingress-from-eks"
  })
}

resource "aws_vpc_security_group_ingress_rule" "msk_inter_broker" {
  security_group_id = aws_security_group.msk.id
  description       = "Inter-broker replication (self-referencing)"

  from_port                    = 9098
  to_port                      = 9098
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.msk.id

  tags = merge(local.common_tags, {
    Name = "msk-ingress-inter-broker"
  })
}

resource "aws_vpc_security_group_egress_rule" "msk_all_outbound" {
  security_group_id = aws_security_group.msk.id
  description       = "Allow all outbound traffic"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  tags = merge(local.common_tags, {
    Name = "msk-egress-all"
  })
}

# --- EKS Node Security Group -------------------------------------------------
#
# Allows outbound to MSK brokers and S3 (via gateway endpoint, which uses
# prefix lists). This is the security group attached to EKS worker nodes
# running Kafka Connect and other data lake workloads.

resource "aws_security_group" "eks_node" {
  name_prefix = "datalake-eks-node-${var.environment}-"
  description = "EKS worker node security group — outbound to MSK and S3"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "datalake-eks-node-sg-${var.environment}"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "eks_to_msk" {
  security_group_id = aws_security_group.eks_node.id
  description       = "Kafka IAM auth (9098) to MSK brokers"

  from_port                    = 9098
  to_port                      = 9098
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.msk.id

  tags = merge(local.common_tags, {
    Name = "eks-egress-to-msk"
  })
}

resource "aws_vpc_security_group_egress_rule" "eks_to_s3" {
  security_group_id = aws_security_group.eks_node.id
  description       = "HTTPS to S3 via gateway endpoint (prefix list)"

  from_port      = 443
  to_port        = 443
  ip_protocol    = "tcp"
  prefix_list_id = aws_vpc_endpoint.s3.prefix_list_id

  tags = merge(local.common_tags, {
    Name = "eks-egress-to-s3"
  })
}

resource "aws_vpc_security_group_egress_rule" "eks_self" {
  security_group_id = aws_security_group.eks_node.id
  description       = "Node-to-node communication (self-referencing)"

  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.eks_node.id

  tags = merge(local.common_tags, {
    Name = "eks-egress-self"
  })
}

resource "aws_vpc_security_group_ingress_rule" "eks_self" {
  security_group_id = aws_security_group.eks_node.id
  description       = "Node-to-node communication (self-referencing)"

  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.eks_node.id

  tags = merge(local.common_tags, {
    Name = "eks-ingress-self"
  })
}
