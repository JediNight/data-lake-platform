# Producer API Design

## Overview

A thin FastAPI service that exercises both data ingestion paths in the data lake platform: CDC (via PostgreSQL INSERTs triggering Debezium) and streaming (via direct Kafka production). Includes a built-in simulator that generates correlated trading activity for end-to-end demos.

## Architecture

The producer-api has two connections:
- **asyncpg** pool to sample-postgres (triggers CDC path via Debezium)
- **aiokafka** producer to Kafka (exercises streaming path directly)

It deploys via the same GitOps pattern as all other components: Kustomize base/overlays with an ArgoCD ApplicationSet.

## REST Endpoints

| Method | Path | Description | Target |
|--------|------|-------------|--------|
| POST | /api/v1/orders | INSERT order into PostgreSQL + produce OrderEvent to stream.order-events | CDC + Streaming |
| POST | /api/v1/market-data | Produce MarketDataTick to stream.market-data | Streaming only |
| GET | /health | Liveness/readiness probe | - |

## Data Models

### OrderEvent (stream.order-events)

```python
class OrderEvent(BaseModel):
    event_id: str           # UUID4
    event_type: str         # ORDER_SUBMITTED
    order_id: int           # matches postgres serial — cross-path correlation key
    account_id: int         # from seed data (1-5)
    instrument_id: int      # from seed data (1-8)
    ticker: str             # denormalized for streaming consumers
    side: str               # BUY | SELL
    quantity: Decimal
    limit_price: Decimal | None
    timestamp: datetime     # ISO 8601 UTC
```

### MarketDataTick (stream.market-data)

```python
class MarketDataTick(BaseModel):
    tick_id: str            # UUID4
    instrument_id: int      # from seed data (1-8)
    ticker: str
    bid: Decimal
    ask: Decimal
    last_price: Decimal
    volume: int             # shares in this tick
    timestamp: datetime     # ISO 8601 UTC
```

Both models serialize to flat JSON, compatible with the Iceberg sink connectors (JsonConverter, schemas.enable=false).

## Built-in Simulator

Activated via `SIMULATION_ENABLED=true`. Runs an async background loop every `SIMULATION_INTERVAL_SECONDS` (default: 5).

Each cycle:
1. Pick a random account (1-5) and instrument (1-8) from seed data constants
2. INSERT a new order into PostgreSQL → Debezium captures to `cdc.trading.orders`
3. Produce a correlated OrderEvent to `stream.order-events` (same order_id)
4. Wait 1-2 seconds
5. INSERT a trade for that order into PostgreSQL → Debezium captures to `cdc.trading.trades`
6. Produce a MarketDataTick for the traded instrument to `stream.market-data`
7. INSERT/UPDATE position for that account+instrument → Debezium captures to `cdc.trading.positions`

### Price Book

An in-memory dict of `ticker → last_price`, seeded from ConfigMap constants with realistic starting prices. Each trade jitters the price by +/- 0.5% to simulate market movement.

### Seed Data Constants (ConfigMap)

```json
{
  "instruments": [
    {"id": 1, "ticker": "AAPL", "start_price": 178.50},
    {"id": 2, "ticker": "MSFT", "start_price": 415.20},
    {"id": 3, "ticker": "GOOGL", "start_price": 141.80},
    {"id": 4, "ticker": "JPM", "start_price": 195.30},
    {"id": 5, "ticker": "GS", "start_price": 472.60},
    {"id": 6, "ticker": "BRK.B", "start_price": 408.90},
    {"id": 7, "ticker": "SPY", "start_price": 505.40},
    {"id": 8, "ticker": "AGG", "start_price": 98.20}
  ],
  "account_ids": [1, 2, 3, 4, 5]
}
```

## Project Structure

```
producer-api/
├── applicationset.yaml
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── configmap.yaml
├── overlays/
│   └── localdev/
│       ├── kustomization.yaml
│       └── deployment-patch.yaml
└── app/
    ├── Dockerfile
    ├── requirements.txt
    ├── main.py              # FastAPI app, lifespan, endpoints
    ├── models.py            # Pydantic models
    ├── producer.py          # KafkaEventProducer (aiokafka wrapper)
    ├── database.py          # asyncpg pool + INSERT functions
    ├── simulator.py         # Simulation loop orchestrator
    └── config.py            # Settings via environment variables
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| KAFKA_BOOTSTRAP_SERVERS | localhost:9092 | Kafka broker endpoint |
| POSTGRES_DSN | postgresql://postgres:postgres@localhost:5432/postgres | asyncpg connection string |
| SIMULATION_ENABLED | false | Enable background simulator |
| SIMULATION_INTERVAL_SECONDS | 5 | Seconds between simulation cycles |

## Error Handling

- **Kafka unavailable**: aiokafka retries with exponential backoff on startup. Mid-simulation failures log and skip the cycle.
- **PostgreSQL unavailable**: asyncpg pool reconnects automatically. API returns 503. Simulator logs and skips.
- **Validation errors**: FastAPI/Pydantic returns 422 with field-level details.

## Observability

Structured JSON logging with fields: `event_type`, `order_id`, `instrument_id`, `ticker`, `duration_ms`. Viewable via `kubectl logs`.

## Cross-Path Correlation

The `order_id` returned from the PostgreSQL INSERT is embedded in both the streaming OrderEvent and the subsequent trade INSERT. This creates a traceable link between the CDC path (`cdc.trading.orders` topic) and the streaming path (`stream.order-events` topic), visible in the Iceberg tables at query time.
