# Production Deployment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy the full production data lake stack (MSK, Aurora, MSK Connect, Glue ETL, Lambda producer, Lake Formation ABAC) as a single Terraform apply in us-east-1.

**Architecture:** Fully serverless/managed — MSK Connect runs Debezium + Iceberg sinks (no EKS), producer-api deploys as Lambda + API Gateway, Glue ETL runs on a scheduled medallion workflow. Lake Formation ABAC with Identity Center trusted identity propagation provides 3-persona access control.

**Data Flow (two paths):**
- **Orders/trades/positions (MNPI):** Lambda → Aurora PostgreSQL (INSERT) → Debezium CDC (WAL via pgoutput) → MSK Kafka (`cdc.trading.*`) → Iceberg Sink → S3 raw layer
- **Market data ticks (non-MNPI):** Lambda → MSK Kafka directly (`stream.market-data`) → Iceberg Sink → S3 raw layer
- **Important:** Orders do NOT dual-write to Kafka. CDC is the single path. The `stream.order-events` topic is removed — replaced by `cdc.trading.orders`.

**Tech Stack:** Terraform 1.7+, AWS (MSK, MSK Connect, Aurora PostgreSQL, Glue 4.0, Lambda, API Gateway, Lake Formation, Athena, CloudTrail, Identity Center), PySpark (Iceberg), Python 3.11 (FastAPI + Mangum)

---

## Phase 1: Cleanup & Security Fixes

### Task 1: Remove EKS Module

**Files:**
- Delete: `terraform/aws/modules/eks/` (entire directory)
- Modify: `terraform/aws/main.tf:192-206` (remove EKS module block)
- Modify: `terraform/aws/main.tf:222-224` (remove EKS SG reference from Aurora)
- Modify: `terraform/aws/main.tf:126-127` (remove EKS OIDC references from service_roles)
- Modify: `terraform/aws/locals.tf:29-31,69-71` (remove enable_eks, eks_node_instance_type, eks_node_count)

**Step 1: Remove EKS module block from root main.tf**

Remove the entire `module "eks"` block (lines 192-206) and the EKS-related wiring:
- In `module "aurora_postgres"`: change `allowed_security_group_ids` to `[]` for now (will add Lambda SG later)
- In `module "service_roles"`: set `eks_oidc_provider_arn = ""` and `eks_oidc_provider_url = ""` unconditionally

**Step 2: Remove EKS config from locals.tf**

Remove these keys from both dev and prod config maps:
- `enable_eks`
- `eks_node_instance_type`
- `eks_node_count`

**Step 3: Delete the EKS module directory**

```bash
rm -rf terraform/aws/modules/eks/
```

**Step 4: Validate**

```bash
cd terraform/aws && terraform validate
```
Expected: Success (no EKS references remain)

**Step 5: Commit**

```bash
git add -A terraform/aws/
git commit -m "refactor: remove EKS module — replaced by Lambda + MSK Connect"
```

---

### Task 2: Fix Aurora Secrets Recovery Window

**Files:**
- Modify: `terraform/aws/modules/aurora-postgres/main.tf:61`

**Step 1: Change recovery_window_in_days**

```hcl
# Before
recovery_window_in_days = 0 # Allow immediate deletion for dev

# After
recovery_window_in_days = var.environment == "prod" ? 7 : 0
```

**Step 2: Commit**

```bash
git add terraform/aws/modules/aurora-postgres/main.tf
git commit -m "fix(aurora): set 7-day secrets recovery window in prod"
```

---

### Task 3: Update prod.tfvars with Real Admin Role ARN

**Files:**
- Modify: `terraform/aws/prod.tfvars`

**Step 1: Update admin_role_arn**

```hcl
# Prod environment overrides
# Usage: terraform plan -var-file=prod.tfvars
admin_role_arn = "arn:aws:iam::445985103066:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_acf5dc9d63ba965c"
```

**Step 2: Commit**

```bash
git add terraform/aws/prod.tfvars
git commit -m "fix(prod): set real admin role ARN in prod.tfvars"
```

---

## Phase 2: Networking — NAT Gateway for Lambda VPC Access

### Task 4: Add Public Subnet, IGW, NAT Gateway

Lambda functions attached to the VPC (needed for MSK + Aurora access) require a NAT
Gateway for outbound internet (CloudWatch Logs, Secrets Manager endpoints). The NAT
Gateway lives in a public subnet with an Internet Gateway.

**Files:**
- Modify: `terraform/aws/modules/networking/main.tf`
- Modify: `terraform/aws/modules/networking/outputs.tf`

**Step 1: Add public subnet, IGW, NAT Gateway, and route tables**

Add to `modules/networking/main.tf` after the private route table section:

```hcl
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
```

**Step 2: Add Lambda security group**

Add to `modules/networking/main.tf` after the EKS security group section:

```hcl
# --- Lambda Security Group --------------------------------------------------

resource "aws_security_group" "lambda" {
  name_prefix = "datalake-lambda-${var.environment}-"
  description = "Lambda producer-api — egress to MSK and Aurora"
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

resource "aws_vpc_security_group_egress_rule" "lambda_to_s3" {
  security_group_id = aws_security_group.lambda.id
  description       = "HTTPS to S3 via gateway endpoint"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id

  tags = merge(local.common_tags, { Name = "lambda-egress-to-s3" })
}

resource "aws_vpc_security_group_egress_rule" "lambda_all_outbound" {
  security_group_id = aws_security_group.lambda.id
  description       = "All outbound (NAT Gateway for AWS endpoints)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = merge(local.common_tags, { Name = "lambda-egress-all" })
}
```

**Step 3: Add MSK ingress from Lambda**

```hcl
resource "aws_vpc_security_group_ingress_rule" "msk_from_lambda" {
  security_group_id            = aws_security_group.msk.id
  description                  = "Kafka IAM auth (9098) from Lambda producer"
  from_port                    = 9098
  to_port                      = 9098
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id

  tags = merge(local.common_tags, { Name = "msk-ingress-from-lambda" })
}
```

**Step 4: Add outputs**

Add to `modules/networking/outputs.tf`:

```hcl
output "lambda_security_group_id" {
  description = "Security group ID for Lambda producer-api"
  value       = aws_security_group.lambda.id
}

output "public_subnet_id" {
  description = "Public subnet ID (NAT Gateway placement)"
  value       = aws_subnet.public.id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID"
  value       = aws_nat_gateway.main.id
}
```

**Step 5: Validate**

```bash
cd terraform/aws && terraform validate
```

**Step 6: Commit**

```bash
git add terraform/aws/modules/networking/
git commit -m "feat(networking): add NAT Gateway, public subnet, Lambda SG"
```

---

## Phase 3: Lambda Producer Module

### Task 5: Create lambda-producer Terraform Module

**Files:**
- Create: `terraform/aws/modules/lambda-producer/main.tf`
- Create: `terraform/aws/modules/lambda-producer/variables.tf`
- Create: `terraform/aws/modules/lambda-producer/outputs.tf`

**Step 1: Create module directory and main.tf**

```hcl
# terraform/aws/modules/lambda-producer/main.tf

/**
 * lambda-producer — FastAPI trading simulator on Lambda + API Gateway
 *
 * Wraps the producer-api FastAPI app with Mangum for Lambda compatibility.
 * Deployed in VPC private subnets for MSK + Aurora access.
 */

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
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
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

  tags = {
    Name        = "datalake-producer-api-${var.environment}"
    Environment = var.environment
  }
}

# --- API Gateway (HTTP API — simpler than REST API) --------------------------

resource "aws_apigatewayv2_api" "producer" {
  name          = "datalake-producer-${var.environment}"
  protocol_type = "HTTP"
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
```

**Step 2: Create variables.tf**

```hcl
# terraform/aws/modules/lambda-producer/variables.tf

variable "environment" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for Lambda VPC attachment"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security group ID for Lambda"
  type        = string
}

variable "msk_cluster_arn" {
  description = "MSK cluster ARN (for IAM policy)"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK IAM bootstrap broker string"
  type        = string
}

variable "postgres_dsn" {
  description = "Aurora PostgreSQL connection string"
  type        = string
}

variable "aurora_secret_arn" {
  description = "Secrets Manager ARN for Aurora master password"
  type        = string
}

variable "lambda_zip_path" {
  description = "Path to the Lambda deployment ZIP"
  type        = string
}
```

**Step 3: Create outputs.tf**

```hcl
# terraform/aws/modules/lambda-producer/outputs.tf

output "api_endpoint" {
  description = "API Gateway endpoint URL"
  value       = aws_apigatewayv2_api.producer.api_endpoint
}

output "function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.producer.function_name
}

output "function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.producer.arn
}
```

**Step 4: Validate**

```bash
cd terraform/aws && terraform validate
```

**Step 5: Commit**

```bash
git add terraform/aws/modules/lambda-producer/
git commit -m "feat: add lambda-producer module (FastAPI + API Gateway)"
```

---

### Task 6: Add Mangum Handler + Package Lambda ZIP

**Files:**
- Create: `producer-api/handler.py` (Mangum wrapper — 3 lines)
- Modify: `producer-api/app/requirements.txt` (add mangum)
- Create: `scripts/package-lambda.sh` (build ZIP for deployment)

**Step 1: Create Mangum handler**

```python
# producer-api/handler.py
from mangum import Mangum
from app.main import app

handler = Mangum(app, lifespan="off")
```

Note: `lifespan="off"` because Lambda doesn't support persistent background tasks
(the simulator). The Lambda only handles HTTP requests — simulation is disabled
via the `SIMULATION_ENABLED=false` env var.

**Data flow correction:** The producer-api must be refactored so that:
- `/api/v1/orders` writes ONLY to Aurora (no Kafka). Debezium CDC captures the change.
- `/api/v1/market-data` writes ONLY to Kafka (no DB — external market feed).
- Remove the `stream.order-events` topic from the producer. CDC topics replace it.
- Update `KafkaEventProducer` to only expose `send_market_data()`.
- Update the Iceberg Sink MNPI connector topics: replace `stream.order-events` with
  CDC topics only (`cdc.trading.orders,cdc.trading.trades,cdc.trading.positions`).

**Step 2: Add mangum to requirements.txt**

Add `mangum==0.19.0` to `producer-api/app/requirements.txt`.

**Step 3: Create packaging script**

```bash
#!/usr/bin/env bash
# scripts/package-lambda.sh — Build Lambda deployment ZIP
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PRODUCER_DIR="$PROJECT_DIR/producer-api"
BUILD_DIR="$PROJECT_DIR/.build/lambda-producer"
ZIP_PATH="$PROJECT_DIR/.build/lambda-producer.zip"

echo "==> Cleaning build directory"
rm -rf "$BUILD_DIR" "$ZIP_PATH"
mkdir -p "$BUILD_DIR"

echo "==> Installing dependencies"
pip install -q -r "$PRODUCER_DIR/app/requirements.txt" -t "$BUILD_DIR"

echo "==> Copying application code"
cp -r "$PRODUCER_DIR/app" "$BUILD_DIR/app"
cp "$PRODUCER_DIR/handler.py" "$BUILD_DIR/handler.py"

echo "==> Creating ZIP"
cd "$BUILD_DIR"
zip -q -r "$ZIP_PATH" . -x "*/__pycache__/*" "*.pyc"

echo "==> Lambda package: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
```

**Step 4: Build the package**

```bash
chmod +x scripts/package-lambda.sh
./scripts/package-lambda.sh
```
Expected: `.build/lambda-producer.zip` created (~15-20 MB)

**Step 5: Commit**

```bash
git add producer-api/handler.py producer-api/app/requirements.txt scripts/package-lambda.sh
git commit -m "feat: add Lambda handler (Mangum) and packaging script"
```

---

### Task 7: Wire Lambda Module into Root main.tf

**Files:**
- Modify: `terraform/aws/main.tf` (add lambda_producer module block)
- Modify: `terraform/aws/locals.tf` (add enable_lambda_producer to config)
- Modify: `terraform/aws/modules/aurora-postgres/outputs.tf` (add secret_arn output)

**Step 1: Add Aurora secret ARN output**

Add to `modules/aurora-postgres/outputs.tf`:

```hcl
output "secret_arn" {
  description = "Secrets Manager ARN for Aurora master password"
  value       = aws_secretsmanager_secret.master_password.arn
}
```

**Step 2: Add enable_lambda_producer to locals.tf**

Add to both dev and prod config maps:
- dev: `enable_lambda_producer = false`
- prod: `enable_lambda_producer = true`

**Step 3: Add module block to main.tf**

Replace the removed EKS module block with:

```hcl
# =============================================================================
# Lambda Producer API (prod only — FastAPI on Lambda + API Gateway)
# =============================================================================

module "lambda_producer" {
  source = "./modules/lambda-producer"
  count  = local.c.enable_lambda_producer ? 1 : 0

  environment              = local.env
  subnet_ids               = module.networking.private_subnet_ids
  lambda_security_group_id = module.networking.lambda_security_group_id
  msk_cluster_arn          = module.streaming[0].cluster_arn
  msk_bootstrap_brokers    = module.streaming[0].bootstrap_brokers_iam
  aurora_secret_arn        = module.aurora_postgres[0].secret_arn

  postgres_dsn = format("postgresql://%s:%s@%s:%s/trading",
    "postgres",
    "PLACEHOLDER",  # Retrieved at runtime from Secrets Manager
    module.aurora_postgres[0].cluster_endpoint,
    module.aurora_postgres[0].cluster_port,
  )

  lambda_zip_path = "${path.module}/../../.build/lambda-producer.zip"
}
```

**Step 4: Update Aurora module — allow Lambda SG ingress**

In root `main.tf`, update `module "aurora_postgres"`:

```hcl
allowed_security_group_ids = local.c.enable_lambda_producer ? [
  module.networking.lambda_security_group_id,
] : []
```

**Step 5: Validate**

```bash
cd terraform/aws && terraform validate
```

**Step 6: Commit**

```bash
git add terraform/aws/
git commit -m "feat: wire lambda-producer module into root (prod only)"
```

---

## Phase 4: Glue ETL — Scheduling + Data Quality

### Task 8: Add Scheduled Trigger

**Files:**
- Modify: `terraform/aws/modules/glue-etl/main.tf:132-146`
- Modify: `terraform/aws/modules/glue-etl/variables.tf`

**Step 1: Add schedule variable**

Add to `modules/glue-etl/variables.tf`:

```hcl
variable "schedule_expression" {
  description = "Cron expression for the start trigger (empty string = ON_DEMAND)"
  type        = string
  default     = ""
}
```

**Step 2: Change start trigger to SCHEDULED when expression provided**

Replace the `aws_glue_trigger.start_curated` resource:

```hcl
resource "aws_glue_trigger" "start_curated" {
  name          = "datalake-start-curated-${var.environment}"
  type          = var.schedule_expression != "" ? "SCHEDULED" : "ON_DEMAND"
  workflow_name = aws_glue_workflow.medallion.name
  schedule      = var.schedule_expression != "" ? var.schedule_expression : null
  start_on_creation = var.schedule_expression != "" ? true : null

  actions {
    job_name = aws_glue_job.this["curated_order_events"].name
  }

  actions {
    job_name = aws_glue_job.this["curated_market_ticks"].name
  }

  tags = local.common_tags
}
```

**Step 3: Wire schedule from locals.tf**

Add to locals.tf config maps:
- dev: `glue_schedule = ""` (keep ON_DEMAND for dev)
- prod: `glue_schedule = "cron(0 */6 * * ? *)"` (every 6 hours)

Pass to module in root main.tf:
```hcl
schedule_expression = local.c.glue_schedule
```

**Step 4: Validate**

```bash
cd terraform/aws && terraform validate
```

**Step 5: Commit**

```bash
git add terraform/aws/
git commit -m "feat(glue): add scheduled trigger for prod (every 6 hours)"
```

---

### Task 9: Add Lightweight Data Quality Checks to PySpark Scripts

**Files:**
- Modify: `scripts/glue/curated_order_events.py`
- Modify: `scripts/glue/curated_market_ticks.py`
- Modify: `scripts/glue/analytics_order_summary.py`
- Modify: `scripts/glue/analytics_market_summary.py`

**Step 1: Add DQ helper function**

Add this to each script after the imports:

```python
def assert_quality(df, table_name, checks):
    """Lightweight data quality gate — fails the job if any check fails."""
    for check_name, condition in checks.items():
        if not condition:
            raise ValueError(f"DQ FAILED [{table_name}]: {check_name}")
    print(f"DQ PASSED [{table_name}]: {list(checks.keys())}")
```

**Step 2: Add checks before each write**

For curated_order_events.py (before `writeTo`):

```python
row_count = df_curated.count()
null_event_ids = df_curated.filter(F.col("event_id").isNull()).count()

assert_quality(df_curated, target_table, {
    "row_count > 0": row_count > 0,
    "no null event_ids": null_event_ids == 0,
    f"row_count={row_count}": True,  # Log the count (always passes)
})
```

For curated_market_ticks.py (before `writeTo`):

```python
row_count = df_curated.count()
null_tickers = df_curated.filter(F.col("ticker").isNull()).count()

assert_quality(df_curated, target_table, {
    "row_count > 0": row_count > 0,
    "no null tickers": null_tickers == 0,
    f"row_count={row_count}": True,
})
```

For analytics_order_summary.py (before `writeTo`):

```python
row_count = df_summary.count()

assert_quality(df_summary, target_table, {
    "row_count > 0": row_count > 0,
    f"row_count={row_count}": True,
})
```

For analytics_market_summary.py (before `writeTo`):

```python
row_count = df_summary.count()

assert_quality(df_summary, target_table, {
    "row_count > 0": row_count > 0,
    f"row_count={row_count}": True,
})
```

**Step 3: Commit**

```bash
git add scripts/glue/
git commit -m "feat(glue): add lightweight data quality checks to all 4 jobs"
```

---

## Phase 5: MSK Connect — Production Wiring

### Task 10: Fix MSK Connect Plugin Upload (Replace Placeholders)

The current `msk-connect` module uses `source = "/dev/null"` placeholders for the
connector JARs. For production, we need to download the real JARs and upload them.

**Files:**
- Create: `scripts/upload-connector-plugins.sh`
- Modify: `terraform/aws/modules/msk-connect/main.tf` (adjust plugin config)
- Modify: `terraform/aws/modules/msk-connect/variables.tf`

**Step 1: Create plugin upload script**

```bash
#!/usr/bin/env bash
# scripts/upload-connector-plugins.sh
# Downloads Debezium + Iceberg connector JARs and uploads to S3.
set -euo pipefail

ENV="${1:?Usage: $0 <environment>}"
BUCKET="datalake-msk-connect-plugins-${ENV}"
DEBEZIUM_VERSION="2.5.0.Final"
ICEBERG_VERSION="1.8.1"
TMP_DIR=$(mktemp -d)

echo "==> Downloading Debezium PostgreSQL connector ${DEBEZIUM_VERSION}"
curl -sL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz" \
  -o "${TMP_DIR}/debezium-plugin.tar.gz"

echo "==> Downloading Iceberg Kafka Connect runtime ${ICEBERG_VERSION}"
curl -sL "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-kafka-connect-runtime/${ICEBERG_VERSION}/iceberg-kafka-connect-runtime-${ICEBERG_VERSION}.jar" \
  -o "${TMP_DIR}/iceberg-sink.jar"

echo "==> Uploading to s3://${BUCKET}/"
aws s3 cp "${TMP_DIR}/debezium-plugin.tar.gz" \
  "s3://${BUCKET}/debezium-postgres/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"
aws s3 cp "${TMP_DIR}/iceberg-sink.jar" \
  "s3://${BUCKET}/iceberg-sink/iceberg-kafka-connect-runtime-${ICEBERG_VERSION}.jar"

echo "==> Done. Plugins uploaded to s3://${BUCKET}/"
rm -rf "${TMP_DIR}"
```

**Step 2: Update msk-connect module to use real S3 objects as data sources**

Replace the placeholder `aws_s3_object` resources with `data "aws_s3_object"` that
reference the uploaded JARs. The script uploads first, Terraform references what's there.

**Step 3: Fix MNPI Iceberg Sink topic list**

In `modules/msk-connect/main.tf`, update the MNPI sink connector topics:
```hcl
# Before (includes dual-write topic):
"topics" = "cdc.trading.orders,cdc.trading.trades,cdc.trading.positions,stream.order-events"

# After (CDC-only — no dual-write):
"topics" = "cdc.trading.orders,cdc.trading.trades,cdc.trading.positions"
```

**Step 3: Commit**

```bash
git add scripts/upload-connector-plugins.sh terraform/aws/modules/msk-connect/
git commit -m "feat(msk-connect): add plugin upload script, wire real JARs"
```

---

## Phase 6: GitHub + Prod Deploy

### Task 11: Push to GitHub

**Step 1: Create GitHub repo**

```bash
gh repo create jediNight/data-lake-platform --public --description "Production-grade AWS data lake with MNPI isolation, Lake Formation ABAC, and medallion ETL"
```

**Step 2: Add remote and push**

```bash
cd /Users/toksfawibe/Documents/claude-agent-workspace/data-lake-platform
git remote add origin git@github.com:jediNight/data-lake-platform.git
git push -u origin main
```

**Step 3: Verify**

```bash
gh repo view jediNight/data-lake-platform --web
```

---

### Task 12: Deploy Prod

**Step 1: Build Lambda package**

```bash
./scripts/package-lambda.sh
```

**Step 2: Upload MSK Connect plugins**

```bash
./scripts/upload-connector-plugins.sh prod
```

**Step 3: Switch to prod workspace and apply**

```bash
cd terraform/aws
AWS_PROFILE=data-lake terraform workspace select prod
AWS_PROFILE=data-lake terraform plan -var-file=prod.tfvars
# Review the plan carefully — expect ~80+ resources to create
AWS_PROFILE=data-lake terraform apply -var-file=prod.tfvars
```

Expected resources created:
- VPC + subnets + NAT Gateway + IGW
- MSK cluster (3 brokers) — ~30 min creation time
- Aurora PostgreSQL (2 instances) — ~15 min
- MSK Connect (3 connectors) — ~10 min each
- 4 Glue jobs + workflow + triggers
- Lambda + API Gateway
- Lake Formation (tags, grants, registrations)
- Identity Center (groups, permission sets)
- CloudTrail + audit infrastructure

**Step 4: Verify MSK Connect connectors**

```bash
AWS_PROFILE=data-lake aws kafkaconnect list-connectors --region us-east-1
```
Expected: 3 connectors in RUNNING state

**Step 5: Test Lambda producer**

```bash
# Get the API Gateway endpoint from terraform output
API_URL=$(AWS_PROFILE=data-lake terraform output -raw lambda_api_endpoint)

# Health check
curl "$API_URL/health"

# Create an order
curl -X POST "$API_URL/api/v1/orders" \
  -H "Content-Type: application/json" \
  -d '{"account_id": 1, "instrument_id": 1, "side": "BUY", "quantity": 100, "ticker": "AAPL"}'
```

**Step 6: Trigger Glue workflow**

```bash
AWS_PROFILE=data-lake aws glue start-workflow-run \
  --name datalake-medallion-prod --region us-east-1
```

**Step 7: Verify analytics tables populated**

```bash
AWS_PROFILE=data-lake aws athena start-query-execution \
  --query-string "SELECT * FROM analytics_mnpi_prod.order_summary LIMIT 10" \
  --work-group data-engineers \
  --region us-east-1
```

---

### Task 13: Final Verification + Push

**Step 1: Run existing producer-api tests**

```bash
cd producer-api && pip install -r requirements-test.txt && pytest tests/ -v
```
Expected: 36 tests passing

**Step 2: Verify zero terraform drift**

```bash
cd terraform/aws
AWS_PROFILE=data-lake terraform plan -var-file=prod.tfvars
```
Expected: No changes

**Step 3: Push final state**

```bash
git push origin main
```

---

## Summary: Execution Order

| Phase | Tasks | Estimated Time |
|-------|-------|---------------|
| 1. Cleanup & Security | Tasks 1-3 | 30 min |
| 2. Networking | Task 4 | 30 min |
| 3. Lambda Producer | Tasks 5-7 | 1.5 hours |
| 4. Glue ETL | Tasks 8-9 | 30 min |
| 5. MSK Connect | Task 10 | 30 min |
| 6. Deploy & Verify | Tasks 11-13 | 2-3 hours (MSK/Aurora creation time) |
| **Total** | | **5-7 hours** |
