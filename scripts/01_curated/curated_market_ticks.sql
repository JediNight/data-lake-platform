-- Curated Market Ticks: Clean + type-cast streaming market data
-- Source: raw_nonmnpi_dev.nonmnpi_events (Iceberg, append-only from Kafka)
-- Target: curated_nonmnpi_dev.market_ticks (Iceberg, typed + enriched)
--
-- Transform logic:
--   1. Cast string price fields to double (ask, bid, last_price)
--   2. Cast timestamp string to proper timestamp type
--   3. Calculate spread (ask - bid) and mid_price ((ask + bid) / 2)
--   4. Deduplicate by tick_id
--
-- Run via Athena engine v3 in the data-engineers workgroup.

CREATE TABLE curated_nonmnpi_dev.market_ticks
WITH (
    table_type = 'ICEBERG',
    location = 's3://datalake-local-iceberg-dev/curated/nonmnpi/market_ticks/',
    is_external = false,
    format = 'PARQUET'
) AS
SELECT
    tick_id,
    ticker,
    CAST(bid AS double)               AS bid,
    CAST(ask AS double)               AS ask,
    CAST(last_price AS double)        AS last_price,
    volume,
    instrument_id,
    from_iso8601_timestamp(timestamp) AS tick_timestamp,
    CAST(ask AS double) - CAST(bid AS double) AS spread,
    (CAST(ask AS double) + CAST(bid AS double)) / 2.0 AS mid_price,
    date_trunc('hour', from_iso8601_timestamp(timestamp)) AS tick_hour
FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY tick_id
            ORDER BY timestamp DESC
        ) AS rn
    FROM raw_nonmnpi_dev.nonmnpi_events
    WHERE ticker IS NOT NULL
      AND ticker != ''
)
WHERE rn = 1;
