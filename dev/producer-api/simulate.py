#!/usr/bin/env python3
"""Standalone trading simulator — Python 3.9 compatible.

Inserts orders/trades into Postgres (CDC path) and publishes market-data
ticks to Kafka (streaming path).  Run with:

    python3 simulate.py [--cycles N] [--interval SECONDS]
"""

import argparse
import asyncio
import json
import logging
import random
import sys
import uuid
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Optional

import asyncpg
from aiokafka import AIOKafkaProducer

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("simulator")

INSTRUMENTS = [
    {"instrument_id": 1, "ticker": "AAPL", "price": "178.50"},
    {"instrument_id": 2, "ticker": "MSFT", "price": "415.20"},
    {"instrument_id": 3, "ticker": "GOOGL", "price": "141.80"},
    {"instrument_id": 4, "ticker": "JPM", "price": "195.30"},
    {"instrument_id": 5, "ticker": "GS", "price": "472.60"},
]

ACCOUNT_IDS = [1, 2, 3, 4, 5]

POSTGRES_DSN = "postgresql://postgres:postgres@localhost:5432/trading"
KAFKA_BOOTSTRAP = "localhost:9092"
MARKET_DATA_TOPIC = "market-data.ticks"

price_book = {i["ticker"]: Decimal(i["price"]) for i in INSTRUMENTS}


def jitter(ticker: str) -> Decimal:
    cur = price_book[ticker]
    factor = Decimal(str(random.uniform(0.995, 1.005)))
    new = (cur * factor).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    price_book[ticker] = new
    return new


async def run(cycles: int, interval: float) -> None:
    pool = await asyncpg.create_pool(POSTGRES_DSN, min_size=1, max_size=3)
    producer = AIOKafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP,
        value_serializer=lambda v: json.dumps(v, default=str).encode(),
    )
    await producer.start()

    log.info("Simulator started — %s cycles, %.1fs interval", cycles or "infinite", interval)

    count = 0
    try:
        while cycles == 0 or count < cycles:
            count += 1
            acct = random.choice(ACCOUNT_IDS)
            inst = random.choice(INSTRUMENTS)
            iid = inst["instrument_id"]
            ticker = inst["ticker"]
            side = random.choice(["BUY", "SELL"])
            qty = random.randint(100, 5000)
            otype = random.choice(["MARKET", "LIMIT"])
            limit_px: Optional[Decimal] = jitter(ticker) if otype == "LIMIT" else None

            # 1. INSERT order (CDC captures this)
            async with pool.acquire() as conn:
                order_id = await conn.fetchval(
                    """INSERT INTO orders (account_id, instrument_id, side, quantity,
                           order_type, limit_price, status)
                       VALUES ($1,$2,$3,$4,$5,$6,'PENDING') RETURNING order_id""",
                    acct, iid, side, qty, otype, limit_px,
                )

            log.info(
                "[%d] order_id=%d %s %s %s qty=%d acct=%d",
                count, order_id, ticker, side, otype, qty, acct,
            )

            await asyncio.sleep(random.uniform(0.5, 1.5))

            # 2. Execution price + INSERT trade
            exec_px = jitter(ticker)
            async with pool.acquire() as conn:
                trade_id = await conn.fetchval(
                    """INSERT INTO trades (order_id, instrument_id, quantity, price)
                       VALUES ($1,$2,$3,$4) RETURNING trade_id""",
                    order_id, iid, qty, exec_px,
                )
                # 3. Mark order FILLED
                await conn.execute(
                    "UPDATE orders SET status='FILLED', updated_at=NOW() WHERE order_id=$1",
                    order_id,
                )

            log.info("  trade_id=%d filled @ %s", trade_id, exec_px)

            # 4. Publish market-data tick to Kafka
            spread = exec_px * Decimal("0.001")
            bid = (exec_px - spread).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            ask = (exec_px + spread).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            tick = {
                "tick_id": str(uuid.uuid4()),
                "instrument_id": iid,
                "ticker": ticker,
                "bid": str(bid),
                "ask": str(ask),
                "last_price": str(exec_px),
                "volume": qty,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
            await producer.send_and_wait(MARKET_DATA_TOPIC, tick)
            log.info("  market tick published: %s @ %s", ticker, exec_px)

            # 5. Upsert position
            qty_delta = qty if side == "BUY" else -qty
            async with pool.acquire() as conn:
                await conn.execute(
                    """INSERT INTO positions (account_id, instrument_id, quantity, market_value, position_date, updated_at)
                       VALUES ($1, $2, $3, $4, CURRENT_DATE, NOW())
                       ON CONFLICT (account_id, instrument_id, position_date) DO UPDATE
                       SET quantity = positions.quantity + $3,
                           market_value = $4,
                           updated_at = NOW()""",
                    acct, iid, qty_delta, exec_px,
                )

            await asyncio.sleep(interval)

    except KeyboardInterrupt:
        log.info("Interrupted")
    finally:
        await producer.stop()
        await pool.close()
        log.info("Done — %d cycles completed", count)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cycles", type=int, default=10, help="0 = infinite")
    parser.add_argument("--interval", type=float, default=3.0)
    args = parser.parse_args()
    asyncio.run(run(args.cycles, args.interval))
