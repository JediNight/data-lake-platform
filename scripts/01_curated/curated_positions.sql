-- Curated Positions: Current-state table from raw CDC events
-- Source: raw_mnpi.positions (append-only Iceberg with Debezium CDC events)
-- Target: curated_mnpi.positions (current state via MERGE)
--
-- Debezium CDC envelope fields:
--   op            : 'c' (create), 'u' (update), 'd' (delete), 'r' (snapshot)
--   before / after: full row image (struct)
--   source_timestamp: Debezium event timestamp in epoch millis

MERGE INTO curated_mnpi.positions AS target
USING (
    -- Deduplicate: take latest event per position_id
    SELECT *
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY after.position_id
                ORDER BY source_timestamp DESC
            ) AS rn
        FROM raw_mnpi.positions
        WHERE op != 'd'  -- Exclude deletes for current state
    )
    WHERE rn = 1
) AS source
ON target.position_id = source.after.position_id
WHEN MATCHED THEN UPDATE SET
    account_id    = source.after.account_id,
    instrument_id = source.after.instrument_id,
    quantity      = source.after.quantity,
    market_value  = source.after.market_value,
    position_date = source.after.position_date,
    updated_at    = from_unixtime(source.source_timestamp / 1000)
WHEN NOT MATCHED THEN INSERT (
    position_id, account_id, instrument_id, quantity,
    market_value, position_date, updated_at
) VALUES (
    source.after.position_id, source.after.account_id,
    source.after.instrument_id, source.after.quantity,
    source.after.market_value, source.after.position_date,
    from_unixtime(source.source_timestamp / 1000)
);
