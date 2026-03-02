/**
 * networking — VPC, Subnets, S3 Gateway Endpoint, NAT Gateway, Security Groups
 *
 * Creates the network foundation for the data lake platform:
 *   1. VPC with DNS support and hostnames enabled
 *   2. Two private subnets across two AZs (for MSK and EKS workloads)
 *   3. One public subnet for NAT Gateway placement (no workloads)
 *   4. Internet Gateway + NAT Gateway (private subnet outbound for Lambda,
 *      CloudWatch Logs, Secrets Manager, etc.)
 *   5. S3 VPC gateway endpoint (keeps Iceberg writes within AWS network)
 *   6. Security groups for MSK brokers, EKS worker nodes, and Lambda functions
 *
 * DESIGN DECISION:
 *   Workload subnets remain private. A single public subnet hosts the NAT
 *   Gateway so that VPC-attached Lambda functions (and future EKS pods) can
 *   reach AWS service endpoints that lack VPC interface endpoints. The S3
 *   gateway endpoint is still associated with the private route table so
 *   that Kafka Connect Iceberg sink writes flow directly to S3 without
 *   traversing the public internet.
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
# Public Subnet (for NAT Gateway only — no workloads)
# =============================================================================

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 100) # 10.0.100.0/24
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "datalake-public-${local.azs[0]}-${var.environment}"
    Tier = "public"
  })
}

# =============================================================================
# Internet Gateway
# =============================================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "datalake-igw-${var.environment}"
  })
}

# =============================================================================
# Public Route Table (IGW route for NAT Gateway outbound)
# =============================================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "datalake-public-rt-${var.environment}"
    Tier = "public"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# =============================================================================
# NAT Gateway (private subnet outbound via public subnet)
# =============================================================================

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "datalake-nat-eip-${var.environment}"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = merge(local.common_tags, {
    Name = "datalake-nat-${var.environment}"
  })

  depends_on = [aws_internet_gateway.main]
}

# Default route for private subnets via NAT Gateway
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
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
  service_name = "com.amazonaws.${data.aws_region.current.id}.s3"

  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, {
    Name = "datalake-s3-endpoint-${var.environment}"
  })
}

# --- VPC Interface Endpoints Security Group --------------------------------

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "datalake-vpce-${var.environment}-"
  description = "VPC Interface Endpoints - HTTPS from Lambda"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "datalake-vpce-sg-${var.environment}"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_lambda" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS (443) from Lambda functions"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id

  tags = merge(local.common_tags, {
    Name = "vpce-ingress-from-lambda"
  })
}

# --- STS VPC Interface Endpoint -------------------------------------------
# Required for Lambda to generate MSK IAM auth tokens (sts:AssumeRole)
# without depending on NAT Gateway. Cost: ~$7.30/month (2 ENIs).

resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.id}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "datalake-sts-endpoint-${var.environment}"
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
  description = "MSK broker security group - allows Kafka IAM auth from EKS nodes"
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
  description = "EKS worker node security group - outbound to MSK and S3"
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

# --- Lambda Security Group --------------------------------------------------

resource "aws_security_group" "lambda" {
  name_prefix = "datalake-lambda-${var.environment}-"
  description = "Lambda producer-api - egress to MSK and Aurora"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "datalake-lambda-sg-${var.environment}"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_msk" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "Kafka IAM auth (9098) to MSK brokers"
  from_port                    = 9098
  to_port                      = 9098
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.msk.id

  tags = merge(local.common_tags, { Name = "lambda-egress-to-msk" })
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_aurora" {
  security_group_id = aws_security_group.lambda.id
  description       = "PostgreSQL (5432) to Aurora"
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = merge(local.common_tags, { Name = "lambda-egress-to-aurora" })
}

resource "aws_vpc_security_group_egress_rule" "lambda_all_outbound" {
  security_group_id = aws_security_group.lambda.id
  description       = "All outbound (NAT Gateway for AWS endpoints)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = merge(local.common_tags, { Name = "lambda-egress-all" })
}

# --- MSK ingress from Lambda ------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "msk_from_lambda" {
  security_group_id            = aws_security_group.msk.id
  description                  = "Kafka IAM auth (9098) from Lambda producer"
  from_port                    = 9098
  to_port                      = 9098
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id

  tags = merge(local.common_tags, { Name = "msk-ingress-from-lambda" })
}
