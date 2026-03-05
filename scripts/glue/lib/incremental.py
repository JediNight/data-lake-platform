"""
Shared helpers for incremental Iceberg processing in Glue ETL jobs.

Snapshot tracking: stores `last_processed_snapshot_id` as an Iceberg table
property on the *target* table via ALTER TABLE SET TBLPROPERTIES. No external
state store (DynamoDB, S3 markers) required — the Glue Catalog IS the state.

Usage in a curated job:
    from lib.incremental import (
        get_current_snapshot, get_last_processed_snapshot,
        set_last_processed_snapshot, table_exists, assert_quality,
    )
"""

SNAPSHOT_PROPERTY = "last_processed_snapshot_id"


def table_exists(spark, table_fqn):
    """Check whether a Glue Catalog table already exists."""
    try:
        spark.table(table_fqn)
        return True
    except Exception:
        return False


def get_current_snapshot(spark, table_fqn):
    """Return the latest snapshot ID of an Iceberg table, or None if empty."""
    rows = spark.sql(
        f"SELECT snapshot_id FROM {table_fqn}.snapshots ORDER BY committed_at DESC LIMIT 1"
    ).collect()
    return rows[0]["snapshot_id"] if rows else None


def get_last_processed_snapshot(spark, target_table_fqn):
    """Read the watermark snapshot ID stored on the target table, or None."""
    try:
        rows = spark.sql(
            f"SHOW TBLPROPERTIES {target_table_fqn} ('{SNAPSHOT_PROPERTY}')"
        ).collect()
        if rows and rows[0]["value"] != f"Table {target_table_fqn} does not have property: {SNAPSHOT_PROPERTY}":
            return int(rows[0]["value"])
    except Exception:
        pass
    return None


def set_last_processed_snapshot(spark, target_table_fqn, snapshot_id):
    """Persist the watermark snapshot ID as a table property."""
    spark.sql(
        f"ALTER TABLE {target_table_fqn} SET TBLPROPERTIES ('{SNAPSHOT_PROPERTY}' = '{snapshot_id}')"
    )
    print(f"Watermark set: {target_table_fqn}.{SNAPSHOT_PROPERTY} = {snapshot_id}")


def read_incremental(spark, source_table_fqn, start_snapshot, end_snapshot):
    """Read only the rows added between two Iceberg snapshots."""
    return (
        spark.read.format("iceberg")
        .option("start-snapshot-id", str(start_snapshot))
        .option("end-snapshot-id", str(end_snapshot))
        .load(source_table_fqn)
    )


def assert_quality(df, table_name, checks):
    """Lightweight data quality gate — fails the job if any check fails."""
    for check_name, condition in checks.items():
        if not condition:
            raise ValueError(f"DQ FAILED [{table_name}]: {check_name}")
    print(f"DQ PASSED [{table_name}]: {list(checks.keys())}")
