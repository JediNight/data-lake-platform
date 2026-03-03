from datetime import datetime
from decimal import Decimal
from pydantic import BaseModel


class OrderEvent(BaseModel):
    event_id: str
    event_type: str
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
