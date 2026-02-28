"""Tests for Pydantic models: OrderEvent and MarketDataTick."""

import json
from datetime import datetime, timezone
from decimal import Decimal

import pytest
from pydantic import ValidationError

from app.models import MarketDataTick, OrderEvent


# ---------------------------------------------------------------------------
# OrderEvent
# ---------------------------------------------------------------------------


class TestOrderEvent:
    def test_valid_construction(self):
        event = OrderEvent(
            event_id="evt-001",
            event_type="ORDER_CREATED",
            order_id=1,
            account_id=1,
            instrument_id=1,
            ticker="AAPL",
            side="BUY",
            quantity=Decimal("100"),
            timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
        )
        assert event.event_id == "evt-001"
        assert event.order_id == 1
        assert event.quantity == Decimal("100")

    def test_json_round_trip(self):
        event = OrderEvent(
            event_id="evt-002",
            event_type="ORDER_CREATED",
            order_id=2,
            account_id=1,
            instrument_id=1,
            ticker="MSFT",
            side="SELL",
            quantity=Decimal("500"),
            timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
        )
        json_str = event.model_dump_json()
        parsed = json.loads(json_str)
        assert parsed["event_id"] == "evt-002"
        assert parsed["ticker"] == "MSFT"
        assert parsed["side"] == "SELL"

    def test_with_limit_price(self):
        event = OrderEvent(
            event_id="evt-003",
            event_type="ORDER_CREATED",
            order_id=3,
            account_id=1,
            instrument_id=1,
            ticker="GOOGL",
            side="BUY",
            quantity=Decimal("200"),
            limit_price=Decimal("141.80"),
            timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
        )
        assert event.limit_price == Decimal("141.80")
        dumped = event.model_dump(mode="json")
        assert dumped["limit_price"] is not None

    def test_without_limit_price(self):
        event = OrderEvent(
            event_id="evt-004",
            event_type="ORDER_CREATED",
            order_id=4,
            account_id=1,
            instrument_id=1,
            ticker="JPM",
            side="BUY",
            quantity=Decimal("100"),
            timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
        )
        assert event.limit_price is None

    def test_decimal_serialization_json_mode(self):
        event = OrderEvent(
            event_id="evt-005",
            event_type="ORDER_CREATED",
            order_id=5,
            account_id=1,
            instrument_id=1,
            ticker="GS",
            side="BUY",
            quantity=Decimal("1500.50"),
            limit_price=Decimal("472.60"),
            timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
        )
        dumped = event.model_dump(mode="json")
        # In JSON mode, Pydantic serializes Decimal as string
        assert isinstance(dumped["quantity"], str)
        assert dumped["quantity"] == "1500.50"
        assert dumped["limit_price"] == "472.60"

    def test_rejects_missing_required_field(self):
        with pytest.raises(ValidationError):
            OrderEvent(
                # Missing event_id
                event_type="ORDER_CREATED",
                order_id=1,
                account_id=1,
                instrument_id=1,
                ticker="AAPL",
                side="BUY",
                quantity=Decimal("100"),
                timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
            )


# ---------------------------------------------------------------------------
# MarketDataTick
# ---------------------------------------------------------------------------


class TestMarketDataTick:
    def test_valid_construction(self):
        tick = MarketDataTick(
            tick_id="tick-001",
            instrument_id=1,
            ticker="AAPL",
            bid=Decimal("178.40"),
            ask=Decimal("178.60"),
            last_price=Decimal("178.50"),
            volume=1000,
            timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
        )
        assert tick.tick_id == "tick-001"
        assert tick.bid == Decimal("178.40")
        assert tick.volume == 1000

    def test_json_round_trip(self):
        tick = MarketDataTick(
            tick_id="tick-002",
            instrument_id=2,
            ticker="MSFT",
            bid=Decimal("415.00"),
            ask=Decimal("415.40"),
            last_price=Decimal("415.20"),
            volume=5000,
            timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
        )
        json_str = tick.model_dump_json()
        parsed = json.loads(json_str)
        assert parsed["tick_id"] == "tick-002"
        assert parsed["ticker"] == "MSFT"
        assert parsed["volume"] == 5000

    def test_decimal_fields_serialization(self):
        tick = MarketDataTick(
            tick_id="tick-003",
            instrument_id=3,
            ticker="GOOGL",
            bid=Decimal("141.70"),
            ask=Decimal("141.90"),
            last_price=Decimal("141.80"),
            volume=2000,
            timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
        )
        dumped = tick.model_dump(mode="json")
        assert isinstance(dumped["bid"], str)
        assert dumped["bid"] == "141.70"
        assert dumped["ask"] == "141.90"
        assert dumped["last_price"] == "141.80"

    def test_rejects_missing_required_field(self):
        with pytest.raises(ValidationError):
            MarketDataTick(
                tick_id="tick-004",
                instrument_id=1,
                # Missing ticker
                bid=Decimal("178.40"),
                ask=Decimal("178.60"),
                last_price=Decimal("178.50"),
                volume=1000,
                timestamp=datetime(2026, 2, 28, 12, 0, 0, tzinfo=timezone.utc),
            )
