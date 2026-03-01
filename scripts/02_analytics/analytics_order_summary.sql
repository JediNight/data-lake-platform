-- Analytics: Order Activity Summary per Ticker
-- Source: curated_mnpi_dev.order_events
-- Target: analytics_mnpi_dev.order_summary (Iceberg, pre-aggregated)
--
-- Business metrics:
--   - Total orders, buy/sell split, volume per ticker
--   - Average order size
--   - Buy/sell ratio (values > 1 = net buying pressure)
--
-- Run via Athena engine v3 in the data-engineers workgroup.

CREATE TABLE analytics_mnpi_dev.order_summary
WITH (
    table_type = 'ICEBERG',
    location = 's3://datalake-local-iceberg-dev/analytics/mnpi/order_summary/',
    is_external = false,
    format = 'PARQUET'
) AS
SELECT
    ticker,
    count(*)                                         AS total_orders,
    count(CASE WHEN is_buy THEN 1 END)               AS buy_orders,
    count(CASE WHEN NOT is_buy THEN 1 END)            AS sell_orders,
    sum(quantity)                                     AS total_volume,
    round(avg(quantity), 0)                           AS avg_order_size,
    round(
        CAST(count(CASE WHEN is_buy THEN 1 END) AS double) /
        NULLIF(count(CASE WHEN NOT is_buy THEN 1 END), 0),
        2
    )                                                AS buy_sell_ratio,
    min(event_timestamp)                             AS first_order_at,
    max(event_timestamp)                             AS last_order_at
FROM curated_mnpi_dev.order_events
GROUP BY ticker
ORDER BY total_volume DESC;
