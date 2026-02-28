from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    kafka_bootstrap_servers: str = "localhost:9092"
    postgres_dsn: str = "postgresql://postgres:postgres@localhost:5432/trading"
    simulation_enabled: bool = False
    simulation_interval_seconds: float = 5.0
