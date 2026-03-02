"""Synchronous trading simulator for AWS Lambda.

Port of the async 8-step trading cycle from producer-api/app/simulator.py.
Each invocation runs exactly one cycle (no loop, no sleep).
"""

import random
import uuid
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal

from aws_lambda_powertools import Logger

from database import TradingDatabase
from producer import MSKProducer

logger = Logger(child=True)

# Hardcoded instruments matching the init-aurora-cdc.sh seed data.
# instrument_id values correspond to SERIAL insertion order in the seed SQL.
INSTRUMENTS: list[dict] = [
    {"instrument_id": 1, "ticker": "AAPL", "price": "178.50"},
    {"instrument_id": 2, "ticker": "MSFT", "price": "415.20"},
    {"instrument_id": 3, "ticker": "GOOGL", "price": "141.80"},
    {"instrument_id": 4, "ticker": "AMZN", "price": "185.60"},
    {"instrument_id": 5, "ticker": "JPM", "price": "195.30"},
    {"instrument_id": 6, "ticker": "GS", "price": "472.60"},
    {"instrument_id": 7, "ticker": "SPY", "price": "505.40"},
    {"instrument_id": 8, "ticker": "QQQ", "price": "438.70"},
]

ACCOUNT_IDS: list[int] = [1, 2, 3, 4, 5]


class TradingSimulator:
    """Generates one complete trade lifecycle per invocation.

    Steps: order INSERT -> trade INSERT -> order UPDATE (FILLED)
           -> Kafka market-data tick -> position UPSERT.
    """

    def __init__(self, db: TradingDatabase, kafka: MSKProducer) -> None:
        self._db = db
        self._kafka = kafka

        # In-memory price book: ticker -> last_price.
        # Re-seeded from INSTRUMENTS on each cold start; drifts within
        # a warm invocation sequence.
        self._price_book: dict[str, Decimal] = {
            inst["ticker"]: Decimal(str(inst["price"]))
            for inst in INSTRUMENTS
        }

    def _jitter_price(self, ticker: str) -> Decimal:
        """Apply small random jitter and update the in-memory price book.

        Multiplies the current price by random factor in [0.995, 1.005]
        and quantizes to 2 decimal places.
        """
        current = self._price_book[ticker]
        factor = Decimal(str(random.uniform(0.995, 1.005)))
        new_price = (current * factor).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP
        )
        self._price_book[ticker] = new_price
        return new_price

    def run_cycle(self) -> dict:
        """Execute one complete trading cycle and return a result summary."""

        # -- Step 1: Pick random parameters ----------------------------------
        account_id = random.choice(ACCOUNT_IDS)
        instrument = random.choice(INSTRUMENTS)
        instrument_id: int = instrument["instrument_id"]
        ticker: str = instrument["ticker"]
        side = random.choice(["BUY", "SELL"])
        quantity = random.randint(100, 5000)
        order_type = random.choice(["MARKET", "LIMIT"])

        # -- Step 2: If LIMIT, set limit_price to jittered price -------------
        limit_price: Decimal | None = None
        if order_type == "LIMIT":
            limit_price = self._jitter_price(ticker)

        # -- Step 3: INSERT order (CDC captures this change) -----------------
        order_id = self._db.insert_order(
            account_id=account_id,
            instrument_id=instrument_id,
            side=side,
            quantity=quantity,
            order_type=order_type,
            limit_price=limit_price,
        )
        logger.info(
            "Order inserted",
            extra={
                "order_id": order_id,
                "ticker": ticker,
                "side": side,
                "order_type": order_type,
                "quantity": quantity,
                "account_id": account_id,
            },
        )

        # -- Step 4: Jitter price for execution ------------------------------
        execution_price = self._jitter_price(ticker)

        # -- Step 5: INSERT trade --------------------------------------------
        trade_id = self._db.insert_trade(
            order_id=order_id,
            instrument_id=instrument_id,
            quantity=quantity,
            price=execution_price,
        )

        # -- Step 6: UPDATE order to FILLED ----------------------------------
        self._db.update_order_filled(order_id)
        logger.info(
            "Order filled",
            extra={
                "order_id": order_id,
                "trade_id": trade_id,
                "price": str(execution_price),
            },
        )

        # -- Step 7: Produce market-data tick to MSK Kafka -------------------
        spread = execution_price * Decimal("0.001")
        bid = (execution_price - spread).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP
        )
        ask = (execution_price + spread).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP
        )

        tick = {
            "tick_id": str(uuid.uuid4()),
            "instrument_id": instrument_id,
            "ticker": ticker,
            "bid": str(bid),
            "ask": str(ask),
            "last_price": str(execution_price),
            "volume": quantity,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        self._kafka.send_market_data(tick)

        # -- Step 8: UPSERT position ----------------------------------------
        qty_delta = quantity if side == "BUY" else -quantity
        self._db.upsert_position(
            account_id=account_id,
            instrument_id=instrument_id,
            quantity_delta=qty_delta,
            price=execution_price,
        )

        return {
            "order_id": order_id,
            "trade_id": trade_id,
            "ticker": ticker,
            "side": side,
            "quantity": quantity,
            "price": str(execution_price),
        }
