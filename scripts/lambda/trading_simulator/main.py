"""Lambda handler for the trading simulator.

Replaces the FastAPI producer-api K8s pod for production.
Runs one trading cycle per invocation, triggered by EventBridge every 1 minute.
"""

import os

from aws_lambda_powertools import Logger, Tracer

from database import TradingDatabase
from producer import MSKProducer
from simulator import TradingSimulator

logger = Logger(service="trading-simulator")
tracer = Tracer(service="trading-simulator")

# ---------------------------------------------------------------------------
# Initialize clients OUTSIDE the handler for connection reuse across
# warm Lambda invocations.
# ---------------------------------------------------------------------------
AURORA_CLUSTER_ARN = os.environ["AURORA_CLUSTER_ARN"]
AURORA_SECRET_ARN = os.environ["AURORA_SECRET_ARN"]
AURORA_DATABASE = os.environ.get("AURORA_DATABASE", "trading")
KAFKA_BOOTSTRAP_SERVERS = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")

db = TradingDatabase(
    cluster_arn=AURORA_CLUSTER_ARN,
    secret_arn=AURORA_SECRET_ARN,
    database=AURORA_DATABASE,
)

kafka = MSKProducer(bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS)

simulator = TradingSimulator(db=db, kafka=kafka)


@logger.inject_lambda_context(log_event=True)
@tracer.capture_lambda_handler
def handler(event: dict, context) -> dict:
    """Run a single trading cycle and return the result summary."""
    logger.info("Starting trading cycle", extra={"environment": ENVIRONMENT})

    result = simulator.run_cycle()
    logger.info("Trading cycle completed", extra={"result": result})
    return result
