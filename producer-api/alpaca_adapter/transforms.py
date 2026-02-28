"""Pure transform functions: Alpaca WebSocket events → producer-api models."""

import random
import uuid
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP

from app.models import MarketDataTick, OrderEvent

# Matches DEFAULT_INSTRUMENTS in simulator.py
INSTRUMENT_MAP: dict[str, int] = {
    "AAPL": 1,
    "MSFT": 2,
    "GOOGL": 3,
    "JPM": 4,
    "GS": 5,
    "BRK.B": 6,
    "SPY": 7,
    "AGG": 8,
}


def _parse_timestamp(ts: str) -> datetime:
    """Parse Alpaca RFC-3339 timestamp to timezone-aware datetime."""
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return datetime.fromisoformat(ts)


def alpaca_quote_to_market_tick(quote: dict) -> MarketDataTick | None:
    """Transform an Alpaca quote event into a MarketDataTick.

    Returns None if the ticker is not in INSTRUMENT_MAP.
    """
    ticker = quote.get("S", "")
    instrument_id = INSTRUMENT_MAP.get(ticker)
    if instrument_id is None:
        return None

    bid = Decimal(str(quote["bp"]))
    ask = Decimal(str(quote["ap"]))
    midpoint = ((bid + ask) / 2).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    volume = int(quote.get("bs", 0)) + int(quote.get("as", 0))

    return MarketDataTick(
        tick_id=str(uuid.uuid4()),
        instrument_id=instrument_id,
        ticker=ticker,
        bid=bid,
        ask=ask,
        last_price=midpoint,
        volume=volume,
        timestamp=_parse_timestamp(quote["t"]),
    )


def alpaca_trade_to_order_event(trade: dict, account_id: int) -> OrderEvent | None:
    """Transform an Alpaca trade event into an OrderEvent.

    Returns None if the ticker is not in INSTRUMENT_MAP.
    """
    ticker = trade.get("S", "")
    instrument_id = INSTRUMENT_MAP.get(ticker)
    if instrument_id is None:
        return None

    trade_id = trade.get("i", 0)

    return OrderEvent(
        event_id=str(uuid.uuid4()),
        event_type="ORDER_CREATED",
        order_id=int(trade_id) % 10**6,
        account_id=account_id,
        instrument_id=instrument_id,
        ticker=ticker,
        side=random.choice(["BUY", "SELL"]),
        quantity=Decimal(str(trade["s"])),
        limit_price=Decimal(str(trade["p"])),
        timestamp=_parse_timestamp(trade["t"]),
    )
