# Producer API Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a FastAPI service that exercises both CDC and streaming ingestion paths with a correlated trading simulator.

**Architecture:** Thin FastAPI service with asyncpg (PostgreSQL INSERTs → triggers Debezium CDC) and aiokafka (direct Kafka production to stream.* topics). Deployed via Kustomize + ArgoCD ApplicationSet, built via Tiltfile. Built-in simulator generates correlated trading sequences every N seconds.

**Tech Stack:** Python 3.11, FastAPI, uvicorn, aiokafka, asyncpg, Pydantic v2

**Design Doc:** `docs/plans/2026-02-28-producer-api-design.md`

---

## Phase 1: Python Application

### Task 1: Project scaffold and dependencies

**Files:**
- Create: `producer-api/app/requirements.txt`
- Create: `producer-api/app/config.py`
- Create: `producer-api/app/models.py`

**Step 1: Create requirements.txt**

```
fastapi==0.115.6
uvicorn[standard]==0.34.0
aiokafka==0.12.0
asyncpg==0.30.0
pydantic==2.10.4
```

**Step 2: Create config.py**

Settings class using Pydantic `BaseSettings` with env var bindings:

```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    kafka_bootstrap_servers: str = "localhost:9092"
    postgres_dsn: str = "postgresql://postgres:postgres@localhost:5432/trading"
    simulation_enabled: bool = False
    simulation_interval_seconds: float = 5.0

    class Config:
        env_prefix = ""
```

Note: Add `pydantic-settings` to requirements.txt as well.

**Step 3: Create models.py**

Two Pydantic models matching the design doc:

```python
from datetime import datetime
from decimal import Decimal
from pydantic import BaseModel

class OrderEvent(BaseModel):
    event_id: str
    event_type: str  # ORDER_SUBMITTED
    order_id: int
    account_id: int
    instrument_id: int
    ticker: str
    side: str
    quantity: Decimal
    limit_price: Decimal | None = None
    timestamp: datetime

class MarketDataTick(BaseModel):
    tick_id: str
    instrument_id: int
    ticker: str
    bid: Decimal
    ask: Decimal
    last_price: Decimal
    volume: int
    timestamp: datetime
```

**Step 4: Commit**

```bash
git add producer-api/app/
git commit -m "feat(producer-api): add project scaffold, config, and Pydantic models"
```

---

### Task 2: Database module (asyncpg)

**Files:**
- Create: `producer-api/app/database.py`

**Step 1: Create database.py**

Module with asyncpg pool management and INSERT functions for orders, trades, and positions. Must use parameterized queries (no SQL injection).

```python
import asyncpg
import logging
from datetime import date, timedelta
from decimal import Decimal

logger = logging.getLogger(__name__)

class TradingDatabase:
    def __init__(self, dsn: str):
        self._dsn = dsn
        self._pool: asyncpg.Pool | None = None

    async def connect(self):
        self._pool = await asyncpg.create_pool(self._dsn, min_size=1, max_size=5)
        logger.info("database_connected", extra={"dsn": self._dsn.split("@")[-1]})

    async def close(self):
        if self._pool:
            await self._pool.close()

    async def insert_order(
        self, account_id: int, instrument_id: int, side: str,
        quantity: Decimal, order_type: str, limit_price: Decimal | None,
        status: str = "PENDING", disclosure_status: str = "MNPI",
    ) -> int:
        """INSERT order and return the generated order_id."""
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                """INSERT INTO orders
                   (account_id, instrument_id, side, quantity, order_type, limit_price, status, disclosure_status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                   RETURNING order_id""",
                account_id, instrument_id, side, quantity, order_type, limit_price, status, disclosure_status,
            )
            return row["order_id"]

    async def insert_trade(
        self, order_id: int, instrument_id: int, quantity: Decimal,
        price: Decimal, venue: str = "NYSE", disclosure_status: str = "MNPI",
    ) -> int:
        """INSERT trade and return the generated trade_id."""
        settlement = date.today() + timedelta(days=2)
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                """INSERT INTO trades
                   (order_id, instrument_id, quantity, price, execution_venue, settlement_date, disclosure_status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7)
                   RETURNING trade_id""",
                order_id, instrument_id, quantity, price, venue, settlement, disclosure_status,
            )
            return row["trade_id"]

    async def upsert_position(
        self, account_id: int, instrument_id: int, quantity_delta: Decimal, price: Decimal,
    ):
        """UPSERT position: add quantity_delta to existing or create new."""
        async with self._pool.acquire() as conn:
            await conn.execute(
                """INSERT INTO positions (account_id, instrument_id, quantity, market_value, position_date)
                   VALUES ($1, $2, $3, $4, CURRENT_DATE)
                   ON CONFLICT (account_id, instrument_id, position_date)
                   DO UPDATE SET
                     quantity = positions.quantity + $3,
                     market_value = (positions.quantity + $3) * $4,
                     updated_at = NOW()""",
                account_id, instrument_id, quantity_delta, price,
            )
```

**Step 2: Commit**

```bash
git add producer-api/app/database.py
git commit -m "feat(producer-api): add asyncpg database module with order/trade/position INSERTs"
```

---

### Task 3: Kafka producer module (aiokafka)

**Files:**
- Create: `producer-api/app/producer.py`

**Step 1: Create producer.py**

Wrapper around aiokafka that serializes Pydantic models to JSON and produces to named topics.

```python
import json
import logging
from aiokafka import AIOKafkaProducer
from pydantic import BaseModel

logger = logging.getLogger(__name__)

class KafkaEventProducer:
    TOPIC_ORDER_EVENTS = "stream.order-events"
    TOPIC_MARKET_DATA = "stream.market-data"

    def __init__(self, bootstrap_servers: str):
        self._bootstrap = bootstrap_servers
        self._producer: AIOKafkaProducer | None = None

    async def start(self):
        self._producer = AIOKafkaProducer(
            bootstrap_servers=self._bootstrap,
            value_serializer=lambda v: json.dumps(v, default=str).encode("utf-8"),
        )
        await self._producer.start()
        logger.info("kafka_producer_started", extra={"bootstrap": self._bootstrap})

    async def stop(self):
        if self._producer:
            await self._producer.stop()

    async def send_order_event(self, event: BaseModel):
        await self._producer.send_and_wait(
            self.TOPIC_ORDER_EVENTS,
            value=event.model_dump(mode="json"),
        )
        logger.info("order_event_produced", extra={"topic": self.TOPIC_ORDER_EVENTS})

    async def send_market_data(self, tick: BaseModel):
        await self._producer.send_and_wait(
            self.TOPIC_MARKET_DATA,
            value=tick.model_dump(mode="json"),
        )
        logger.info("market_data_produced", extra={"topic": self.TOPIC_MARKET_DATA})
```

**Step 2: Commit**

```bash
git add producer-api/app/producer.py
git commit -m "feat(producer-api): add aiokafka producer module with JSON serialization"
```

---

### Task 4: Simulator module

**Files:**
- Create: `producer-api/app/simulator.py`

**Step 1: Create simulator.py**

The correlated trading simulation loop. References the design doc for the exact flow:

1. Pick random account + instrument from seed constants
2. INSERT order into PostgreSQL (CDC) + produce OrderEvent (streaming)
3. Wait 1-2s
4. INSERT trade (CDC) + produce MarketDataTick (streaming)
5. UPSERT position (CDC)

Seed data constants are loaded from a JSON file (mounted via ConfigMap). Price book is an in-memory dict with jitter.

```python
import asyncio
import json
import logging
import random
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

from .database import TradingDatabase
from .models import MarketDataTick, OrderEvent
from .producer import KafkaEventProducer

logger = logging.getLogger(__name__)

SEED_DATA_PATH = Path("/etc/producer-api/seed-data.json")

# Fallback seed data if ConfigMap not mounted (local dev outside k8s)
DEFAULT_INSTRUMENTS = [
    {"id": 1, "ticker": "AAPL", "start_price": 178.50},
    {"id": 2, "ticker": "MSFT", "start_price": 415.20},
    {"id": 3, "ticker": "GOOGL", "start_price": 141.80},
    {"id": 4, "ticker": "JPM", "start_price": 195.30},
    {"id": 5, "ticker": "GS", "start_price": 472.60},
    {"id": 6, "ticker": "BRK.B", "start_price": 408.90},
    {"id": 7, "ticker": "SPY", "start_price": 505.40},
    {"id": 8, "ticker": "AGG", "start_price": 98.20},
]
DEFAULT_ACCOUNT_IDS = [1, 2, 3, 4, 5]


class TradingSimulator:
    def __init__(
        self, db: TradingDatabase, kafka: KafkaEventProducer, interval: float = 5.0,
    ):
        self._db = db
        self._kafka = kafka
        self._interval = interval
        self._running = False
        self._instruments: list[dict] = []
        self._account_ids: list[int] = []
        self._price_book: dict[str, Decimal] = {}

    def _load_seed_data(self):
        if SEED_DATA_PATH.exists():
            data = json.loads(SEED_DATA_PATH.read_text())
            self._instruments = data["instruments"]
            self._account_ids = data["account_ids"]
        else:
            logger.warning("seed_data_not_found, using defaults")
            self._instruments = DEFAULT_INSTRUMENTS
            self._account_ids = DEFAULT_ACCOUNT_IDS

        self._price_book = {
            inst["ticker"]: Decimal(str(inst["start_price"]))
            for inst in self._instruments
        }

    def _jitter_price(self, ticker: str) -> Decimal:
        current = self._price_book[ticker]
        factor = Decimal(str(1 + random.uniform(-0.005, 0.005)))
        new_price = (current * factor).quantize(Decimal("0.01"))
        self._price_book[ticker] = new_price
        return new_price

    async def run(self):
        self._load_seed_data()
        self._running = True
        logger.info("simulator_started", extra={"interval": self._interval})

        while self._running:
            try:
                await self._run_cycle()
            except Exception:
                logger.exception("simulator_cycle_failed")
            await asyncio.sleep(self._interval)

    async def stop(self):
        self._running = False

    async def _run_cycle(self):
        instrument = random.choice(self._instruments)
        account_id = random.choice(self._account_ids)
        ticker = instrument["ticker"]
        instrument_id = instrument["id"]
        side = random.choice(["BUY", "SELL"])
        quantity = Decimal(str(random.randint(100, 5000)))
        price = self._jitter_price(ticker)
        order_type = random.choice(["MARKET", "LIMIT"])
        limit_price = price if order_type == "LIMIT" else None

        # 1. INSERT order into PostgreSQL (triggers CDC)
        order_id = await self._db.insert_order(
            account_id=account_id, instrument_id=instrument_id,
            side=side, quantity=quantity, order_type=order_type,
            limit_price=limit_price,
        )

        # 2. Produce correlated OrderEvent to streaming topic
        event = OrderEvent(
            event_id=str(uuid.uuid4()), event_type="ORDER_SUBMITTED",
            order_id=order_id, account_id=account_id,
            instrument_id=instrument_id, ticker=ticker,
            side=side, quantity=quantity, limit_price=limit_price,
            timestamp=datetime.now(timezone.utc),
        )
        await self._kafka.send_order_event(event)

        # 3. Wait to simulate execution latency
        await asyncio.sleep(random.uniform(1.0, 2.0))

        # 4. INSERT trade (triggers CDC)
        trade_price = self._jitter_price(ticker)
        await self._db.insert_trade(
            order_id=order_id, instrument_id=instrument_id,
            quantity=quantity, price=trade_price,
        )

        # 5. Update the order status to FILLED
        # (This UPDATE triggers a second CDC event on the orders table)
        async with self._db._pool.acquire() as conn:
            await conn.execute(
                "UPDATE orders SET status = 'FILLED', updated_at = NOW() WHERE order_id = $1",
                order_id,
            )

        # 6. Produce correlated MarketDataTick
        spread = (trade_price * Decimal("0.001")).quantize(Decimal("0.01"))
        tick = MarketDataTick(
            tick_id=str(uuid.uuid4()), instrument_id=instrument_id,
            ticker=ticker, bid=trade_price - spread,
            ask=trade_price + spread, last_price=trade_price,
            volume=int(quantity),
            timestamp=datetime.now(timezone.utc),
        )
        await self._kafka.send_market_data(tick)

        # 7. UPSERT position (triggers CDC)
        qty_delta = quantity if side == "BUY" else -quantity
        await self._db.upsert_position(account_id, instrument_id, qty_delta, trade_price)

        logger.info(
            "simulation_cycle_complete",
            extra={
                "order_id": order_id, "ticker": ticker,
                "side": side, "quantity": str(quantity),
                "price": str(trade_price),
            },
        )
```

**Step 2: Commit**

```bash
git add producer-api/app/simulator.py
git commit -m "feat(producer-api): add correlated trading simulator with dual-path ingestion"
```

---

### Task 5: FastAPI application (main.py)

**Files:**
- Create: `producer-api/app/main.py`

**Step 1: Create main.py**

FastAPI app with lifespan context manager for startup/shutdown of DB pool, Kafka producer, and simulator. Two POST endpoints + health check.

```python
import asyncio
import logging
import json
import sys
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException

from .config import Settings
from .database import TradingDatabase
from .models import MarketDataTick, OrderEvent
from .producer import KafkaEventProducer
from .simulator import TradingSimulator

# Structured JSON logging
logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}',
    stream=sys.stdout,
)
logger = logging.getLogger("producer-api")

settings = Settings()
db = TradingDatabase(settings.postgres_dsn)
kafka = KafkaEventProducer(settings.kafka_bootstrap_servers)
simulator = TradingSimulator(db, kafka, settings.simulation_interval_seconds)
_simulator_task: asyncio.Task | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    await db.connect()
    await kafka.start()
    global _simulator_task
    if settings.simulation_enabled:
        _simulator_task = asyncio.create_task(simulator.run())
        logger.info("simulator_enabled")
    yield
    # Shutdown
    await simulator.stop()
    if _simulator_task:
        _simulator_task.cancel()
    await kafka.stop()
    await db.close()


app = FastAPI(title="Producer API", version="1.0.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "healthy"}


@app.post("/api/v1/orders", status_code=201)
async def create_order(payload: dict):
    """INSERT order into PostgreSQL (CDC) and produce OrderEvent (streaming)."""
    try:
        order_id = await db.insert_order(
            account_id=payload["account_id"],
            instrument_id=payload["instrument_id"],
            side=payload["side"],
            quantity=payload["quantity"],
            order_type=payload.get("order_type", "MARKET"),
            limit_price=payload.get("limit_price"),
        )
        event = OrderEvent(
            event_id=str(uuid.uuid4()),
            event_type="ORDER_SUBMITTED",
            order_id=order_id,
            account_id=payload["account_id"],
            instrument_id=payload["instrument_id"],
            ticker=payload.get("ticker", "UNKNOWN"),
            side=payload["side"],
            quantity=payload["quantity"],
            limit_price=payload.get("limit_price"),
            timestamp=datetime.now(timezone.utc),
        )
        await kafka.send_order_event(event)
        return {"order_id": order_id, "event_id": event.event_id}
    except Exception as e:
        logger.exception("order_creation_failed")
        raise HTTPException(status_code=503, detail=str(e))


@app.post("/api/v1/market-data", status_code=201)
async def create_market_data(payload: MarketDataTick):
    """Produce MarketDataTick directly to Kafka (streaming only)."""
    try:
        await kafka.send_market_data(payload)
        return {"tick_id": payload.tick_id}
    except Exception as e:
        logger.exception("market_data_production_failed")
        raise HTTPException(status_code=503, detail=str(e))
```

**Step 2: Create `producer-api/app/__init__.py`**

Empty file to make the app a Python package.

```python
# producer-api/app/__init__.py
```

**Step 3: Commit**

```bash
git add producer-api/app/main.py producer-api/app/__init__.py
git commit -m "feat(producer-api): add FastAPI app with order and market-data endpoints"
```

---

## Phase 2: Container & Kubernetes

### Task 6: Dockerfile

**Files:**
- Create: `producer-api/app/Dockerfile`

**Step 1: Create Dockerfile**

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Note: The CMD uses `app.main:app` because the working dir is `/app` and the package is `app/`. We'll adjust the COPY and CMD path based on how the Docker context is set up. The build context will be `producer-api/app/` and the WORKDIR structure means we run `uvicorn main:app`.

Corrected Dockerfile:

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Wait — since the Python files use relative imports (e.g., `from .config import Settings`), the app needs to be a package. The correct approach:

Build context: `producer-api/` (not `producer-api/app/`)

```dockerfile
FROM python:3.11-slim

WORKDIR /srv

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Step 2: Verify the build locally**

```bash
cd producer-api && docker build -t producer-api:test -f app/Dockerfile . && echo "BUILD OK"
```

Wait — with the corrected Dockerfile above, the Dockerfile should be at `producer-api/Dockerfile` (not inside app/). Let me finalize:

**File:** `producer-api/Dockerfile`

```dockerfile
FROM python:3.11-slim

WORKDIR /srv

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Build command:**
```bash
cd producer-api && docker build -t producer-api:test . && echo "BUILD OK"
```

**Step 3: Commit**

```bash
git add producer-api/Dockerfile
git commit -m "feat(producer-api): add Dockerfile for FastAPI service"
```

---

### Task 7: Kubernetes manifests (Kustomize + ApplicationSet)

**Files:**
- Create: `producer-api/applicationset.yaml`
- Create: `producer-api/base/kustomization.yaml`
- Create: `producer-api/base/deployment.yaml`
- Create: `producer-api/base/service.yaml`
- Create: `producer-api/base/configmap.yaml`
- Create: `producer-api/overlays/localdev/kustomization.yaml`
- Create: `producer-api/overlays/localdev/deployment-patch.yaml`

**Reference:** Follow the exact same pattern as `sample-postgres/` for applicationset.yaml and kustomization structure. See `sample-postgres/applicationset.yaml` for the template.

**Step 1: Create applicationset.yaml**

Same pattern as sample-postgres: goTemplate, list generator with `cluster: localdev`, source pointing to `producer-api/overlays/{{ .cluster }}`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: producer-api
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          - cluster: localdev
  template:
    metadata:
      name: 'producer-api-{{ .cluster }}'
    spec:
      project: default
      source:
        repoURL: file:///mnt/data-lake-platform
        targetRevision: HEAD
        path: 'producer-api/overlays/{{ .cluster }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: data
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**Step 2: Create base/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
configMapGenerator:
  - name: producer-api-seed-data
    files:
      - seed-data.json
```

**Step 3: Create base/seed-data.json**

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

**Step 4: Create base/deployment.yaml**

Deployment with 1 replica. Mounts the seed-data ConfigMap. Environment variables for Kafka and Postgres are set to PLACEHOLDERs (overridden in overlays).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: producer-api
  labels:
    app: producer-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: producer-api
  template:
    metadata:
      labels:
        app: producer-api
    spec:
      containers:
        - name: producer-api
          image: producer-api:latest
          ports:
            - containerPort: 8000
          env:
            - name: KAFKA_BOOTSTRAP_SERVERS
              value: "PLACEHOLDER"
            - name: POSTGRES_DSN
              value: "PLACEHOLDER"
            - name: SIMULATION_ENABLED
              value: "false"
            - name: SIMULATION_INTERVAL_SECONDS
              value: "5"
          volumeMounts:
            - name: seed-data
              mountPath: /etc/producer-api
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: seed-data
          configMap:
            name: producer-api-seed-data
```

**Step 5: Create base/service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: producer-api
spec:
  selector:
    app: producer-api
  ports:
    - port: 8000
      targetPort: 8000
  type: ClusterIP
```

**Step 6: Create overlays/localdev/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: data
resources:
  - ../../base
patches:
  - path: deployment-patch.yaml
```

**Step 7: Create overlays/localdev/deployment-patch.yaml**

Patches environment variables to point to local Kind services. Enables the simulator.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: producer-api
spec:
  template:
    spec:
      containers:
        - name: producer-api
          env:
            - name: KAFKA_BOOTSTRAP_SERVERS
              value: "data-lake-cluster-kafka-bootstrap.strimzi.svc.cluster.local:9092"
            - name: POSTGRES_DSN
              value: "postgresql://postgres:postgres@sample-postgres.data.svc.cluster.local:5432/trading"
            - name: SIMULATION_ENABLED
              value: "true"
            - name: SIMULATION_INTERVAL_SECONDS
              value: "5"
```

**Step 8: Commit**

```bash
git add producer-api/applicationset.yaml producer-api/base/ producer-api/overlays/
git commit -m "feat(producer-api): add Kustomize manifests and ArgoCD ApplicationSet"
```

---

### Task 8: Tiltfile update

**Files:**
- Modify: `Tiltfile`

**Step 1: Add producer-api build resource and watch**

Add a `local_resource` for building the Docker image, loading it into Kind, and a `watch_file` for the manifests. Follow the pattern from the design doc — use `TRIGGER_MODE_MANUAL` to prevent runaway builds.

Add to the Tiltfile after the existing watch_file lines:

```python
watch_file('producer-api/')

# Producer API build (manual trigger)
local_resource(
    'producer-api-build',
    cmd='TAG=localdev-$(date +%s) && ' +
        'docker build -t producer-api:$TAG producer-api/ && ' +
        'kind load docker-image producer-api:$TAG --name data-lake && ' +
        'cd producer-api/overlays/localdev && ' +
        'kustomize edit set image producer-api=producer-api:$TAG',
    deps=[
        'producer-api/app/',
        'producer-api/Dockerfile',
    ],
    labels=['build'],
    trigger_mode=TRIGGER_MODE_MANUAL,
)
```

Also add a utility resource to view producer-api logs:

```python
local_resource(
    'producer-api-logs',
    cmd='kubectl -n data logs -l app=producer-api --tail=50 2>/dev/null || echo "No producer-api pods"',
    labels=['info'],
    auto_init=False,
    trigger_mode=TRIGGER_MODE_MANUAL,
)
```

**Step 2: Commit**

```bash
git add Tiltfile
git commit -m "feat(producer-api): add Tilt build resource and log viewer"
```

---

### Task 9: Update documentation

**Files:**
- Modify: `docs/documentation.md` — Add a "Producer API" section describing the service, its endpoints, how to trigger simulation, and how to view logs.
- Modify: `docs/architecture-diagram.md` — Add producer-api to diagram 1 (E2E Data Flow) showing it connecting to both PostgreSQL and Kafka.
- Modify: `README.md` — Add producer-api to the project structure section.

**Step 1: Add Producer API section to documentation.md**

Add after the existing content, a new section covering:
- Service overview
- REST endpoints with curl examples
- Simulation mode
- Viewing logs with kubectl

**Step 2: Update architecture diagram**

Add a `PRODUCER` subgraph/node to diagram 1 showing:
- `producer-api` connecting to `sample-postgres` (INSERT → CDC)
- `producer-api` connecting to `stream.order-events` and `stream.market-data` (direct produce)

**Step 3: Update README project structure**

Add `producer-api/` to the directory listing.

**Step 4: Commit**

```bash
git add docs/documentation.md docs/architecture-diagram.md README.md
git commit -m "docs: add producer-api to documentation, architecture diagram, and README"
```
