"""RDS Data API wrapper for the trading database.

Replaces the asyncpg-based TradingDatabase from producer-api/app/database.py.
All queries use the AWS RDS Data API (HTTPS, no direct PG connection).
"""

from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger, Tracer

logger = Logger(child=True)
tracer = Tracer()


class TradingDatabase:
    """Synchronous database client using the RDS Data API."""

    def __init__(
        self,
        cluster_arn: str,
        secret_arn: str,
        database: str,
    ) -> None:
        self._cluster_arn = cluster_arn
        self._secret_arn = secret_arn
        self._database = database
        self._client = boto3.client("rds-data")

    def _execute(self, sql: str, parameters: list[dict] | None = None) -> dict:
        """Execute a SQL statement via the RDS Data API."""
        kwargs: dict = {
            "resourceArn": self._cluster_arn,
            "secretArn": self._secret_arn,
            "database": self._database,
            "sql": sql,
            "includeResultMetadata": True,
        }
        if parameters:
            kwargs["parameters"] = parameters
        return self._client.execute_statement(**kwargs)

    # ------------------------------------------------------------------
    # Orders
    # ------------------------------------------------------------------

    @tracer.capture_method
    def insert_order(
        self,
        account_id: int,
        instrument_id: int,
        side: str,
        quantity: int,
        order_type: str,
        limit_price: Decimal | None = None,
        status: str = "PENDING",
        disclosure_status: str = "MNPI",
    ) -> int:
        """Insert a new order and return the generated order_id."""
        sql = """
            INSERT INTO orders (
                account_id, instrument_id, side, quantity,
                order_type, limit_price, status, disclosure_status
            )
            VALUES (
                :account_id, :instrument_id, :side,
                CAST(:quantity AS DECIMAL(18,4)),
                :order_type,
                CAST(:limit_price AS DECIMAL(18,4)),
                :status, :disclosure_status
            )
            RETURNING order_id
        """
        params = [
            {"name": "account_id", "value": {"longValue": account_id}},
            {"name": "instrument_id", "value": {"longValue": instrument_id}},
            {"name": "side", "value": {"stringValue": side}},
            {"name": "quantity", "value": {"stringValue": str(quantity)}},
            {"name": "order_type", "value": {"stringValue": order_type}},
            {
                "name": "limit_price",
                "value": {"stringValue": str(limit_price)}
                if limit_price is not None
                else {"isNull": True},
            },
            {"name": "status", "value": {"stringValue": status}},
            {"name": "disclosure_status", "value": {"stringValue": disclosure_status}},
        ]

        response = self._execute(sql, params)
        records = response.get("records", [])
        if not records:
            raise RuntimeError(f"INSERT order returned no rows: {response}")
        order_id = records[0][0]["longValue"]

        logger.info(
            "Inserted order",
            extra={
                "order_id": order_id,
                "side": side,
                "order_type": order_type,
                "quantity": quantity,
                "instrument_id": instrument_id,
                "account_id": account_id,
            },
        )
        return order_id

    # ------------------------------------------------------------------
    # Trades
    # ------------------------------------------------------------------

    @tracer.capture_method
    def insert_trade(
        self,
        order_id: int,
        instrument_id: int,
        quantity: int,
        price: Decimal,
        venue: str = "NYSE",
        disclosure_status: str = "MNPI",
    ) -> int:
        """Insert a new trade with T+2 settlement date and return trade_id."""
        sql = """
            INSERT INTO trades (
                order_id, instrument_id, quantity, price,
                execution_venue, settlement_date, disclosure_status
            )
            VALUES (
                :order_id, :instrument_id,
                CAST(:quantity AS DECIMAL(18,4)),
                CAST(:price AS DECIMAL(18,4)),
                :venue,
                CURRENT_DATE + INTERVAL '2 days',
                :disclosure_status
            )
            RETURNING trade_id
        """
        params = [
            {"name": "order_id", "value": {"longValue": order_id}},
            {"name": "instrument_id", "value": {"longValue": instrument_id}},
            {"name": "quantity", "value": {"stringValue": str(quantity)}},
            {"name": "price", "value": {"stringValue": str(price)}},
            {"name": "venue", "value": {"stringValue": venue}},
            {"name": "disclosure_status", "value": {"stringValue": disclosure_status}},
        ]

        response = self._execute(sql, params)
        records = response.get("records", [])
        if not records:
            raise RuntimeError(f"INSERT trade returned no rows: {response}")
        trade_id = records[0][0]["longValue"]

        logger.info(
            "Inserted trade",
            extra={
                "trade_id": trade_id,
                "order_id": order_id,
                "instrument_id": instrument_id,
                "quantity": quantity,
                "price": str(price),
            },
        )
        return trade_id

    # ------------------------------------------------------------------
    # Order status update
    # ------------------------------------------------------------------

    @tracer.capture_method
    def update_order_filled(self, order_id: int) -> None:
        """Mark an order as FILLED."""
        sql = """
            UPDATE orders
            SET status = 'FILLED', updated_at = NOW()
            WHERE order_id = :order_id
        """
        params = [
            {"name": "order_id", "value": {"longValue": order_id}},
        ]
        self._execute(sql, params)
        logger.info("Order marked FILLED", extra={"order_id": order_id})

    # ------------------------------------------------------------------
    # Positions
    # ------------------------------------------------------------------

    @tracer.capture_method
    def upsert_position(
        self,
        account_id: int,
        instrument_id: int,
        quantity_delta: int,
        price: Decimal,
    ) -> None:
        """Insert or update a position for the current date.

        On conflict (account_id, instrument_id, position_date), the existing
        row is updated: quantity is incremented by quantity_delta and
        market_value is recalculated as (quantity + quantity_delta) * price.
        """
        sql = """
            INSERT INTO positions (
                account_id, instrument_id, quantity, market_value, position_date
            )
            VALUES (
                :account_id,
                :instrument_id,
                CAST(:qty_delta AS DECIMAL(18,4)),
                CAST(:qty_delta AS DECIMAL(18,4)) * CAST(:price AS DECIMAL(18,4)),
                CURRENT_DATE
            )
            ON CONFLICT (account_id, instrument_id, position_date)
            DO UPDATE SET
                quantity     = positions.quantity + CAST(:qty_delta AS DECIMAL(18,4)),
                market_value = (positions.quantity + CAST(:qty_delta AS DECIMAL(18,4)))
                               * CAST(:price AS DECIMAL(18,4)),
                updated_at   = NOW()
        """
        params = [
            {"name": "account_id", "value": {"longValue": account_id}},
            {"name": "instrument_id", "value": {"longValue": instrument_id}},
            {"name": "qty_delta", "value": {"stringValue": str(quantity_delta)}},
            {"name": "price", "value": {"stringValue": str(price)}},
        ]
        self._execute(sql, params)
        logger.info(
            "Upserted position",
            extra={
                "account_id": account_id,
                "instrument_id": instrument_id,
                "quantity_delta": quantity_delta,
                "price": str(price),
            },
        )
