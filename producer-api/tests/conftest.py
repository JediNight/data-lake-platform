"""Shared fixtures for producer-api tests."""

from datetime import datetime, timezone
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient


@pytest.fixture
def mock_db():
    """AsyncMock of TradingDatabase with preset return values."""
    db = AsyncMock()
    db.insert_order = AsyncMock(return_value=42)
    db.insert_trade = AsyncMock(return_value=100)
    db.upsert_position = AsyncMock(return_value=None)
    db.connect = AsyncMock()
    db.close = AsyncMock()
    return db


@pytest.fixture
def mock_kafka():
    """AsyncMock of KafkaEventProducer with preset return values."""
    kafka = AsyncMock()
    kafka.send_order_event = AsyncMock(return_value=None)
    kafka.send_market_data = AsyncMock(return_value=None)
    kafka.start = AsyncMock()
    kafka.stop = AsyncMock()
    return kafka


@pytest_asyncio.fixture
async def client(mock_db, mock_kafka, monkeypatch):
    """Async httpx client with mocked db and kafka."""
    # Patch module-level singletons BEFORE the app handles requests
    monkeypatch.setattr("app.main.db", mock_db)
    monkeypatch.setattr("app.main.kafka", mock_kafka)
    monkeypatch.setattr("app.main.settings", MagicMock(simulation_enabled=False))

    from app.main import app

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture
def sample_order_payload():
    """Valid order payload for POST /api/v1/orders."""
    return {
        "account_id": 1,
        "instrument_id": 1,
        "ticker": "AAPL",
        "side": "BUY",
        "quantity": "100",
        "order_type": "MARKET",
    }


@pytest.fixture
def sample_market_tick_payload():
    """Valid market data tick payload for POST /api/v1/market-data."""
    return {
        "tick_id": "test-tick-001",
        "instrument_id": 1,
        "ticker": "AAPL",
        "bid": "178.40",
        "ask": "178.60",
        "last_price": "178.50",
        "volume": 1000,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
