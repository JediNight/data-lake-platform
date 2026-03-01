"""Configuration for the Alpaca Markets adapter."""

from pydantic_settings import BaseSettings


class AlpacaSettings(BaseSettings):
    alpaca_api_key: str = ""
    alpaca_secret_key: str = ""
    alpaca_ws_url: str = "wss://stream.data.alpaca.markets/v2/iex"
    alpaca_paper_url: str = "https://paper-api.alpaca.markets"
    producer_api_url: str = "http://localhost:8000"
    symbols: list[str] = ["AAPL", "MSFT", "GOOGL", "JPM", "GS", "SPY"]
    account_id: int = 1
