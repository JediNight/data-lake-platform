import json
import logging

from aiokafka import AIOKafkaProducer
from pydantic import BaseModel

logger = logging.getLogger(__name__)


class KafkaEventProducer:
    TOPIC_ORDER_EVENTS = "stream.order-events"
    TOPIC_MARKET_DATA = "stream.market-data"

    def __init__(self, bootstrap_servers: str) -> None:
        self.bootstrap_servers = bootstrap_servers
        self.producer: AIOKafkaProducer | None = None

    async def start(self) -> None:
        self.producer = AIOKafkaProducer(
            bootstrap_servers=self.bootstrap_servers,
            value_serializer=lambda v: json.dumps(v, default=str).encode("utf-8"),
        )
        await self.producer.start()
        logger.info(
            "Kafka producer started (bootstrap_servers=%s)", self.bootstrap_servers
        )

    async def stop(self) -> None:
        if self.producer is not None:
            await self.producer.stop()
            logger.info("Kafka producer stopped")

    async def send_order_event(self, event: BaseModel) -> None:
        assert self.producer is not None, "Producer not started"
        value = event.model_dump(mode="json")
        await self.producer.send_and_wait(self.TOPIC_ORDER_EVENTS, value=value)
        logger.info("Sent order event to %s", self.TOPIC_ORDER_EVENTS)

    async def send_market_data(self, tick: BaseModel) -> None:
        assert self.producer is not None, "Producer not started"
        value = tick.model_dump(mode="json")
        await self.producer.send_and_wait(self.TOPIC_MARKET_DATA, value=value)
        logger.info("Sent market data to %s", self.TOPIC_MARKET_DATA)
