-- Curated Orders: Current-state table from raw CDC events
-- Source: raw_mnpi.orders (append-only Iceberg with Debezium CDC events)
-- Target: curated_mnpi.orders (current state via MERGE)
--
-- Debezium CDC envelope fields:
--   op            : 'c' (create), 'u' (update), 'd' (delete), 'r' (snapshot)
--   before / after: full row image (struct)
--   source_timestamp: Debezium event timestamp in epoch millis

MERGE INTO curated_mnpi.orders AS target
USING (
    -- Deduplicate: take latest event per order_id
    SELECT *
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY after.order_id
                ORDER BY source_timestamp DESC
            ) AS rn
        FROM raw_mnpi.orders
        WHERE op != 'd'  -- Exclude deletes for current state
    )
    WHERE rn = 1
) AS source
ON target.order_id = source.after.order_id
WHEN MATCHED THEN UPDATE SET
    account_id        = source.after.account_id,
    instrument_id     = source.after.instrument_id,
    side              = source.after.side,
    quantity          = source.after.quantity,
    order_type        = source.after.order_type,
    limit_price       = source.after.limit_price,
    status            = source.after.status,
    disclosure_status = source.after.disclosure_status,
    updated_at        = from_unixtime(source.source_timestamp / 1000)
WHEN NOT MATCHED THEN INSERT (
    order_id, account_id, instrument_id, side, quantity,
    order_type, limit_price, status, disclosure_status,
    created_at, updated_at
) VALUES (
    source.after.order_id, source.after.account_id,
    source.after.instrument_id, source.after.side,
    source.after.quantity, source.after.order_type,
    source.after.limit_price, source.after.status,
    source.after.disclosure_status,
    from_unixtime(source.source_timestamp / 1000),
    from_unixtime(source.source_timestamp / 1000)
);
