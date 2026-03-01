-- Analytics: Market Data Summary per Ticker
-- Source: curated_nonmnpi_dev.market_ticks
-- Target: analytics_nonmnpi_dev.market_summary (Iceberg, pre-aggregated)
--
-- Business metrics:
--   - Price range (open, high, low, close proxy via first/last)
--   - Average spread and mid-price
--   - Total volume and tick count
--   - Spread as percentage of mid-price (liquidity indicator)
--
-- Run via Athena engine v3 in the data-engineers workgroup.

CREATE TABLE analytics_nonmnpi_dev.market_summary
WITH (
    table_type = 'ICEBERG',
    location = 's3://datalake-local-iceberg-dev/analytics/nonmnpi/market_summary/',
    is_external = false,
    format = 'PARQUET'
) AS
SELECT
    ticker,
    count(*)                                AS tick_count,
    sum(volume)                             AS total_volume,
    round(min(last_price), 2)               AS low_price,
    round(max(last_price), 2)               AS high_price,
    round(avg(last_price), 2)               AS avg_price,
    round(avg(spread), 4)                   AS avg_spread,
    round(avg(mid_price), 2)                AS avg_mid_price,
    round(avg(spread) / NULLIF(avg(mid_price), 0) * 100, 4) AS spread_pct,
    min(tick_timestamp)                     AS first_tick_at,
    max(tick_timestamp)                     AS last_tick_at
FROM curated_nonmnpi_dev.market_ticks
GROUP BY ticker
ORDER BY total_volume DESC;
