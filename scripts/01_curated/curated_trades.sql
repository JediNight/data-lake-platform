-- Curated Trades: Current-state table from raw CDC events
-- Source: raw_mnpi.trades (append-only Iceberg with Debezium CDC events)
-- Target: curated_mnpi.trades (current state via MERGE)
--
-- Debezium CDC envelope fields:
--   op            : 'c' (create), 'u' (update), 'd' (delete), 'r' (snapshot)
--   before / after: full row image (struct)
--   source_timestamp: Debezium event timestamp in epoch millis

MERGE INTO curated_mnpi.trades AS target
USING (
    -- Deduplicate: take latest event per trade_id
    SELECT *
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY after.trade_id
                ORDER BY source_timestamp DESC
            ) AS rn
        FROM raw_mnpi.trades
        WHERE op != 'd'  -- Exclude deletes for current state
    )
    WHERE rn = 1
) AS source
ON target.trade_id = source.after.trade_id
WHEN MATCHED THEN UPDATE SET
    order_id          = source.after.order_id,
    instrument_id     = source.after.instrument_id,
    quantity          = source.after.quantity,
    price             = source.after.price,
    execution_venue   = source.after.execution_venue,
    settlement_date   = source.after.settlement_date,
    disclosure_status = source.after.disclosure_status,
    executed_at       = source.after.executed_at,
    updated_at        = from_unixtime(source.source_timestamp / 1000)
WHEN NOT MATCHED THEN INSERT (
    trade_id, order_id, instrument_id, quantity, price,
    execution_venue, settlement_date, disclosure_status,
    executed_at, updated_at
) VALUES (
    source.after.trade_id, source.after.order_id,
    source.after.instrument_id, source.after.quantity,
    source.after.price, source.after.execution_venue,
    source.after.settlement_date, source.after.disclosure_status,
    source.after.executed_at,
    from_unixtime(source.source_timestamp / 1000)
);
