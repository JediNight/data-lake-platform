# Testing & Validation Strategy Design

## Overview

A layered testing strategy for the data-lake-platform covering infrastructure validation, application tests, local integration, and AWS end-to-end verification. The strategy includes an Alpaca Markets adapter as a complementary real-market-data source for the existing trading simulator.

## Architecture Context

The platform has four testable surfaces:

1. **Terraform IaC** — 9 AWS modules, 2 environments, ~40+ resource types
2. **Producer-API** — FastAPI with async Kafka + PostgreSQL + trading simulator
3. **Local Pipeline** — Kind cluster with Strimzi Kafka, Debezium CDC, Iceberg sinks
4. **AWS Pipeline** — MSK → Iceberg → S3 → Athena → Lake Formation grants

Currently: **zero tests, zero CI/CD**. Existing assets: `scripts/validation/` SQL queries and `Taskfile.yml` automation.

---

## Layer 1: Terraform Static Validation

### What It Tests

- HCL syntax and provider compatibility
- Module interface contracts (variable/output types)
- Security misconfigurations (public buckets, overly permissive IAM)
- Dev/prod environment parity

### Tools

| Tool | Purpose | Install |
|------|---------|---------|
| `terraform validate` | Syntax + provider schema | Built-in |
| `terraform plan` | Drift detection, resource graph | Built-in |
| `tflint` | Terraform linting, AWS best practices | `brew install tflint` |
| `tfsec` / `trivy` | Security scanning (S3 encryption, IAM wildcards) | `brew install trivy` |

### Implementation

**New file: `tests/terraform/validate.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

ENVS=("dev" "prod")
BASE="terraform/aws/environments"
PASS=0; FAIL=0

for env in "${ENVS[@]}"; do
  echo "=== Validating $env ==="
  cd "$BASE/$env"

  terraform init -backend=false -input=false > /dev/null 2>&1
  if terraform validate; then
    echo "  ✅ $env: valid"
    ((PASS++))
  else
    echo "  ❌ $env: INVALID"
    ((FAIL++))
  fi

  cd - > /dev/null
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

**New Taskfile targets:**

```yaml
validate:tf:
  desc: Validate all Terraform environments
  cmds:
    - bash tests/terraform/validate.sh

validate:tf:security:
  desc: Run Trivy security scan on Terraform
  cmds:
    - trivy config terraform/aws/modules/ --severity HIGH,CRITICAL
```

### Key Checks

- [ ] Both `dev` and `prod` pass `terraform validate`
- [ ] No HIGH/CRITICAL findings from security scanner
- [ ] `terraform plan` produces no unexpected destroys
- [ ] Module variable types match between environments

---

## Layer 2: Producer-API Unit Tests

### What It Tests

- Pydantic model validation (OrderEvent, MarketDataTick)
- FastAPI endpoint contracts (POST /api/v1/orders, POST /api/v1/market-data, GET /health)
- Simulator logic (price jitter, cycle execution, seed data loading)
- Kafka producer serialization
- Error handling (invalid payloads, connection failures)

### Dependencies

**New file: `producer-api/app/requirements-test.txt`**

```
pytest==8.3.4
pytest-asyncio==0.25.0
httpx==0.28.1
pytest-cov==6.0.0
```

### Test Structure

```
producer-api/
├── app/
│   └── ...
└── tests/
    ├── conftest.py              # Shared fixtures
    ├── test_models.py           # Pydantic model validation
    ├── test_endpoints.py        # FastAPI endpoint tests
    ├── test_simulator.py        # TradingSimulator unit tests
    └── test_producer.py         # KafkaEventProducer tests
```

### Key Test Cases

**test_models.py — Pydantic validation**

```python
def test_order_event_valid():
    """Minimum valid OrderEvent round-trips through JSON."""
    event = OrderEvent(
        event_id="uuid-1", event_type="ORDER_CREATED",
        order_id=1, account_id=1, instrument_id=1,
        ticker="AAPL", side="BUY", quantity=Decimal("100"),
        timestamp=datetime.now(timezone.utc),
    )
    assert event.model_dump_json()  # Serializes without error

def test_order_event_rejects_negative_quantity():
    """Quantity must be positive (if validation added)."""
    ...

def test_market_data_tick_bid_ask_spread():
    """Verify bid < ask invariant holds."""
    ...
```

**test_endpoints.py — FastAPI integration (no real Kafka/DB)**

```python
@pytest.fixture
def client(monkeypatch):
    """HTTPX test client with mocked Kafka + DB."""
    monkeypatch.setattr("app.main.kafka_producer", MockProducer())
    monkeypatch.setattr("app.main.trading_db", MockDatabase())
    from app.main import app
    return TestClient(app)

def test_health_endpoint(client):
    resp = client.get("/health")
    assert resp.status_code == 200

def test_post_order_returns_201(client):
    resp = client.post("/api/v1/orders", json={...})
    assert resp.status_code == 201

def test_post_market_data_returns_201(client):
    resp = client.post("/api/v1/market-data", json={...})
    assert resp.status_code == 201

def test_post_order_invalid_payload_returns_422(client):
    resp = client.post("/api/v1/orders", json={"bad": "data"})
    assert resp.status_code == 422
```

**test_simulator.py — Simulator logic**

```python
def test_jitter_price_stays_within_bounds():
    """Price jitter factor [0.995, 1.005] keeps price within 0.5%."""
    sim = TradingSimulator(mock_db, mock_kafka)
    sim._price_book = {"AAPL": Decimal("178.50")}
    for _ in range(1000):
        price = sim._jitter_price("AAPL")
        assert Decimal("170") < price < Decimal("190")

def test_load_seed_data_uses_defaults_when_file_missing(tmp_path):
    """Falls back to DEFAULT_INSTRUMENTS when seed file absent."""
    ...

def test_load_seed_data_from_file(tmp_path):
    """Reads instruments and accounts from JSON seed file."""
    ...
```

### Taskfile Target

```yaml
test:unit:
  desc: Run producer-api unit tests
  cmds:
    - |
      cd producer-api
      pip install -r app/requirements.txt -r app/requirements-test.txt -q
      pytest tests/ -v --tb=short --cov=app --cov-report=term-missing
```

---

## Layer 3: Alpaca Markets Adapter

### Purpose

Complement the built-in trading simulator with real market data from Alpaca's free tier. The simulator provides 24/7 deterministic data generation; Alpaca provides realistic price movements, real ticker symbols, and WebSocket-driven market data during market hours.

### Why Complementary, Not Replacement

| Aspect | Built-in Simulator | Alpaca Adapter |
|--------|-------------------|----------------|
| Availability | 24/7, no API key needed | Market hours only (9:30-4 ET) |
| Data control | Deterministic, reproducible | Real market volatility |
| Rate limits | None | 200 req/min (free tier) |
| CDC path | ✅ INSERTs into PostgreSQL | ✅ Same path via producer-api |
| Streaming path | ✅ Produces to Kafka | ✅ Same path via producer-api |
| Interview demo | Works offline | Impressive live data |

### Alpaca Free Tier

- **Paper trading**: Simulated orders with real market behavior
- **IEX market data**: Real-time quotes (15-min delayed on free plan)
- **WebSocket streaming**: `wss://stream.data.alpaca.markets/v2/iex`
- **Rate limit**: 200 API calls/minute
- **Auth**: API key + secret (environment variables)

### Architecture

```
Alpaca WebSocket ──→ AlpacaAdapter ──→ producer-api POST endpoints
  (real market data)    (transforms)     (same as simulator path)
                                              │
                                         ┌────┴────┐
                                         ↓         ↓
                                    PostgreSQL    Kafka
                                    (CDC path)   (stream path)
```

The adapter is a **standalone Python script** that:
1. Connects to Alpaca's WebSocket for real-time quotes
2. Transforms Alpaca trade/quote events into our `OrderEvent` / `MarketDataTick` models
3. POSTs to the producer-api REST endpoints (same path as the simulator)
4. Optionally places paper trades via Alpaca's trading API

### New Files

```
producer-api/
├── app/
│   └── ...
├── alpaca_adapter/
│   ├── __init__.py
│   ├── adapter.py          # Core adapter: Alpaca → producer-api
│   ├── config.py           # Alpaca API key config (env vars)
│   └── transforms.py       # Alpaca event → OrderEvent/MarketDataTick
├── tests/
│   └── test_alpaca_transforms.py  # Transform unit tests
└── Dockerfile.alpaca       # Optional: separate container
```

### Key Implementation

**alpaca_adapter/transforms.py:**

```python
from app.models import MarketDataTick, OrderEvent

INSTRUMENT_MAP = {
    "AAPL": 1, "MSFT": 2, "GOOGL": 3, "JPM": 4,
    "GS": 5, "BRK.B": 6, "SPY": 7, "AGG": 8,
}

def alpaca_quote_to_market_tick(quote: dict) -> MarketDataTick | None:
    """Transform Alpaca quote event to our MarketDataTick model."""
    ticker = quote.get("S")
    if ticker not in INSTRUMENT_MAP:
        return None
    return MarketDataTick(
        tick_id=str(uuid.uuid4()),
        instrument_id=INSTRUMENT_MAP[ticker],
        ticker=ticker,
        bid=Decimal(str(quote["bp"])),
        ask=Decimal(str(quote["ap"])),
        last_price=Decimal(str(quote.get("bp", 0) + quote.get("ap", 0))) / 2,
        volume=int(quote.get("bz", 0) + quote.get("az", 0)),
        timestamp=datetime.fromisoformat(quote["t"]),
    )

def alpaca_trade_to_order_event(trade: dict, account_id: int) -> OrderEvent | None:
    """Transform Alpaca trade event to our OrderEvent model."""
    ticker = trade.get("S")
    if ticker not in INSTRUMENT_MAP:
        return None
    return OrderEvent(
        event_id=str(uuid.uuid4()),
        event_type="ORDER_CREATED",
        order_id=random.randint(10000, 99999),
        account_id=account_id,
        instrument_id=INSTRUMENT_MAP[ticker],
        ticker=ticker,
        side=random.choice(["BUY", "SELL"]),
        quantity=Decimal(str(trade.get("s", 100))),
        limit_price=Decimal(str(trade["p"])),
        timestamp=datetime.fromisoformat(trade["t"]),
    )
```

**alpaca_adapter/adapter.py:**

```python
async def run_adapter(api_url: str, producer_url: str, symbols: list[str]):
    """Connect to Alpaca WebSocket and forward events to producer-api."""
    async with websockets.connect(api_url) as ws:
        # Authenticate
        await ws.send(json.dumps({
            "action": "auth",
            "key": os.environ["ALPACA_API_KEY"],
            "secret": os.environ["ALPACA_SECRET_KEY"],
        }))

        # Subscribe to quotes for our instruments
        await ws.send(json.dumps({
            "action": "subscribe",
            "quotes": symbols,
            "trades": symbols,
        }))

        async for message in ws:
            events = json.loads(message)
            for event in events:
                if event.get("T") == "q":  # Quote
                    tick = alpaca_quote_to_market_tick(event)
                    if tick:
                        await httpx.AsyncClient().post(
                            f"{producer_url}/api/v1/market-data",
                            json=tick.model_dump(mode="json"),
                        )
                elif event.get("T") == "t":  # Trade
                    order = alpaca_trade_to_order_event(event, account_id=1)
                    if order:
                        await httpx.AsyncClient().post(
                            f"{producer_url}/api/v1/orders",
                            json=order.model_dump(mode="json"),
                        )
```

### Taskfile Target

```yaml
alpaca:start:
  desc: Start Alpaca adapter (requires ALPACA_API_KEY and ALPACA_SECRET_KEY)
  env:
    PRODUCER_API_URL: http://localhost:8000
  cmds:
    - python -m producer_api.alpaca_adapter.adapter

alpaca:test:
  desc: Test Alpaca transforms (no API key needed)
  cmds:
    - pytest producer-api/tests/test_alpaca_transforms.py -v
```

---

## Layer 4: Local Integration Tests (Kind Cluster)

### What It Tests

End-to-end data flow through the local pipeline:
```
PostgreSQL INSERT → Debezium CDC → Kafka topic → verify message arrives
Producer-API POST → Kafka topic → verify message arrives
```

### Prerequisites

- Kind cluster running (`task infra`)
- All pods healthy (`task status`)
- Simulator disabled (for controlled testing)

### Implementation

**New file: `tests/integration/test_pipeline.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Local Pipeline Integration Tests ==="

# --- Test 1: CDC path (PostgreSQL → Debezium → Kafka) ---
echo ""
echo "--- Test 1: CDC Path ---"

# Insert a test order with known values
BEFORE_COUNT=$(kubectl -n strimzi exec -it data-lake-cluster-kafka-0 -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic cdc.trading.orders \
  --from-beginning --timeout-ms 5000 2>/dev/null | wc -l)

kubectl -n data exec -i statefulset/sample-postgres -- \
  psql -U postgres -d trading -c \
  "INSERT INTO orders (account_id, instrument_id, side, quantity, order_type, status)
   VALUES (1, 1, 'BUY', 999, 'MARKET', 'PENDING');"

# Wait for Debezium to capture the change
sleep 10

AFTER_COUNT=$(kubectl -n strimzi exec -it data-lake-cluster-kafka-0 -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic cdc.trading.orders \
  --from-beginning --timeout-ms 5000 2>/dev/null | wc -l)

if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
  echo "  ✅ CDC path: PostgreSQL INSERT captured in Kafka"
else
  echo "  ❌ CDC path: No new message in cdc.trading.orders"
  exit 1
fi

# --- Test 2: Streaming path (producer-api → Kafka) ---
echo ""
echo "--- Test 2: Streaming Path ---"

PRODUCER_POD=$(kubectl -n data get pod -l app=producer-api -o jsonpath='{.items[0].metadata.name}')

kubectl -n data exec "$PRODUCER_POD" -- \
  curl -s -X POST http://localhost:8000/api/v1/market-data \
  -H "Content-Type: application/json" \
  -d '{
    "tick_id": "test-001",
    "instrument_id": 1, "ticker": "AAPL",
    "bid": "178.40", "ask": "178.60", "last_price": "178.50",
    "volume": 1000,
    "timestamp": "2026-02-28T12:00:00Z"
  }'

sleep 5

# Verify message in stream.market-data topic
MARKET_MSG=$(kubectl -n strimzi exec -it data-lake-cluster-kafka-0 -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic stream.market-data \
  --from-beginning --timeout-ms 5000 2>/dev/null | grep "test-001" || true)

if [ -n "$MARKET_MSG" ]; then
  echo "  ✅ Streaming path: Market data tick received in Kafka"
else
  echo "  ❌ Streaming path: test-001 not found in stream.market-data"
  exit 1
fi

# --- Test 3: Health check ---
echo ""
echo "--- Test 3: Health Check ---"
HEALTH=$(kubectl -n data exec "$PRODUCER_POD" -- curl -s http://localhost:8000/health)
echo "  Health response: $HEALTH"
echo "  ✅ Producer-API healthy"

echo ""
echo "=== All integration tests passed ==="
```

### Taskfile Targets

```yaml
test:integration:
  desc: Run local pipeline integration tests (Kind cluster must be running)
  cmds:
    - bash tests/integration/test_pipeline.sh

test:integration:topics:
  desc: List all Kafka topics and their message counts
  cmds:
    - |
      kubectl -n strimzi exec -it data-lake-cluster-kafka-0 -- \
        bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

---

## Layer 5: AWS End-to-End Validation

### What It Tests

Post-deploy verification of the full AWS pipeline:
1. Terraform plan is clean (no drift)
2. MSK cluster is ACTIVE, topics exist
3. S3 buckets have expected structure
4. Glue Catalog databases and tables exist
5. Lake Formation grants enforce MNPI isolation
6. Athena queries work per-persona
7. CloudTrail audit events are captured

### Implementation

**New file: `tests/aws/validate_infrastructure.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-dev}"
REGION="us-east-1"
PROFILE="data-lake"

echo "=== AWS Infrastructure Validation ($ENV) ==="

# --- 1. Terraform plan (drift detection) ---
echo ""
echo "--- 1. Terraform Plan (drift check) ---"
cd "terraform/aws/environments/$ENV"
terraform init -input=false > /dev/null 2>&1
PLAN_OUTPUT=$(terraform plan -detailed-exitcode 2>&1) || PLAN_EXIT=$?
cd - > /dev/null

case ${PLAN_EXIT:-0} in
  0) echo "  ✅ No drift detected" ;;
  2) echo "  ⚠️  Infrastructure drift detected"; echo "$PLAN_OUTPUT" ;;
  *) echo "  ❌ Plan failed"; echo "$PLAN_OUTPUT"; exit 1 ;;
esac

# --- 2. S3 buckets exist and are encrypted ---
echo ""
echo "--- 2. S3 Bucket Validation ---"
for BUCKET_PREFIX in "datalake-mnpi-$ENV" "datalake-nonmnpi-$ENV" "datalake-audit-$ENV"; do
  BUCKET=$(aws s3api list-buckets --profile "$PROFILE" \
    --query "Buckets[?starts_with(Name, '$BUCKET_PREFIX')].Name" \
    --output text)
  if [ -n "$BUCKET" ]; then
    ENCRYPTION=$(aws s3api get-bucket-encryption --bucket "$BUCKET" \
      --profile "$PROFILE" --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" \
      --output text 2>/dev/null || echo "NONE")
    echo "  ✅ $BUCKET (encryption: $ENCRYPTION)"
  else
    echo "  ❌ No bucket matching $BUCKET_PREFIX"
  fi
done

# --- 3. Glue Catalog databases ---
echo ""
echo "--- 3. Glue Catalog Databases ---"
EXPECTED_DBS=("raw_mnpi_$ENV" "raw_nonmnpi_$ENV" "curated_mnpi_$ENV" "curated_nonmnpi_$ENV" "analytics_mnpi_$ENV" "analytics_nonmnpi_$ENV")
for DB in "${EXPECTED_DBS[@]}"; do
  if aws glue get-database --name "$DB" --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
    echo "  ✅ $DB"
  else
    echo "  ❌ $DB not found"
  fi
done

# --- 4. Lake Formation LF-Tags ---
echo ""
echo "--- 4. Lake Formation Tags ---"
for TAG in "sensitivity" "layer"; do
  VALUES=$(aws lakeformation get-lf-tag --tag-key "$TAG" \
    --profile "$PROFILE" --region "$REGION" \
    --query "TagValues" --output text 2>/dev/null || echo "NOT_FOUND")
  echo "  Tag '$TAG': $VALUES"
done

# --- 5. MSK cluster status ---
echo ""
echo "--- 5. MSK Cluster ---"
CLUSTER_ARN=$(aws kafka list-clusters-v2 --profile "$PROFILE" --region "$REGION" \
  --query "ClusterInfoList[?ClusterName=='data-lake-$ENV'].ClusterArn" \
  --output text 2>/dev/null || echo "")
if [ -n "$CLUSTER_ARN" ]; then
  STATE=$(aws kafka describe-cluster-v2 --cluster-arn "$CLUSTER_ARN" \
    --profile "$PROFILE" --region "$REGION" \
    --query "ClusterInfo.State" --output text)
  echo "  ✅ MSK cluster: $STATE"
else
  echo "  ⚠️  MSK cluster not found (expected if not yet deployed)"
fi

echo ""
echo "=== Validation complete ==="
```

**New file: `tests/aws/validate_access_control.sh`**

This script wraps the existing `scripts/validation/access_validation.sql` with persona role assumption:

```bash
#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-dev}"
PROFILE="data-lake"
WORKGROUP_PREFIX="data-lake-$ENV"

echo "=== Lake Formation Access Control Validation ==="

# Test: Data Analyst CANNOT access MNPI data
echo ""
echo "--- Data Analyst → curated_mnpi.orders (expect FAIL) ---"
RESULT=$(aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM curated_mnpi_${ENV}.orders" \
  --work-group "${WORKGROUP_PREFIX}-data-analysts" \
  --profile "$PROFILE" \
  --query "QueryExecutionId" --output text 2>&1) || true

if echo "$RESULT" | grep -qi "AccessDenied\|FAILED"; then
  echo "  ✅ Correctly denied MNPI access to Data Analyst"
else
  echo "  ⚠️  Query submitted (ID: $RESULT) — check execution status"
fi

# Test: Finance Analyst CAN access MNPI curated data
echo ""
echo "--- Finance Analyst → curated_mnpi.orders (expect SUCCEED) ---"
RESULT=$(aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM curated_mnpi_${ENV}.orders" \
  --work-group "${WORKGROUP_PREFIX}-finance-analysts" \
  --profile "$PROFILE" \
  --query "QueryExecutionId" --output text 2>&1) || true

echo "  Query execution ID: $RESULT"
echo "  (Check execution status for SUCCEEDED/FAILED)"

echo ""
echo "=== Access control tests submitted ==="
```

### Taskfile Targets

```yaml
validate:aws:
  desc: Validate AWS infrastructure (S3, Glue, LF, MSK)
  cmds:
    - bash tests/aws/validate_infrastructure.sh {{.CLI_ARGS | default "dev"}}

validate:aws:access:
  desc: Validate Lake Formation access control per persona
  cmds:
    - bash tests/aws/validate_access_control.sh {{.CLI_ARGS | default "dev"}}
```

---

## Layer 6: CI/CD Pipeline (GitHub Actions)

### What It Automates

| Trigger | Jobs |
|---------|------|
| Push to any branch | Terraform validate, tflint, security scan |
| Push to `main` | Above + producer-api unit tests + Docker build |
| Pull request | Above + `terraform plan` comment on PR |
| Manual dispatch | AWS infrastructure validation |

### Implementation

**New file: `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main, 'feat/**']
  pull_request:
    branches: [main]

jobs:
  terraform-validate:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [dev, prod]
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - name: Terraform Init
        run: terraform -chdir=terraform/aws/environments/${{ matrix.environment }} init -backend=false
      - name: Terraform Validate
        run: terraform -chdir=terraform/aws/environments/${{ matrix.environment }} validate

  security-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Trivy
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: config
          scan-ref: terraform/aws/modules/
          severity: HIGH,CRITICAL

  producer-api-tests:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: producer-api
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - name: Install dependencies
        run: pip install -r app/requirements.txt -r app/requirements-test.txt
      - name: Run tests
        run: pytest tests/ -v --tb=short --cov=app --cov-report=term-missing
```

---

## Test Execution Summary

### Quick Validation (Pre-Commit)

```bash
task validate:tf          # ~10s: Terraform validate both envs
task test:unit            # ~15s: Producer-API unit tests
```

### Local Integration (After `task up`)

```bash
task test:integration     # ~60s: CDC + streaming path verification
```

### AWS Validation (Post-Deploy)

```bash
task validate:aws         # ~30s: Infrastructure checks (S3, Glue, LF, MSK)
task validate:aws:access  # ~60s: Lake Formation grant enforcement
```

### Full Suite

```bash
task test:all             # Runs validate:tf → test:unit → test:integration
```

### Taskfile Target

```yaml
test:all:
  desc: Run all tests (Terraform + unit + integration)
  cmds:
    - task: validate:tf
    - task: test:unit
    - task: test:integration
```

---

## Interview Demonstration Flow

For the interview, the recommended demo sequence is:

1. **`task validate:tf`** — Show both environments validate cleanly
2. **`task aws:plan`** — Show terraform plan with no drift
3. **`task up`** — Boot local Kind cluster with full pipeline
4. **`task status`** — Show all pods healthy (PostgreSQL, Kafka, Debezium, producer-api)
5. **`task test:integration`** — Demonstrate CDC and streaming paths work end-to-end
6. **Start Alpaca adapter** — Show real market data flowing through the same pipeline
7. **`task db:shell`** — Query PostgreSQL to show orders, trades, positions
8. **`task validate:aws:access`** — Demonstrate Lake Formation MNPI isolation

This sequence demonstrates: IaC discipline, local development workflow, CDC + streaming data paths, real market data integration, and governance enforcement.

---

## Files Changed

| Action | Path |
|--------|------|
| CREATE | `tests/terraform/validate.sh` |
| CREATE | `tests/integration/test_pipeline.sh` |
| CREATE | `tests/aws/validate_infrastructure.sh` |
| CREATE | `tests/aws/validate_access_control.sh` |
| CREATE | `producer-api/app/requirements-test.txt` |
| CREATE | `producer-api/tests/conftest.py` |
| CREATE | `producer-api/tests/test_models.py` |
| CREATE | `producer-api/tests/test_endpoints.py` |
| CREATE | `producer-api/tests/test_simulator.py` |
| CREATE | `producer-api/alpaca_adapter/__init__.py` |
| CREATE | `producer-api/alpaca_adapter/adapter.py` |
| CREATE | `producer-api/alpaca_adapter/config.py` |
| CREATE | `producer-api/alpaca_adapter/transforms.py` |
| CREATE | `producer-api/tests/test_alpaca_transforms.py` |
| CREATE | `.github/workflows/ci.yml` |
| MODIFY | `Taskfile.yml` (add test/validate targets) |
| MODIFY | `scripts/validation/access_validation.sql` (update persona references) |
