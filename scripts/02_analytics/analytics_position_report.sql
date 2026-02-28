-- Analytics: Position Report by Account
-- Source: curated_mnpi.positions + curated_nonmnpi.accounts + curated_nonmnpi.instruments
-- Target: analytics_mnpi.position_report (CTAS)
--
-- Joins positions with account and instrument reference data to produce
-- a human-readable holdings report. Includes implied price calculation
-- for sanity-checking market value against quantity.

CREATE TABLE analytics_mnpi.position_report
WITH (
    format = 'PARQUET',
    external_location = 's3://datalake-mnpi-${environment}/analytics/position_report/'
) AS
SELECT
    a.account_name,
    a.account_type,
    i.ticker,
    i.name AS instrument_name,
    p.quantity,
    p.market_value,
    p.position_date,
    ROUND(p.market_value / NULLIF(p.quantity, 0), 2) AS implied_price
FROM curated_mnpi.positions p
JOIN curated_nonmnpi.accounts a ON p.account_id = a.account_id
JOIN curated_nonmnpi.instruments i ON p.instrument_id = i.instrument_id
ORDER BY a.account_name, p.market_value DESC;
