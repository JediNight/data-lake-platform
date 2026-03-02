# Lambda Trading Simulator — Design Document

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the FastAPI `producer-api` K8s pod with a serverless Lambda function for production, triggered by EventBridge every 1 minute to generate realistic trading activity that feeds the CDC and streaming pipelines.

**Architecture:** EventBridge schedule → Lambda (VPC-attached, private subnet) → Aurora via RDS Data API (HTTPS) + MSK via kafka-python (port 9098, IAM auth). Lambda Powertools for structured logging and X-Ray tracing.

**Tech Stack:** Python 3.11, boto3 (RDS Data API), kafka-python + aws-msk-iam-sasl-signer-python (MSK IAM), AWS Lambda Powertools (logging/tracing), Terraform (IaC).

---

## Context

### What exists today

| Component | Status |
|---|---|
| `producer-api/` (FastAPI + asyncpg + aiokafka) | Working for local dev (Kind + Strimzi) |
| `locals.tf` feature flags | `enable_lambda_producer = false` (dev), `true` (prod) |
| `main.tf` module block | Wired at lines 248-269 — passes subnet IDs, SG, MSK ARNs, Aurora secrets |
| `modules/lambda-producer/` | **Does not exist yet** — module directory needs to be created |
| Networking module | Lambda SG with MSK (9098) + Aurora (5432) egress already configured |
| NAT Gateway | Exists in networking module (private subnet outbound) |
| STS VPC Endpoint | **Does not exist** — needed for MSK IAM auth without NAT dependency |
| `init-aurora-cdc.sh` | Idempotent DDL + seeding via RDS Data API — stays as-is for migrations |

### Key design decisions

1. **Dev vs Prod**: `producer-api/` (K8s pod) for local dev, Lambda for prod — controlled by `enable_lambda_producer` flag
2. **RDS Data API** for Aurora writes — no VPC routing needed for DB, IAM-based auth
3. **VPC placement** required for MSK access (port 9098) — Lambda goes in private subnets
4. **STS VPC Interface Endpoint** for MSK IAM token generation (~$7.30/month) — avoids NAT dependency for auth tokens
5. **Lambda Powertools** via AWS-managed layer (zero packaging overhead)
6. **Pure Terraform** — no SAM/SST/Serverless Framework (single IaC tool, single state backend)
7. **Keep `init-aurora-cdc.sh`** for schema management — no Alembic needed for 5 stable tables

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  EventBridge                                                     │
│  rate(1 minute)                                                  │
│      │                                                           │
│      ▼                                                           │
│  ┌─────────────────────────────────────────────┐                 │
│  │  Lambda: trading-simulator                   │                │
│  │  (VPC: private subnets, Lambda SG)           │                │
│  │                                              │                │
│  │  1. Pick random ticker/side/qty/price        │                │
│  │  2. INSERT order → Aurora (RDS Data API)     │──── HTTPS ───▶ Aurora PostgreSQL
│  │  3. Jitter price, INSERT trade               │                │
│  │  4. UPDATE order → FILLED                    │                │
│  │  5. Produce mnpi_events → MSK               │──── 9098 ────▶ MSK (IAM auth)
│  │  6. UPSERT position                          │                │     │
│  │  7. Produce nonmnpi_events → MSK            │                │     │
│  │                                              │                │     ▼
│  │  Powertools: structured JSON logs + X-Ray    │                │  Debezium (MSK Connect)
│  └─────────────────────────────────────────────┘                 │  captures CDC from Aurora
│                                                                  │     │
│  STS VPC Endpoint ◀── MSK IAM token generation                   │     ▼
│  S3 Gateway Endpoint ◀── (existing, for Iceberg writes)          │  Iceberg Sink → S3
└──────────────────────────────────────────────────────────────────┘
```

### Data flow (two paths)

**Path 1 — CDC (MNPI orders/trades/positions):**
Lambda → INSERT/UPDATE in Aurora (Data API) → Debezium captures WAL → MSK `cdc.*` topics → Iceberg S3 Sink → raw MNPI S3 bucket

**Path 2 — Streaming (market data ticks):**
Lambda → Produce directly to MSK `stream.market-data` topic → Iceberg S3 Sink → raw non-MNPI S3 bucket

---

## Lambda Handler Design

### Directory structure

```
scripts/lambda/trading_simulator/
  main.py            # Lambda handler entry point + Powertools decorators
  simulator.py       # Trading cycle logic (sync, single cycle per invocation)
  database.py        # RDS Data API wrapper (boto3 rds-data)
  producer.py        # MSK Kafka producer (kafka-python + IAM auth)
  requirements.txt   # kafka-python, aws-msk-iam-sasl-signer-python
```

### `main.py` — Handler

```python
import os
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

from simulator import TradingSimulator
from database import TradingDatabase
from producer import MSKProducer

logger = Logger(service="trading-simulator")
tracer = Tracer(service="trading-simulator")

# Init outside handler for connection reuse across warm invocations
db = TradingDatabase(
    cluster_arn=os.environ["AURORA_CLUSTER_ARN"],
    secret_arn=os.environ["AURORA_SECRET_ARN"],
    database=os.environ.get("AURORA_DATABASE", "trading"),
)
kafka = MSKProducer(
    bootstrap_servers=os.environ["KAFKA_BOOTSTRAP_SERVERS"],
)

@logger.inject_lambda_context(log_event=True)
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    simulator = TradingSimulator(db=db, kafka=kafka)
    result = simulator.run_cycle()
    logger.info("Cycle complete", extra={"result": result})
    return result
```

### `database.py` — RDS Data API wrapper

Converts the asyncpg queries from `producer-api/app/database.py` to synchronous `boto3.client("rds-data").execute_statement()` calls. Same SQL, different transport:

- `insert_order()` → `execute_statement()` with `RETURNING order_id`
- `insert_trade()` → `execute_statement()` with `RETURNING trade_id`
- `update_order_filled()` → `execute_statement()` UPDATE
- `upsert_position()` → `execute_statement()` INSERT ON CONFLICT

RDS Data API uses typed parameter lists (`[{"name": "account_id", "value": {"longValue": 1}}]`) instead of positional `$1` parameters.

### `producer.py` — MSK IAM auth producer

```python
from kafka import KafkaProducer
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

def _msk_auth_cb(auth_token_provider):
    def callback(required_callback_param=None):
        token, _ = auth_token_provider.generate_auth_token("us-east-1")
        return token
    return callback

class MSKProducer:
    TOPIC_MARKET_DATA = "stream.market-data"

    def __init__(self, bootstrap_servers: str):
        provider = MSKAuthTokenProvider(region="us-east-1")
        self.producer = KafkaProducer(
            bootstrap_servers=bootstrap_servers.split(","),
            security_protocol="SASL_SSL",
            sasl_mechanism="OAUTHBEARER",
            sasl_oauth_token_provider=provider,
            value_serializer=lambda v: json.dumps(v, default=str).encode(),
        )

    def send_market_data(self, tick: dict) -> None:
        self.producer.send(self.TOPIC_MARKET_DATA, value=tick)
        self.producer.flush()
```

### `simulator.py` — Trading cycle

Sync port of `producer-api/app/simulator.py._run_cycle()`:

1. Pick random account_id, instrument (from hardcoded seed list matching `init-aurora-cdc.sh`)
2. Random side (BUY/SELL), quantity (100-5000), order_type (MARKET/LIMIT)
3. `INSERT` order via `database.insert_order()` → get `order_id`
4. Jitter price (±0.5%)
5. `INSERT` trade via `database.insert_trade()` → get `trade_id`
6. `UPDATE` order status → FILLED via `database.update_order_filled()`
7. Produce `MarketDataTick` to MSK via `producer.send_market_data()`
8. `UPSERT` position via `database.upsert_position()`

No artificial sleep — full cycle runs in ~1-2 seconds.

Returns `{"order_id": N, "trade_id": N, "ticker": "AAPL", "side": "BUY", "quantity": 500}` for logging.

---

## Terraform Module

### `modules/lambda-producer/` — Resources

The existing `module "lambda_producer"` block in `main.tf` (lines 248-269) needs to be updated. The current block passes `postgres_dsn` (direct PG connection) which we're replacing with RDS Data API parameters.

**Resources in the module:**

| Resource | Purpose |
|---|---|
| `aws_iam_role.lambda` | Lambda execution role with assume policy |
| `aws_iam_role_policy.msk` | MSK IAM auth (kafka-cluster:Connect, WriteData, DescribeTopic) |
| `aws_iam_role_policy.rds_data_api` | RDS Data API (rds-data:ExecuteStatement, BatchExecuteStatement) |
| `aws_iam_role_policy.secrets` | Secrets Manager (GetSecretValue) for Aurora credentials |
| `aws_iam_role_policy_attachment.vpc` | AWSLambdaVPCAccessExecutionRole managed policy |
| `aws_lambda_layer_version.deps` | pip dependencies (kafka-python, msk-iam-sasl-signer) |
| `aws_lambda_function.simulator` | Python 3.11, 512MB, 5min timeout, VPC-attached |
| `aws_cloudwatch_event_rule.schedule` | EventBridge rate(1 minute) |
| `aws_cloudwatch_event_target.simulator` | Connects rule → Lambda |
| `aws_lambda_permission.eventbridge` | Allows EventBridge to invoke Lambda |

**Lambda Powertools layer:** Use AWS-managed layer ARN (no packaging):
```hcl
layers = [
  aws_lambda_layer_version.deps.arn,
  "arn:aws:lambda:${data.aws_region.current.name}:017000801446:layer:AWSLambdaPowertoolsPythonV3-python311-x86_64:7"
]
```

**Environment variables:**
```hcl
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
```

### Updated `main.tf` module block

Replace the current wiring (lines 248-269) with:
```hcl
module "lambda_producer" {
  source = "./modules/lambda-producer"
  count  = local.c.enable_lambda_producer ? 1 : 0

  environment              = local.env
  subnet_ids               = module.networking.private_subnet_ids
  lambda_security_group_id = module.networking.lambda_security_group_id
  msk_cluster_arn          = module.streaming[0].cluster_arn
  msk_bootstrap_brokers    = module.streaming[0].bootstrap_brokers_iam
  aurora_cluster_arn       = module.aurora_postgres[0].cluster_arn
  aurora_secret_arn        = module.aurora_postgres[0].master_password_secret_arn

  function_zip_path = "${path.module}/../../.build/trading-simulator.zip"
  layer_zip_path    = "${path.module}/../../.build/trading-simulator-layer.zip"

  schedule_enabled = true
  tags             = {}
}
```

---

## Networking Additions

### STS VPC Interface Endpoint

Add to `modules/networking/main.tf`:

```hcl
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
```

Also add a VPC Endpoints security group (HTTPS 443 from Lambda SG):

```hcl
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "datalake-vpce-${var.environment}-"
  description = "VPC Interface Endpoints - HTTPS from Lambda"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "datalake-vpce-sg-${var.environment}"
  })

  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_lambda" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS from Lambda functions"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}
```

**Cost:** ~$7.30/month (2 ENIs × $0.01/hr + data processing).

---

## Build Script

`scripts/build_lambda.sh`:

```bash
#!/bin/bash
set -euo pipefail

BUILD_DIR=".build"
SRC_DIR="scripts/lambda/trading_simulator"

# --- Build Layer (pip deps) ---
LAYER_DIR="$BUILD_DIR/layer/python/lib/python3.11/site-packages"
rm -rf "$BUILD_DIR/layer"
mkdir -p "$LAYER_DIR"
pip install -r "$SRC_DIR/requirements.txt" \
  -t "$LAYER_DIR" \
  --platform manylinux2014_x86_64 \
  --only-binary=:all: \
  --quiet
(cd "$BUILD_DIR/layer" && zip -rq ../trading-simulator-layer.zip .)

# --- Build Function ZIP ---
(cd "$SRC_DIR" && zip -rq "../../../$BUILD_DIR/trading-simulator.zip" . \
  --exclude "*.pyc" --exclude "__pycache__/*" --exclude "requirements.txt")

echo "Built: $BUILD_DIR/trading-simulator.zip"
echo "Built: $BUILD_DIR/trading-simulator-layer.zip"
```

**Cross-platform note:** `--platform manylinux2014_x86_64 --only-binary=:all:` ensures Linux-compatible wheels when building on macOS.

---

## Files Summary

| File | Action |
|---|---|
| `scripts/lambda/trading_simulator/main.py` | CREATE — Lambda handler + Powertools |
| `scripts/lambda/trading_simulator/simulator.py` | CREATE — Sync trading cycle |
| `scripts/lambda/trading_simulator/database.py` | CREATE — RDS Data API wrapper |
| `scripts/lambda/trading_simulator/producer.py` | CREATE — MSK IAM-auth Kafka producer |
| `scripts/lambda/trading_simulator/requirements.txt` | CREATE — pip deps |
| `terraform/aws/modules/lambda-producer/main.tf` | CREATE — Lambda + EventBridge + IAM |
| `terraform/aws/modules/lambda-producer/variables.tf` | CREATE — Module inputs |
| `terraform/aws/modules/lambda-producer/outputs.tf` | CREATE — function_name, function_arn |
| `terraform/aws/main.tf` | MODIFY — Update lambda_producer module block (RDS Data API params) |
| `terraform/aws/modules/networking/main.tf` | MODIFY — Add STS VPC endpoint + VPC endpoints SG |
| `terraform/aws/modules/networking/outputs.tf` | MODIFY — Expose vpc_endpoints_sg_id |
| `terraform/aws/outputs.tf` | MODIFY — Expose Lambda outputs |
| `scripts/build_lambda.sh` | CREATE — Build script for Lambda artifacts |

---

## Verification

```bash
# 1. Build Lambda artifacts
./scripts/build_lambda.sh

# 2. Terraform plan (expect ~15 new resources)
cd terraform/aws && terraform plan -var-file=dev.tfvars

# 3. Apply (prod workspace)
terraform workspace select prod
terraform apply -var-file=prod.tfvars

# 4. Verify Lambda exists
aws lambda get-function --function-name datalake-trading-simulator-prod

# 5. Verify EventBridge rule
aws events describe-rule --name datalake-trading-simulator-prod

# 6. Invoke manually to test
aws lambda invoke --function-name datalake-trading-simulator-prod \
  --payload '{}' --log-type Tail /tmp/lambda-output.json \
  --query 'LogResult' --output text | base64 -d

# 7. Check CloudWatch Logs (structured JSON from Powertools)
aws logs filter-log-events \
  --log-group-name /aws/lambda/datalake-trading-simulator-prod \
  --filter-pattern '{$.service = "trading-simulator"}'

# 8. Verify data flow via Athena
task athena:query \
  QUERY="SELECT count(*) FROM raw_mnpi_prod.mnpi_events WHERE timestamp > current_timestamp - interval '5' minute"
```
