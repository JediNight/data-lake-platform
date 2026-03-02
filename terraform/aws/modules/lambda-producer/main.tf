/**
 * lambda-producer — Lambda Trading Simulator
 *
 * Deploys the trading simulator as a Lambda function triggered by EventBridge
 * on a 1-minute schedule. The Lambda:
 *   - Runs in VPC private subnets for MSK Kafka access (IAM auth, port 9098)
 *   - Writes to Aurora via RDS Data API (HTTPS, no VPC peering needed)
 *   - Uses AWS Lambda Powertools managed layer for structured logging/tracing
 *
 * IAM grants: MSK produce, RDS Data API, Secrets Manager read, VPC access.
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

# =============================================================================
# Locals
# =============================================================================

locals {
  common_tags = merge(var.tags, {
    Module      = "lambda-producer"
    Environment = var.environment
  })
  function_name = "datalake-trading-simulator-${var.environment}"
}

# =============================================================================
# IAM Role
# =============================================================================
# Lambda execution role with VPC access, MSK produce, RDS Data API,
# and Secrets Manager read permissions.
# =============================================================================

resource "aws_iam_role" "lambda" {
  name = "datalake-trading-simulator-${var.environment}"
  path = "/datalake/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowLambdaAssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name    = "datalake-trading-simulator-${var.environment}"
    Persona = "lambda-producer"
  })
}

# VPC access — allows Lambda to create ENIs in private subnets
resource "aws_iam_role_policy_attachment" "vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# MSK IAM auth — cluster-level connect + topic-level produce
resource "aws_iam_role_policy" "msk" {
  name = "msk-iam-auth"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MSKClusterAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
        ]
        Resource = var.msk_cluster_arn
      },
      {
        Sid    = "MSKTopicProduce"
        Effect = "Allow"
        Action = [
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
        ]
        Resource = "${var.msk_cluster_arn}/*"
      },
    ]
  })
}

# RDS Data API — execute SQL statements against Aurora Serverless
resource "aws_iam_role_policy" "rds_data_api" {
  name = "rds-data-api"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "RDSDataAPIAccess"
      Effect = "Allow"
      Action = [
        "rds-data:ExecuteStatement",
        "rds-data:BatchExecuteStatement",
      ]
      Resource = var.aurora_cluster_arn
    }]
  })
}

# Secrets Manager — read Aurora credentials for RDS Data API auth
resource "aws_iam_role_policy" "secrets" {
  name = "secretsmanager-aurora-read"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "SecretsManagerAuroraRead"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.aurora_secret_arn
    }]
  })
}

# =============================================================================
# Lambda Layer (pip dependencies)
# =============================================================================

resource "aws_lambda_layer_version" "deps" {
  layer_name          = "datalake-trading-simulator-deps-${var.environment}"
  filename            = var.layer_zip_path
  source_code_hash    = filebase64sha256(var.layer_zip_path)
  compatible_runtimes = ["python3.11"]

  description = "pip dependencies for trading simulator Lambda"
}

# =============================================================================
# Lambda Function
# =============================================================================

resource "aws_lambda_function" "simulator" {
  function_name    = local.function_name
  role             = aws_iam_role.lambda.arn
  handler          = "main.handler"
  runtime          = "python3.11"
  timeout          = 300
  memory_size      = 512
  filename         = var.function_zip_path
  source_code_hash = filebase64sha256(var.function_zip_path)

  layers = [
    aws_lambda_layer_version.deps.arn,
    "arn:aws:lambda:${data.aws_region.current.name}:017000801446:layer:AWSLambdaPowertoolsPythonV3-python311-x86_64:7",
  ]

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  environment {
    variables = {
      AURORA_CLUSTER_ARN      = var.aurora_cluster_arn
      AURORA_SECRET_ARN       = var.aurora_secret_arn
      AURORA_DATABASE         = "trading"
      KAFKA_BOOTSTRAP_SERVERS = var.msk_bootstrap_brokers
      ENVIRONMENT             = var.environment
      POWERTOOLS_SERVICE_NAME = "trading-simulator"
      LOG_LEVEL               = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = merge(local.common_tags, {
    Name = local.function_name
  })
}

# =============================================================================
# EventBridge Schedule (1-minute trigger)
# =============================================================================

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "datalake-trading-simulator-${var.environment}"
  description         = "Triggers trading simulator Lambda every 1 minute"
  schedule_expression = "rate(1 minute)"
  state               = var.schedule_enabled ? "ENABLED" : "DISABLED"

  tags = merge(local.common_tags, {
    Name = "datalake-trading-simulator-${var.environment}"
  })
}

resource "aws_cloudwatch_event_target" "simulator" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.simulator.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.simulator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
