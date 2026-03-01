"""Alpaca WebSocket adapter: connects to Alpaca IEX stream and forwards to producer-api."""

import asyncio
import json
import logging
import signal

import httpx
import websockets

from .config import AlpacaSettings
from .transforms import alpaca_quote_to_market_tick, alpaca_trade_to_order_event

logger = logging.getLogger(__name__)

MAX_RECONNECT_DELAY = 60


async def run_adapter(settings: AlpacaSettings) -> None:
    """Main adapter loop with reconnection and graceful shutdown."""
    stop_event = asyncio.Event()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    delay = 1
    while not stop_event.is_set():
        try:
            await _connect_and_stream(settings, stop_event)
            delay = 1  # reset on clean disconnect
        except (websockets.ConnectionClosed, OSError) as exc:
            logger.warning("Connection lost: %s. Reconnecting in %ds...", exc, delay)
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=delay)
                break  # shutdown requested during backoff
            except asyncio.TimeoutError:
                pass
            delay = min(delay * 2, MAX_RECONNECT_DELAY)
        except Exception:
            logger.exception("Unexpected error in adapter loop")
            break

    logger.info("Adapter shut down.")


async def _connect_and_stream(
    settings: AlpacaSettings, stop_event: asyncio.Event
) -> None:
    """Authenticate, subscribe, and stream events from Alpaca."""
    async with websockets.connect(settings.alpaca_ws_url) as ws:
        # --- Authenticate ---
        auth_msg = json.dumps({
            "action": "auth",
            "key": settings.alpaca_api_key,
            "secret": settings.alpaca_secret_key,
        })
        await ws.send(auth_msg)

        resp = json.loads(await ws.recv())
        if not isinstance(resp, list) or resp[0].get("msg") != "authenticated":
            raise RuntimeError(f"Alpaca auth failed: {resp}")
        logger.info("Authenticated with Alpaca WebSocket.")

        # --- Subscribe ---
        sub_msg = json.dumps({
            "action": "subscribe",
            "quotes": settings.symbols,
            "trades": settings.symbols,
        })
        await ws.send(sub_msg)

        sub_resp = json.loads(await ws.recv())
        logger.info("Subscribed: %s", sub_resp)

        # --- Stream ---
        async with httpx.AsyncClient(
            base_url=settings.producer_api_url, timeout=10.0
        ) as http:
            while not stop_event.is_set():
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
                except asyncio.TimeoutError:
                    continue  # check stop_event and loop

                events = json.loads(raw)
                if not isinstance(events, list):
                    events = [events]

                for event in events:
                    await _handle_event(event, settings, http)


async def _handle_event(
    event: dict, settings: AlpacaSettings, http: httpx.AsyncClient
) -> None:
    """Route a single Alpaca event to the correct producer-api endpoint."""
    event_type = event.get("T")

    if event_type == "q":
        tick = alpaca_quote_to_market_tick(event)
        if tick:
            resp = await http.post(
                "/api/v1/market-data",
                json=tick.model_dump(mode="json"),
            )
            logger.info(
                "Forwarded quote %s → producer-api (%d)", tick.ticker, resp.status_code
            )

    elif event_type == "t":
        order = alpaca_trade_to_order_event(event, settings.account_id)
        if order:
            payload = {
                "account_id": order.account_id,
                "instrument_id": order.instrument_id,
                "ticker": order.ticker,
                "side": order.side,
                "quantity": str(order.quantity),
                "order_type": "MARKET",
                "limit_price": str(order.limit_price) if order.limit_price else None,
            }
            resp = await http.post("/api/v1/orders", json=payload)
            logger.info(
                "Forwarded trade %s → producer-api (%d)",
                order.ticker,
                resp.status_code,
            )
