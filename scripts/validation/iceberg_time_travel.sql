-- Iceberg Time Travel Demo Queries
-- Demonstrates Iceberg snapshot capabilities on the raw layer
--
-- Apache Iceberg tables in Athena support time-travel queries via:
--   FOR SYSTEM_VERSION AS OF <snapshot_id>   -- query specific snapshot
--   FOR SYSTEM_TIME AS OF <timestamp>        -- query as-of timestamp
--
-- The raw layer tables are append-only Iceberg tables that receive
-- Debezium CDC events. Each Kafka Connect flush creates a new Iceberg
-- snapshot, enabling full audit history of all changes.

-- ============================================================
-- 1. List all snapshots for a table
-- ============================================================

-- The $snapshots metadata table shows every committed snapshot
SELECT *
FROM raw_mnpi."orders$snapshots"
ORDER BY committed_at DESC;

-- ============================================================
-- 2. Query table as of a specific snapshot
-- ============================================================

-- Replace <snapshot_id> with an actual snapshot ID from query above
-- SELECT * FROM raw_mnpi.orders FOR SYSTEM_VERSION AS OF <snapshot_id>;

-- ============================================================
-- 3. Query table as of a specific timestamp
-- ============================================================

-- Replace timestamp with the desired point-in-time
-- SELECT * FROM raw_mnpi.orders FOR SYSTEM_TIME AS OF TIMESTAMP '2024-01-15 10:00:00';

-- ============================================================
-- 4. Count events per snapshot (shows CDC progression)
-- ============================================================

-- Each snapshot summary contains record counts that show how
-- the table grew with each batch of CDC events
SELECT
    s.snapshot_id,
    s.committed_at,
    s.operation,
    s.summary['added-records'] AS added_records,
    s.summary['total-records'] AS total_records
FROM raw_mnpi."orders$snapshots" s
ORDER BY s.committed_at;

-- ============================================================
-- 5. Compare current vs previous snapshot
-- ============================================================

-- Useful for auditing: "what changed in the last batch?"
SELECT
    'current' AS version,
    COUNT(*) AS record_count
FROM raw_mnpi.orders
UNION ALL
SELECT
    'previous' AS version,
    COUNT(*) AS record_count
FROM raw_mnpi.orders FOR SYSTEM_VERSION AS OF (
    SELECT snapshot_id
    FROM raw_mnpi."orders$snapshots"
    ORDER BY committed_at DESC
    OFFSET 1
    LIMIT 1
);

-- ============================================================
-- 6. Snapshot history for other tables
-- ============================================================

-- Trades snapshot history
SELECT
    s.snapshot_id,
    s.committed_at,
    s.operation,
    s.summary['added-records'] AS added_records,
    s.summary['total-records'] AS total_records
FROM raw_mnpi."trades$snapshots" s
ORDER BY s.committed_at;

-- Positions snapshot history
SELECT
    s.snapshot_id,
    s.committed_at,
    s.operation,
    s.summary['added-records'] AS added_records,
    s.summary['total-records'] AS total_records
FROM raw_mnpi."positions$snapshots" s
ORDER BY s.committed_at;
