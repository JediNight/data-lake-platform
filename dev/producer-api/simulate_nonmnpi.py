#!/usr/bin/env python3
"""Generate NonMNPI synthetic data — reference tables + market-data ticks.

Seeds accounts and instruments into Postgres (CDC path) and publishes
market-data ticks to Kafka (streaming path).

    python3 simulate_nonmnpi.py [--ticks N] [--interval SECONDS]
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

import asyncpg
from aiokafka import AIOKafkaProducer

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("nonmnpi-simulator")

ACCOUNTS = [
    {"account_id": 1, "account_name": "Alpha Fund", "account_type": "INSTITUTIONAL"},
    {"account_id": 2, "account_name": "Beta Capital", "account_type": "INSTITUTIONAL"},
    {"account_id": 3, "account_name": "Gamma Trading", "account_type": "FUND"},
    {"account_id": 4, "account_name": "Delta Advisors", "account_type": "INDIVIDUAL"},
    {"account_id": 5, "account_name": "Epsilon Partners", "account_type": "INDIVIDUAL"},
]

INSTRUMENTS = [
    {"instrument_id": 1, "ticker": "AAPL", "name": "Apple Inc.", "instrument_type": "EQUITY", "price": "178.50"},
    {"instrument_id": 2, "ticker": "MSFT", "name": "Microsoft Corp.", "instrument_type": "EQUITY", "price": "415.20"},
    {"instrument_id": 3, "ticker": "GOOGL", "name": "Alphabet Inc.", "instrument_type": "EQUITY", "price": "141.80"},
    {"instrument_id": 4, "ticker": "JPM", "name": "JPMorgan Chase", "instrument_type": "EQUITY", "price": "195.30"},
    {"instrument_id": 5, "ticker": "GS", "name": "Goldman Sachs", "instrument_type": "EQUITY", "price": "472.60"},
]

POSTGRES_DSN = "postgresql://postgres:postgres@sample-postgres.data.svc.cluster.local:5432/trading"
KAFKA_BOOTSTRAP = "data-lake-kafka-kafka-bootstrap.strimzi.svc.cluster.local:9092"
MARKET_DATA_TOPIC = "stream.market-data"

price_book = {i["ticker"]: Decimal(i["price"]) for i in INSTRUMENTS}


def jitter(ticker: str) -> Decimal:
    cur = price_book[ticker]
    factor = Decimal(str(random.uniform(0.995, 1.005)))
    new = (cur * factor).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    price_book[ticker] = new
    return new


async def run(ticks: int, interval: float) -> None:
    pool = await asyncpg.create_pool(POSTGRES_DSN, min_size=1, max_size=3)
    producer = AIOKafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP,
        value_serializer=lambda v: json.dumps(v, default=str).encode(),
    )
    await producer.start()

    # 1. Seed accounts (upsert)
    async with pool.acquire() as conn:
        for acct in ACCOUNTS:
            await conn.execute(
                """INSERT INTO accounts (account_id, account_name, account_type)
                   VALUES ($1, $2, $3)
                   ON CONFLICT (account_id) DO UPDATE
                   SET account_name = $2, account_type = $3""",
                acct["account_id"], acct["account_name"], acct["account_type"],
            )
        log.info("Seeded %d accounts", len(ACCOUNTS))

    # 2. Seed instruments (upsert)
    async with pool.acquire() as conn:
        for inst in INSTRUMENTS:
            await conn.execute(
                """INSERT INTO instruments (instrument_id, ticker, name, instrument_type)
                   VALUES ($1, $2, $3, $4)
                   ON CONFLICT (instrument_id) DO UPDATE
                   SET ticker = $2, name = $3, instrument_type = $4""",
                inst["instrument_id"], inst["ticker"], inst["name"], inst["instrument_type"],
            )
        log.info("Seeded %d instruments", len(INSTRUMENTS))

    # 3. Publish market-data ticks
    log.info("Publishing %d market-data ticks, %.1fs interval", ticks, interval)
    try:
        for i in range(1, ticks + 1):
            inst = random.choice(INSTRUMENTS)
            ticker = inst["ticker"]
            last_price = jitter(ticker)
            spread = last_price * Decimal("0.001")
            bid = (last_price - spread).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            ask = (last_price + spread).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            volume = random.randint(1000, 50000)

            # Wrap in {"schema": ..., "payload": ...} envelope to match
            # JsonConverter schemas.enable=true expected by the sink connector.
            tick = {
                "schema": {
                    "type": "struct",
                    "fields": [
                        {"field": "tick_id", "type": "string", "optional": False},
                        {"field": "instrument_id", "type": "int32", "optional": False},
                        {"field": "ticker", "type": "string", "optional": False},
                        {"field": "bid", "type": "string", "optional": False},
                        {"field": "ask", "type": "string", "optional": False},
                        {"field": "last_price", "type": "string", "optional": False},
                        {"field": "volume", "type": "int32", "optional": False},
                        {"field": "timestamp", "type": "string", "optional": False},
                    ],
                    "optional": False,
                    "name": "market_data",
                },
                "payload": {
                    "tick_id": str(uuid.uuid4()),
                    "instrument_id": inst["instrument_id"],
                    "ticker": ticker,
                    "bid": str(bid),
                    "ask": str(ask),
                    "last_price": str(last_price),
                    "volume": volume,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                },
            }
            await producer.send_and_wait(MARKET_DATA_TOPIC, tick)
            log.info("[%d] %s bid=%s ask=%s last=%s vol=%d", i, ticker, bid, ask, last_price, volume)
            await asyncio.sleep(interval)
    except KeyboardInterrupt:
        log.info("Interrupted")
    finally:
        await producer.stop()
        await pool.close()
        log.info("Done — %d accounts, %d instruments seeded, %d ticks published", len(ACCOUNTS), len(INSTRUMENTS), ticks)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ticks", type=int, default=20, help="Number of market-data ticks")
    parser.add_argument("--interval", type=float, default=1.0, help="Seconds between ticks")
    args = parser.parse_args()
    asyncio.run(run(args.ticks, args.interval))
