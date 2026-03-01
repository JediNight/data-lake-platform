"""Tests for FastAPI endpoints: /health, /api/v1/orders, /api/v1/market-data."""

from decimal import Decimal

import pytest


# ---------------------------------------------------------------------------
# GET /health
# ---------------------------------------------------------------------------


async def test_health(client):
    resp = await client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "healthy"}


# ---------------------------------------------------------------------------
# POST /api/v1/orders
# ---------------------------------------------------------------------------


async def test_create_order_success(client, mock_db, sample_order_payload):
    resp = await client.post("/api/v1/orders", json=sample_order_payload)
    assert resp.status_code == 200

    body = resp.json()
    assert body["order_id"] == 42  # mock_db.insert_order returns 42
    assert "event_id" not in body  # CDC captures changes; no Kafka dual-write

    mock_db.insert_order.assert_called_once()


async def test_create_order_with_limit_price(client, mock_db, mock_kafka):
    payload = {
        "account_id": 1,
        "instrument_id": 3,
        "ticker": "GOOGL",
        "side": "BUY",
        "quantity": "200",
        "order_type": "LIMIT",
        "limit_price": "141.80",
    }
    resp = await client.post("/api/v1/orders", json=payload)
    assert resp.status_code == 200

    # Verify limit_price was passed as Decimal to db.insert_order
    call_kwargs = mock_db.insert_order.call_args
    assert call_kwargs.kwargs["limit_price"] == Decimal("141.80")


async def test_create_order_missing_field_returns_503(client, mock_db):
    """Missing required key (account_id) raises KeyError → caught → 503."""
    payload = {"instrument_id": 1, "side": "BUY", "quantity": "100"}
    resp = await client.post("/api/v1/orders", json=payload)
    assert resp.status_code == 503


async def test_create_order_db_failure_returns_503(
    client, mock_db, mock_kafka, sample_order_payload
):
    mock_db.insert_order.side_effect = Exception("DB connection lost")
    resp = await client.post("/api/v1/orders", json=sample_order_payload)
    assert resp.status_code == 503
    assert "DB connection lost" in resp.json()["detail"]


# ---------------------------------------------------------------------------
# POST /api/v1/market-data
# ---------------------------------------------------------------------------


async def test_publish_market_data_success(
    client, mock_kafka, sample_market_tick_payload
):
    resp = await client.post("/api/v1/market-data", json=sample_market_tick_payload)
    assert resp.status_code == 200
    assert resp.json()["tick_id"] == "test-tick-001"
    mock_kafka.send_market_data.assert_called_once()


async def test_publish_market_data_invalid_payload(client):
    """Missing required fields triggers Pydantic validation → 422."""
    resp = await client.post("/api/v1/market-data", json={"tick_id": "bad"})
    assert resp.status_code == 422


async def test_publish_market_data_kafka_failure(
    client, mock_kafka, sample_market_tick_payload
):
    mock_kafka.send_market_data.side_effect = Exception("Kafka unavailable")
    resp = await client.post("/api/v1/market-data", json=sample_market_tick_payload)
    assert resp.status_code == 503
    assert "Kafka unavailable" in resp.json()["detail"]
