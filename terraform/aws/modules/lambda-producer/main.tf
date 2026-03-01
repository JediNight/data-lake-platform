/**
 * lambda-producer — FastAPI trading simulator on Lambda + API Gateway
 *
 * Wraps the producer-api FastAPI app with Mangum for Lambda compatibility.
 * Deployed in VPC private subnets for MSK + Aurora access.
 */

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# --- Lambda IAM Role --------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "datalake-lambda-producer-${var.environment}"
  path               = "/datalake/"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = merge(var.tags, {
    Name    = "datalake-lambda-producer-${var.environment}"
    Persona = "lambda-producer"
  })
}

# VPC access (ENI creation for VPC-attached Lambda)
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# MSK IAM auth (kafka:* for producing messages via IAM)
data "aws_iam_policy_document" "lambda_msk" {
  statement {
    sid    = "MSKConnect"
    effect = "Allow"
    actions = [
      "kafka-cluster:Connect",
      "kafka-cluster:DescribeCluster",
    ]
    resources = [var.msk_cluster_arn]
  }

  statement {
    sid    = "MSKProduce"
    effect = "Allow"
    actions = [
      "kafka-cluster:WriteData",
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:CreateTopic",
    ]
    resources = ["${var.msk_cluster_arn}/*"]
  }
}

resource "aws_iam_role_policy" "lambda_msk" {
  name   = "msk-produce"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_msk.json
}

# Secrets Manager (Aurora master password)
data "aws_iam_policy_document" "lambda_secrets" {
  statement {
    sid       = "SecretsRead"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.aurora_secret_arn]
  }
}

resource "aws_iam_role_policy" "lambda_secrets" {
  name   = "secrets-read"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_secrets.json
}

# --- Lambda Function ---------------------------------------------------------

resource "aws_lambda_function" "producer" {
  function_name = "datalake-producer-api-${var.environment}"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 30
  memory_size   = 256

  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  environment {
    variables = {
      KAFKA_BOOTSTRAP_SERVERS = var.msk_bootstrap_brokers
      POSTGRES_DSN            = var.postgres_dsn
      SIMULATION_ENABLED      = "false"
    }
  }

  tags = merge(var.tags, {
    Name        = "datalake-producer-api-${var.environment}"
    Environment = var.environment
  })
}

# --- API Gateway (HTTP API) -------------------------------------------------

resource "aws_apigatewayv2_api" "producer" {
  name          = "datalake-producer-${var.environment}"
  protocol_type = "HTTP"

  tags = merge(var.tags, {
    Name = "datalake-producer-api-${var.environment}"
  })
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.producer.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.producer.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.producer.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.producer.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.producer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.producer.execution_arn}/*/*"
}
