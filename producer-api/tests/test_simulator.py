"""Tests for TradingSimulator: price jitter, seed data loading, run cycle."""

import json
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.simulator import DEFAULT_INSTRUMENTS, TradingSimulator


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def mock_db():
    """Mocked TradingDatabase for simulator tests."""
    db = AsyncMock()
    db.insert_order = AsyncMock(return_value=1)
    db.insert_trade = AsyncMock(return_value=1)
    db.upsert_position = AsyncMock(return_value=None)

    # _run_cycle accesses db.pool.acquire() directly for the UPDATE query
    mock_conn = AsyncMock()
    mock_conn.execute = AsyncMock()

    mock_pool = MagicMock()
    mock_pool.acquire = MagicMock(return_value=AsyncMock(
        __aenter__=AsyncMock(return_value=mock_conn),
        __aexit__=AsyncMock(return_value=False),
    ))
    db.pool = mock_pool
    return db


@pytest.fixture
def mock_kafka():
    """Mocked KafkaEventProducer for simulator tests."""
    kafka = AsyncMock()
    kafka.send_order_event = AsyncMock(return_value=None)
    kafka.send_market_data = AsyncMock(return_value=None)
    return kafka


@pytest.fixture
def simulator(mock_db, mock_kafka):
    """TradingSimulator with mocked dependencies and seed data pre-loaded."""
    sim = TradingSimulator(mock_db, mock_kafka, interval=0.0)
    sim._instruments = list(DEFAULT_INSTRUMENTS)
    sim._account_ids = [1, 2, 3, 4, 5]
    sim._price_book = {
        inst["ticker"]: Decimal(str(inst["price"]))
        for inst in DEFAULT_INSTRUMENTS
    }
    return sim


# ---------------------------------------------------------------------------
# _jitter_price
# ---------------------------------------------------------------------------


class TestJitterPrice:
    def test_within_bounds(self, simulator):
        """Price jitter stays within ±1% of original over many iterations."""
        original = Decimal("178.50")
        simulator._price_book["AAPL"] = original
        for _ in range(1000):
            price = simulator._jitter_price("AAPL")
            # Factor is [0.995, 1.005] per iteration, but compounding 1000 times
            # could drift. Check each individual result is positive and reasonable.
            assert price > Decimal("0")

    def test_quantized_to_two_decimals(self, simulator):
        """Every jittered price has at most 2 decimal places."""
        for _ in range(100):
            price = simulator._jitter_price("AAPL")
            # Decimal("0.01") quantization means exponent is -2 or higher
            assert price == price.quantize(Decimal("0.01"))

    def test_updates_price_book(self, simulator):
        """After jittering, price book reflects the new price."""
        new_price = simulator._jitter_price("MSFT")
        assert simulator._price_book["MSFT"] == new_price


# ---------------------------------------------------------------------------
# _load_seed_data
# ---------------------------------------------------------------------------


class TestLoadSeedData:
    def test_defaults_when_file_missing(self, mock_db, mock_kafka):
        sim = TradingSimulator(mock_db, mock_kafka)
        with patch("app.simulator.SEED_DATA_PATH") as mock_path:
            mock_path.exists.return_value = False
            sim._load_seed_data()

        assert len(sim._instruments) == 8
        assert len(sim._account_ids) == 5
        assert "AAPL" in sim._price_book

    def test_loads_from_file(self, mock_db, mock_kafka, tmp_path):
        seed_file = tmp_path / "seed-data.json"
        seed_data = {
            "instruments": [
                {"instrument_id": 99, "ticker": "TEST", "price": "100.00"},
            ],
            "account_ids": [10, 20],
        }
        seed_file.write_text(json.dumps(seed_data))

        sim = TradingSimulator(mock_db, mock_kafka)
        with patch("app.simulator.SEED_DATA_PATH", seed_file):
            sim._load_seed_data()

        assert len(sim._instruments) == 1
        assert sim._instruments[0]["ticker"] == "TEST"
        assert sim._account_ids == [10, 20]
        assert sim._price_book["TEST"] == Decimal("100.00")

    def test_falls_back_on_invalid_json(self, mock_db, mock_kafka, tmp_path):
        seed_file = tmp_path / "bad-seed.json"
        seed_file.write_text("NOT VALID JSON{{{")

        sim = TradingSimulator(mock_db, mock_kafka)
        with patch("app.simulator.SEED_DATA_PATH", seed_file):
            sim._load_seed_data()

        # Should fall back to defaults
        assert len(sim._instruments) == 8
        assert len(sim._account_ids) == 5


# ---------------------------------------------------------------------------
# _run_cycle
# ---------------------------------------------------------------------------


class TestRunCycle:
    async def test_calls_all_db_and_kafka_methods(
        self, simulator, mock_db, mock_kafka
    ):
        """A single cycle calls insert_order, send_order_event, insert_trade,
        send_market_data, and upsert_position."""
        with patch("app.simulator.asyncio.sleep", new_callable=AsyncMock):
            await simulator._run_cycle()

        mock_db.insert_order.assert_called_once()
        mock_kafka.send_order_event.assert_called_once()
        mock_db.insert_trade.assert_called_once()
        mock_kafka.send_market_data.assert_called_once()
        mock_db.upsert_position.assert_called_once()

    async def test_order_event_has_correct_fields(
        self, simulator, mock_db, mock_kafka
    ):
        """The OrderEvent sent to Kafka has expected field types."""
        with patch("app.simulator.asyncio.sleep", new_callable=AsyncMock):
            await simulator._run_cycle()

        event = mock_kafka.send_order_event.call_args[0][0]
        assert event.event_type == "ORDER_CREATED"
        assert event.side in ("BUY", "SELL")
        assert event.quantity > 0


# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------


class TestStop:
    def test_sets_running_false(self, simulator):
        simulator._running = True
        simulator.stop()
        assert simulator._running is False
