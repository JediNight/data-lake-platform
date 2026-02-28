-- Analytics: Daily Trade Summary
-- Source: curated_mnpi.trades + curated_nonmnpi.instruments
-- Target: analytics_mnpi.daily_trade_summary (CTAS)
--
-- Aggregates trades by date, instrument, and venue for reporting.
-- Finance analysts and data engineers can query this table for
-- daily trading activity dashboards and compliance reporting.

CREATE TABLE analytics_mnpi.daily_trade_summary
WITH (
    format = 'PARQUET',
    external_location = 's3://datalake-mnpi-${environment}/analytics/daily_trade_summary/'
) AS
SELECT
    CAST(t.executed_at AS DATE) AS trade_date,
    i.ticker,
    i.name AS instrument_name,
    t.execution_venue,
    COUNT(*) AS trade_count,
    SUM(t.quantity) AS total_quantity,
    SUM(t.quantity * t.price) AS total_notional,
    AVG(t.price) AS avg_price,
    MIN(t.price) AS min_price,
    MAX(t.price) AS max_price
FROM curated_mnpi.trades t
JOIN curated_nonmnpi.instruments i ON t.instrument_id = i.instrument_id
GROUP BY
    CAST(t.executed_at AS DATE),
    i.ticker,
    i.name,
    t.execution_venue
ORDER BY trade_date DESC, total_notional DESC;
