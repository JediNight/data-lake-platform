"""FastAPI application for the Producer API."""

import asyncio
import logging
import sys
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from fastapi import FastAPI, HTTPException

from .config import Settings
from .database import TradingDatabase
from .models import MarketDataTick, OrderEvent
from .producer import KafkaEventProducer
from .simulator import TradingSimulator

# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format='{"timestamp":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}',
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Module-level instances
# ---------------------------------------------------------------------------
settings = Settings()
db = TradingDatabase(settings.postgres_dsn)
kafka = KafkaEventProducer(settings.kafka_bootstrap_servers)
simulator = TradingSimulator(db, kafka, settings.simulation_interval_seconds)

# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------
_simulator_task: asyncio.Task[None] | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: ARG001
    """Manage startup and shutdown of background services."""
    global _simulator_task

    # --- Startup ---
    await db.connect()
    await kafka.start()

    if settings.simulation_enabled:
        _simulator_task = asyncio.create_task(simulator.run())
        logger.info("Simulator background task created")

    yield

    # --- Shutdown ---
    simulator.stop()

    if _simulator_task is not None:
        _simulator_task.cancel()
        try:
            await _simulator_task
        except asyncio.CancelledError:
            pass

    await kafka.stop()
    await db.close()


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(title="Producer API", version="1.0.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
async def health() -> dict[str, str]:
    """Liveness/readiness probe."""
    return {"status": "healthy"}


@app.post("/api/v1/orders")
async def create_order(payload: dict[str, Any]) -> dict[str, Any]:
    """Accept an order, persist it to PostgreSQL, and publish an OrderEvent to Kafka."""
    try:
        order_id = await db.insert_order(
            account_id=int(payload["account_id"]),
            instrument_id=int(payload["instrument_id"]),
            side=str(payload["side"]),
            quantity=Decimal(str(payload["quantity"])),
            order_type=str(payload.get("order_type", "MARKET")),
            limit_price=(
                Decimal(str(payload["limit_price"]))
                if payload.get("limit_price") is not None
                else None
            ),
        )

        event = OrderEvent(
            event_id=str(uuid.uuid4()),
            event_type="ORDER_CREATED",
            order_id=order_id,
            account_id=int(payload["account_id"]),
            instrument_id=int(payload["instrument_id"]),
            ticker=str(payload.get("ticker", "")),
            side=str(payload["side"]),
            quantity=Decimal(str(payload["quantity"])),
            limit_price=(
                Decimal(str(payload["limit_price"]))
                if payload.get("limit_price") is not None
                else None
            ),
            timestamp=datetime.now(timezone.utc),
        )
        await kafka.send_order_event(event)

        return {"order_id": order_id, "event_id": event.event_id}

    except Exception as exc:
        logger.exception("Failed to create order")
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/api/v1/market-data")
async def publish_market_data(payload: MarketDataTick) -> dict[str, str]:
    """Publish a market-data tick to Kafka."""
    try:
        await kafka.send_market_data(payload)
        return {"tick_id": payload.tick_id}

    except Exception as exc:
        logger.exception("Failed to publish market data")
        raise HTTPException(status_code=503, detail=str(exc)) from exc
