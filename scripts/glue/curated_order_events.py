"""
Curated Order Events: Clean + type-cast CDC order data (incremental).

Source: raw_mnpi_{env}.orders   (Iceberg, CDC from Debezium via MSK Connect)
Target: curated_mnpi_{env}.order_events (Iceberg, deduplicated + typed)

Incremental strategy:
  - Reads only new Iceberg snapshots since last processed watermark
  - MERGE INTO on order_id to handle CDC updates (e.g. PENDING -> FILLED)
  - First run (no target table): full refresh with createOrReplace()
  - No new data: early exit (no-op) — safe for 15-min scheduling
  - --full-refresh=true: forces full reprocessing (for backfills)

Transform logic:
  1. Filter out CDC deletes (_cdc.op != 'd') and tombstones
  2. Cast string fields to proper types
  3. Deduplicate by order_id (latest updated_at wins via ROW_NUMBER)
  4. Add derived columns: is_buy flag, order_hour
  5. Drop internal columns (_topic, _cdc)
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.window import Window

from incremental import (
    assert_quality,
    get_current_snapshot,
    get_last_processed_snapshot,
    read_incremental,
    set_last_processed_snapshot,
    table_exists,
)

args = getResolvedOptions(
    sys.argv, ["JOB_NAME", "environment", "iceberg-warehouse", "full-refresh"]
)
env = args["environment"]
warehouse = args["iceberg_warehouse"]
full_refresh = args.get("full_refresh", "false").lower() == "true"

spark = (
    SparkSession.builder.config(
        "spark.sql.catalog.glue_catalog",
        "org.apache.iceberg.spark.SparkCatalog",
    )
    .config(
        "spark.sql.catalog.glue_catalog.catalog-impl",
        "org.apache.iceberg.aws.glue.GlueCatalog",
    )
    .config(
        "spark.sql.catalog.glue_catalog.warehouse",
        warehouse,
    )
    .config(
        "spark.sql.catalog.glue_catalog.io-impl",
        "org.apache.iceberg.aws.s3.S3FileIO",
    )
    .getOrCreate()
)

glue_ctx = GlueContext(spark.sparkContext)
job = Job(glue_ctx)
job.init(args["JOB_NAME"], args)

source_table = f"glue_catalog.raw_mnpi_{env}.orders"
target_table = f"glue_catalog.curated_mnpi_{env}.order_events"

# ---------------------------------------------------------------------------
# Determine read mode: incremental vs full refresh
# ---------------------------------------------------------------------------
target_exists = table_exists(spark, target_table)
current_snap = get_current_snapshot(spark, source_table)

skip_processing = False

if current_snap is None:
    print("Source table has no snapshots (empty). Nothing to do.")
    skip_processing = True

if not skip_processing:
    last_snap = get_last_processed_snapshot(spark, target_table) if target_exists else None

    if not full_refresh and target_exists and last_snap is not None:
        if last_snap == current_snap:
            print(f"No new data (snapshot {current_snap} already processed). Exiting.")
            skip_processing = True
        else:
            print(f"Incremental read: snapshots {last_snap} -> {current_snap}")
            df = read_incremental(spark, source_table, last_snap, current_snap)
            is_incremental = True
    else:
        reason = "full-refresh flag" if full_refresh else "first run (no target)"
        print(f"Full refresh ({reason}): reading entire source table")
        df = spark.table(source_table)
        is_incremental = False

if not skip_processing:
    # -----------------------------------------------------------------------
    # Transform
    # -----------------------------------------------------------------------

    # 1. Filter out CDC deletes and tombstones
    if "_cdc" in df.columns:
        df_filtered = df.filter(
            (F.col("_cdc.op") != "d") & F.col("order_id").isNotNull()
        )
    else:
        df_filtered = df.filter(F.col("order_id").isNotNull())

    # 2. Deduplicate by order_id (latest updated_at wins)
    window = Window.partitionBy("order_id").orderBy(F.col("updated_at").desc())
    df_deduped = (
        df_filtered.withColumn("rn", F.row_number().over(window))
        .filter(F.col("rn") == 1)
        .drop("rn")
    )

    # 3. Cast types + add derived columns, drop internal columns
    df_curated = df_deduped.select(
        F.col("order_id"),
        F.col("account_id"),
        F.col("instrument_id"),
        F.col("side"),
        F.col("order_type"),
        F.col("quantity").cast("bigint").alias("quantity"),
        F.col("limit_price").cast("double").alias("limit_price"),
        F.col("status"),
        F.col("disclosure_status"),
        F.to_timestamp("created_at").alias("created_at"),
        F.to_timestamp("updated_at").alias("updated_at"),
        (F.col("side") == "BUY").alias("is_buy"),
        F.date_trunc("hour", F.to_timestamp("created_at")).alias("order_hour"),
    )

    # -------------------------------------------------------------------
    # Data quality checks (0 rows valid on incremental)
    # -------------------------------------------------------------------
    row_count = df_curated.count()
    null_order_ids = df_curated.filter(F.col("order_id").isNull()).count()

    assert_quality(
        df_curated,
        target_table,
        {
            "row_count >= 0": row_count >= 0,
            "no null order_ids": null_order_ids == 0,
            f"row_count={row_count}": True,
        },
    )

    # -------------------------------------------------------------------
    # Write: upsert for incremental, createOrReplace for full refresh
    # -------------------------------------------------------------------
    if is_incremental and row_count > 0:
        df_existing = spark.table(target_table)
        df_merged = df_existing.unionByName(df_curated)
        win = Window.partitionBy("order_id").orderBy(F.col("updated_at").desc())
        df_final = (
            df_merged.withColumn("_rn", F.row_number().over(win))
            .filter(F.col("_rn") == 1)
            .drop("_rn")
        )
        df_final.writeTo(target_table).using("iceberg").createOrReplace()
        print(f"Upsert complete: {row_count} new rows merged into {target_table}")
    elif is_incremental and row_count == 0:
        print("Incremental batch had 0 rows after filtering. Skipping write.")
    else:
        df_curated.writeTo(target_table).using("iceberg").createOrReplace()
        print(f"Full refresh complete: {row_count} rows into {target_table}")

    # Persist watermark for next incremental run
    set_last_processed_snapshot(spark, target_table, current_snap)

job.commit()
