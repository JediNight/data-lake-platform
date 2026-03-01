"""Trading simulator that exercises CDC (orders via DB) and streaming (market data via Kafka)."""

import asyncio
import json
import logging
import random
import uuid
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

from .database import TradingDatabase
from .models import MarketDataTick
from .producer import KafkaEventProducer

logger = logging.getLogger(__name__)

SEED_DATA_PATH = Path("/etc/producer-api/seed-data.json")

DEFAULT_INSTRUMENTS: list[dict] = [
    {"instrument_id": 1, "ticker": "AAPL", "price": "178.50"},
    {"instrument_id": 2, "ticker": "MSFT", "price": "415.20"},
    {"instrument_id": 3, "ticker": "GOOGL", "price": "141.80"},
    {"instrument_id": 4, "ticker": "JPM", "price": "195.30"},
    {"instrument_id": 5, "ticker": "GS", "price": "472.60"},
    {"instrument_id": 6, "ticker": "BRK.B", "price": "408.90"},
    {"instrument_id": 7, "ticker": "SPY", "price": "505.40"},
    {"instrument_id": 8, "ticker": "AGG", "price": "98.20"},
]

DEFAULT_ACCOUNT_IDS: list[int] = [1, 2, 3, 4, 5]


class TradingSimulator:
    """Generates correlated trading activity across postgres (CDC) and Kafka (streaming).

    Each simulation cycle creates a complete trade lifecycle:
    order INSERT (CDC captures change) -> trade INSERT -> order UPDATE (FILLED)
    -> Kafka market-data tick -> position UPSERT.
    """

    def __init__(
        self,
        db: TradingDatabase,
        kafka: KafkaEventProducer,
        interval: float = 5.0,
    ) -> None:
        self._db = db
        self._kafka = kafka
        self._interval = interval
        self._running = False

        # In-memory price book: ticker -> last_price
        self._price_book: dict[str, Decimal] = {}

        # Seed data (populated by _load_seed_data)
        self._instruments: list[dict] = []
        self._account_ids: list[int] = []

    def _load_seed_data(self) -> None:
        """Load seed data from ConfigMap mount, falling back to hardcoded defaults."""
        if SEED_DATA_PATH.exists():
            try:
                raw = json.loads(SEED_DATA_PATH.read_text())
                self._instruments = raw.get("instruments", DEFAULT_INSTRUMENTS)
                self._account_ids = raw.get("account_ids", DEFAULT_ACCOUNT_IDS)
                logger.info(
                    "Loaded seed data from %s: %d instruments, %d accounts",
                    SEED_DATA_PATH,
                    len(self._instruments),
                    len(self._account_ids),
                )
            except (json.JSONDecodeError, KeyError) as exc:
                logger.warning(
                    "Failed to parse %s (%s), using defaults", SEED_DATA_PATH, exc
                )
                self._instruments = DEFAULT_INSTRUMENTS
                self._account_ids = DEFAULT_ACCOUNT_IDS
        else:
            logger.info(
                "Seed data file %s not found, using hardcoded defaults", SEED_DATA_PATH
            )
            self._instruments = DEFAULT_INSTRUMENTS
            self._account_ids = DEFAULT_ACCOUNT_IDS

        # Initialise the in-memory price book from seed instruments
        self._price_book = {
            inst["ticker"]: Decimal(str(inst["price"]))
            for inst in self._instruments
        }

    def _jitter_price(self, ticker: str) -> Decimal:
        """Apply a small random jitter to the current price and update the book.

        Multiplies the current price by a random factor in [0.995, 1.005] and
        quantises the result to 2 decimal places.
        """
        current = self._price_book[ticker]
        factor = Decimal(str(random.uniform(0.995, 1.005)))
        new_price = (current * factor).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        self._price_book[ticker] = new_price
        return new_price

    async def _run_cycle(self) -> None:
        """Execute one complete trading cycle across CDC and streaming paths."""
        # --- Step 1: Pick random parameters ---
        account_id = random.choice(self._account_ids)
        instrument = random.choice(self._instruments)
        instrument_id: int = instrument["instrument_id"]
        ticker: str = instrument["ticker"]

        # --- Step 2: Random order attributes ---
        side = random.choice(["BUY", "SELL"])
        quantity = Decimal(str(random.randint(100, 5000)))
        order_type = random.choice(["MARKET", "LIMIT"])

        limit_price: Decimal | None = None
        if order_type == "LIMIT":
            limit_price = self._jitter_price(ticker)

        # --- Step 3: INSERT order into postgres (CDC captures the change) ---
        order_id = await self._db.insert_order(
            account_id=account_id,
            instrument_id=instrument_id,
            side=side,
            quantity=quantity,
            order_type=order_type,
            limit_price=limit_price,
        )

        logger.info(
            "Cycle: order_id=%d %s %s %s qty=%s account=%d (cross-path correlated)",
            order_id,
            ticker,
            side,
            order_type,
            quantity,
            account_id,
        )

        # --- Step 4: Simulate execution latency ---
        await asyncio.sleep(random.uniform(1.0, 2.0))

        # --- Step 5: Jitter price and INSERT trade ---
        execution_price = self._jitter_price(ticker)
        trade_id = await self._db.insert_trade(
            order_id=order_id,
            instrument_id=instrument_id,
            quantity=quantity,
            price=execution_price,
        )

        # --- Step 6: UPDATE order status to FILLED ---
        assert self._db.pool is not None, "Database pool is not initialized"
        async with self._db.pool.acquire() as conn:
            await conn.execute(
                "UPDATE orders SET status = 'FILLED', updated_at = NOW() WHERE order_id = $1",
                order_id,
            )
        logger.info("Order %d marked FILLED at price %s (trade %d)", order_id, execution_price, trade_id)

        # --- Step 7: Produce MarketDataTick to Kafka ---
        spread = execution_price * Decimal("0.001")
        bid = (execution_price - spread).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        ask = (execution_price + spread).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

        market_tick = MarketDataTick(
            tick_id=str(uuid.uuid4()),
            instrument_id=instrument_id,
            ticker=ticker,
            bid=bid,
            ask=ask,
            last_price=execution_price,
            volume=int(quantity),
            timestamp=datetime.now(timezone.utc),
        )
        await self._kafka.send_market_data(market_tick)

        # --- Step 8: UPSERT position ---
        qty_delta = quantity if side == "BUY" else -quantity
        await self._db.upsert_position(
            account_id=account_id,
            instrument_id=instrument_id,
            quantity_delta=qty_delta,
            price=execution_price,
        )

    async def run(self) -> None:
        """Main simulation loop: load seed data, then run cycles forever."""
        self._load_seed_data()
        self._running = True
        logger.info(
            "Trading simulator started (interval=%.1fs, instruments=%d, accounts=%d)",
            self._interval,
            len(self._instruments),
            len(self._account_ids),
        )

        while self._running:
            try:
                await self._run_cycle()
            except Exception:
                logger.exception("Error in simulation cycle")

            await asyncio.sleep(self._interval)

        logger.info("Trading simulator stopped")

    def stop(self) -> None:
        """Signal the simulation loop to exit after the current cycle."""
        self._running = False
        logger.info("Trading simulator stop requested")
