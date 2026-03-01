"""Tests for Alpaca adapter transform functions (no API key needed)."""

from decimal import Decimal

import pytest

from alpaca_adapter.transforms import (
    INSTRUMENT_MAP,
    alpaca_quote_to_market_tick,
    alpaca_trade_to_order_event,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def sample_quote():
    return {
        "T": "q",
        "S": "AAPL",
        "bp": 178.40,
        "ap": 178.60,
        "bs": 100,
        "as": 200,
        "t": "2026-02-28T15:30:00Z",
    }


@pytest.fixture
def sample_trade():
    return {
        "T": "t",
        "S": "AAPL",
        "p": 178.50,
        "s": 500,
        "i": 96921,
        "t": "2026-02-28T15:30:01Z",
    }


# ---------------------------------------------------------------------------
# alpaca_quote_to_market_tick
# ---------------------------------------------------------------------------


class TestQuoteToMarketTick:
    def test_valid_quote(self, sample_quote):
        tick = alpaca_quote_to_market_tick(sample_quote)
        assert tick is not None
        assert tick.ticker == "AAPL"
        assert tick.bid == Decimal("178.40")
        assert tick.ask == Decimal("178.60")
        assert tick.volume == 300  # bs(100) + as(200)

    def test_midpoint_price(self, sample_quote):
        tick = alpaca_quote_to_market_tick(sample_quote)
        assert tick is not None
        # (178.40 + 178.60) / 2 = 178.50
        assert tick.last_price == Decimal("178.50")
        # Quantized to 2 decimal places
        assert tick.last_price == tick.last_price.quantize(Decimal("0.01"))

    def test_unknown_symbol_returns_none(self):
        quote = {
            "T": "q",
            "S": "UNKNOWN",
            "bp": 100.0,
            "ap": 101.0,
            "bs": 10,
            "as": 20,
            "t": "2026-02-28T15:30:00Z",
        }
        assert alpaca_quote_to_market_tick(quote) is None

    def test_instrument_id_mapping(self):
        for ticker, expected_id in INSTRUMENT_MAP.items():
            quote = {
                "T": "q",
                "S": ticker,
                "bp": 100.0,
                "ap": 101.0,
                "bs": 10,
                "as": 20,
                "t": "2026-02-28T15:30:00Z",
            }
            tick = alpaca_quote_to_market_tick(quote)
            assert tick is not None
            assert tick.instrument_id == expected_id


# ---------------------------------------------------------------------------
# alpaca_trade_to_order_event
# ---------------------------------------------------------------------------


class TestTradeToOrderEvent:
    def test_valid_trade(self, sample_trade):
        event = alpaca_trade_to_order_event(sample_trade, account_id=1)
        assert event is not None
        assert event.ticker == "AAPL"
        assert event.limit_price == Decimal("178.50")
        assert event.quantity == Decimal("500")
        assert event.event_type == "ORDER_CREATED"
        assert event.order_id == 96921

    def test_unknown_symbol_returns_none(self):
        trade = {
            "T": "t",
            "S": "UNKNOWN",
            "p": 50.0,
            "s": 100,
            "i": 1234,
            "t": "2026-02-28T15:30:01Z",
        }
        assert alpaca_trade_to_order_event(trade, account_id=1) is None

    def test_side_is_random(self, sample_trade):
        """Over 100 runs, both BUY and SELL should appear."""
        sides = set()
        for _ in range(100):
            event = alpaca_trade_to_order_event(sample_trade, account_id=1)
            assert event is not None
            sides.add(event.side)
        assert sides == {"BUY", "SELL"}

    def test_account_id_passthrough(self, sample_trade):
        event = alpaca_trade_to_order_event(sample_trade, account_id=42)
        assert event is not None
        assert event.account_id == 42
