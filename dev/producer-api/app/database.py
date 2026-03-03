import logging
from datetime import date, timedelta
from decimal import Decimal

import asyncpg

logger = logging.getLogger(__name__)


class TradingDatabase:
    """Async database client for the trading platform using asyncpg."""

    def __init__(self, dsn: str) -> None:
        self.dsn = dsn
        self.pool: asyncpg.Pool | None = None

    async def connect(self) -> None:
        """Create the asyncpg connection pool."""
        self.pool = await asyncpg.create_pool(
            self.dsn,
            min_size=1,
            max_size=5,
        )
        logger.info("Connected to PostgreSQL at %s", self.dsn.split("@")[-1])

    async def close(self) -> None:
        """Close the asyncpg connection pool."""
        if self.pool:
            await self.pool.close()
            logger.info("Closed PostgreSQL connection pool")

    async def insert_order(
        self,
        account_id: int,
        instrument_id: int,
        side: str,
        quantity: Decimal,
        order_type: str,
        limit_price: Decimal | None = None,
        status: str = "PENDING",
        disclosure_status: str = "MNPI",
    ) -> int:
        """Insert a new order and return the generated order_id."""
        assert self.pool is not None, "Database pool is not initialized"
        order_id: int = await self.pool.fetchval(
            """
            INSERT INTO orders (
                account_id, instrument_id, side, quantity,
                order_type, limit_price, status, disclosure_status
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            RETURNING order_id
            """,
            account_id,
            instrument_id,
            side,
            quantity,
            order_type,
            limit_price,
            status,
            disclosure_status,
        )
        logger.info(
            "Inserted order %d: %s %s qty=%s instrument=%d account=%d",
            order_id,
            side,
            order_type,
            quantity,
            instrument_id,
            account_id,
        )
        return order_id

    async def insert_trade(
        self,
        order_id: int,
        instrument_id: int,
        quantity: Decimal,
        price: Decimal,
        venue: str = "NYSE",
        disclosure_status: str = "MNPI",
    ) -> int:
        """Insert a new trade with T+2 settlement date and return the generated trade_id."""
        assert self.pool is not None, "Database pool is not initialized"
        settlement_date: date = date.today() + timedelta(days=2)
        trade_id: int = await self.pool.fetchval(
            """
            INSERT INTO trades (
                order_id, instrument_id, quantity, price,
                execution_venue, settlement_date, disclosure_status
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            RETURNING trade_id
            """,
            order_id,
            instrument_id,
            quantity,
            price,
            venue,
            settlement_date,
            disclosure_status,
        )
        logger.info(
            "Inserted trade %d: order=%d instrument=%d qty=%s @ %s settle=%s",
            trade_id,
            order_id,
            instrument_id,
            quantity,
            price,
            settlement_date,
        )
        return trade_id

    async def upsert_position(
        self,
        account_id: int,
        instrument_id: int,
        quantity_delta: Decimal,
        price: Decimal,
    ) -> None:
        """Insert or update a position for the current date.

        On conflict (account_id, instrument_id, position_date), the existing
        row is updated: quantity is incremented by quantity_delta and
        market_value is recalculated as (quantity + quantity_delta) * price.
        """
        assert self.pool is not None, "Database pool is not initialized"
        await self.pool.execute(
            """
            INSERT INTO positions (
                account_id, instrument_id, quantity, market_value, position_date
            )
            VALUES ($1, $2, $3, $3::numeric * $4::numeric, CURRENT_DATE)
            ON CONFLICT (account_id, instrument_id, position_date)
            DO UPDATE SET
                quantity      = positions.quantity + $3::numeric,
                market_value  = (positions.quantity + $3::numeric) * $4::numeric,
                updated_at    = NOW()
            """,
            account_id,
            instrument_id,
            quantity_delta,
            price,
        )
        logger.info(
            "Upserted position: account=%d instrument=%d delta=%s price=%s",
            account_id,
            instrument_id,
            quantity_delta,
            price,
        )
