-- Curated Instruments: Current-state table from raw CDC events
-- Source: raw_nonmnpi.instruments (append-only Iceberg with Debezium CDC events)
-- Target: curated_nonmnpi.instruments (current state via MERGE)
--
-- Instruments are non-MNPI reference data (publicly available securities info).
--
-- Debezium CDC envelope fields:
--   op            : 'c' (create), 'u' (update), 'd' (delete), 'r' (snapshot)
--   before / after: full row image (struct)
--   source_timestamp: Debezium event timestamp in epoch millis

MERGE INTO curated_nonmnpi.instruments AS target
USING (
    -- Deduplicate: take latest event per instrument_id
    SELECT *
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY after.instrument_id
                ORDER BY source_timestamp DESC
            ) AS rn
        FROM raw_nonmnpi.instruments
        WHERE op != 'd'  -- Exclude deletes for current state
    )
    WHERE rn = 1
) AS source
ON target.instrument_id = source.after.instrument_id
WHEN MATCHED THEN UPDATE SET
    ticker          = source.after.ticker,
    cusip           = source.after.cusip,
    isin            = source.after.isin,
    name            = source.after.name,
    instrument_type = source.after.instrument_type,
    exchange        = source.after.exchange,
    created_at      = source.after.created_at
WHEN NOT MATCHED THEN INSERT (
    instrument_id, ticker, cusip, isin, name,
    instrument_type, exchange, created_at
) VALUES (
    source.after.instrument_id, source.after.ticker,
    source.after.cusip, source.after.isin,
    source.after.name, source.after.instrument_type,
    source.after.exchange, source.after.created_at
);
