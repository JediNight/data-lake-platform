"""Entry point: python -m alpaca_adapter"""

import asyncio
import logging

from .adapter import run_adapter
from .config import AlpacaSettings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)

if __name__ == "__main__":
    settings = AlpacaSettings()
    if not settings.alpaca_api_key:
        raise SystemExit(
            "ALPACA_API_KEY and ALPACA_SECRET_KEY must be set as environment variables."
        )
    asyncio.run(run_adapter(settings))
