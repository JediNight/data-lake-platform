"""MSK Kafka producer with IAM authentication.

Replaces the aiokafka-based KafkaEventProducer from producer-api/app/producer.py.
Uses kafka-python with AWS MSK IAM SASL signer for SASL_SSL/OAUTHBEARER auth.
"""

import json
import os

from aws_lambda_powertools import Logger, Tracer
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
from kafka import KafkaProducer
from kafka.sasl.oauth import AbstractTokenProvider

logger = Logger(child=True)
tracer = Tracer()

TOPIC_MARKET_DATA = "stream.market-data"


class MSKTokenProvider(AbstractTokenProvider):
    """OAUTHBEARER token provider for MSK IAM authentication.

    Extends kafka-python's AbstractTokenProvider so the isinstance() check
    in kafka.sasl.oauth passes at connection init.
    """

    def token(self) -> str:
        region = os.environ.get("AWS_REGION", "us-east-1")
        token, _ = MSKAuthTokenProvider.generate_auth_token(region)
        return token


class MSKProducer:
    """Synchronous Kafka producer for MSK with IAM authentication.

    Handles stale connections on warm Lambda reuse by recreating the
    producer on send failure.
    """

    def __init__(self, bootstrap_servers: str) -> None:
        self._bootstrap_servers = bootstrap_servers
        self._producer: KafkaProducer | None = None
        self._connect()

    def _connect(self) -> None:
        """Create (or recreate) the Kafka producer."""
        self._producer = KafkaProducer(
            bootstrap_servers=self._bootstrap_servers,
            security_protocol="SASL_SSL",
            sasl_mechanism="OAUTHBEARER",
            sasl_oauth_token_provider=MSKTokenProvider(),
            api_version_auto_timeout_ms=10000,
            value_serializer=lambda v: json.dumps(v, default=str).encode("utf-8"),
        )
        logger.info(
            "MSK producer initialized",
            extra={"bootstrap_servers": self._bootstrap_servers},
        )

    @tracer.capture_method
    def send_market_data(self, tick: dict) -> None:
        """Send a market-data tick to Kafka and flush.

        On failure (stale connection from warm reuse), reconnects once and retries.
        """
        try:
            self._producer.send(TOPIC_MARKET_DATA, value=tick)
            self._producer.flush()
        except Exception:
            logger.warning("Kafka send failed, reconnecting and retrying")
            self._connect()
            self._producer.send(TOPIC_MARKET_DATA, value=tick)
            self._producer.flush()
        logger.info(
            "Sent market data",
            extra={"topic": TOPIC_MARKET_DATA, "ticker": tick.get("ticker")},
        )

    def close(self) -> None:
        """Close the Kafka producer."""
        self._producer.close()
        logger.info("MSK producer closed")
