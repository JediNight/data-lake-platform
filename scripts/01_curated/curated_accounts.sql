-- Curated Accounts: Current-state table from raw CDC events
-- Source: raw_nonmnpi.accounts (append-only Iceberg with Debezium CDC events)
-- Target: curated_nonmnpi.accounts (current state via MERGE)
--
-- Accounts are non-MNPI reference data (account metadata only).
--
-- Debezium CDC envelope fields:
--   op            : 'c' (create), 'u' (update), 'd' (delete), 'r' (snapshot)
--   before / after: full row image (struct)
--   source_timestamp: Debezium event timestamp in epoch millis

MERGE INTO curated_nonmnpi.accounts AS target
USING (
    -- Deduplicate: take latest event per account_id
    SELECT *
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY after.account_id
                ORDER BY source_timestamp DESC
            ) AS rn
        FROM raw_nonmnpi.accounts
        WHERE op != 'd'  -- Exclude deletes for current state
    )
    WHERE rn = 1
) AS source
ON target.account_id = source.after.account_id
WHEN MATCHED THEN UPDATE SET
    account_name = source.after.account_name,
    account_type = source.after.account_type,
    status       = source.after.status,
    created_at   = source.after.created_at
WHEN NOT MATCHED THEN INSERT (
    account_id, account_name, account_type, status, created_at
) VALUES (
    source.after.account_id, source.after.account_name,
    source.after.account_type, source.after.status,
    source.after.created_at
);
