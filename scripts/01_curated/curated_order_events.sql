-- Curated Order Events: Clean + type-cast streaming order events
-- Source: raw_mnpi_dev.mnpi_events (Iceberg, append-only from Kafka)
-- Target: curated_mnpi_dev.order_events (Iceberg, deduplicated + typed)
--
-- Transform logic:
--   1. Filter out empty/tombstone records (4,391 of 5,548 raw rows are empty)
--   2. Cast string fields to proper types (quantity -> bigint, timestamp -> timestamp)
--   3. Deduplicate by event_id (take latest per event_id)
--   4. Add derived columns: is_buy flag, event_hour for partitioning
--
-- Run via Athena engine v3 in the data-engineers workgroup.

CREATE TABLE curated_mnpi_dev.order_events
WITH (
    table_type = 'ICEBERG',
    location = 's3://datalake-local-iceberg-dev/curated/mnpi/order_events/',
    is_external = false,
    format = 'PARQUET'
) AS
SELECT
    event_id,
    event_type,
    ticker,
    side,
    CAST(quantity AS bigint)         AS quantity,
    order_id,
    account_id,
    instrument_id,
    from_iso8601_timestamp(timestamp) AS event_timestamp,
    side = 'BUY'                     AS is_buy,
    date_trunc('hour', from_iso8601_timestamp(timestamp)) AS event_hour
FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY event_id
            ORDER BY timestamp DESC
        ) AS rn
    FROM raw_mnpi_dev.mnpi_events
    WHERE ticker IS NOT NULL
      AND ticker != ''
      AND event_type IS NOT NULL
      AND event_type != ''
)
WHERE rn = 1;
