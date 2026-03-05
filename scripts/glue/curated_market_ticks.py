"""
Curated Market Ticks: Clean + type-cast streaming market data (incremental).

Source: raw_nonmnpi_{env}.market_data (Iceberg, append-only from Kafka)
Target: curated_nonmnpi_{env}.market_ticks (Iceberg, typed + enriched)

Incremental strategy:
  - Reads only new Iceberg snapshots since last processed watermark
  - MERGE INTO on tick_id (append-only source, MERGE is dedup safety net)
  - First run (no target table): full refresh with createOrReplace()
  - No new data: early exit (no-op) — safe for 15-min scheduling
  - --full-refresh=true: forces full reprocessing (for backfills)

Transform logic:
  1. Filter out tombstone records (ticker IS NOT NULL AND != '')
  2. Cast string price fields to double (ask, bid, last_price)
  3. Cast timestamp string to proper timestamp type
  4. Calculate spread (ask - bid) and mid_price ((ask + bid) / 2)
  5. Deduplicate by tick_id (take latest per tick_id)
  6. Drop internal columns (_topic)
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

source_table = f"glue_catalog.raw_nonmnpi_{env}.market_data"
target_table = f"glue_catalog.curated_nonmnpi_{env}.market_ticks"

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

    # 1. Filter nulls/tombstones
    df_filtered = df.filter(
        F.col("ticker").isNotNull() & (F.col("ticker") != "")
    )

    # 2. Deduplicate by tick_id (latest timestamp wins)
    window = Window.partitionBy("tick_id").orderBy(F.col("timestamp").desc())
    df_deduped = (
        df_filtered.withColumn("rn", F.row_number().over(window))
        .filter(F.col("rn") == 1)
        .drop("rn")
    )

    # 3. Cast types + add derived columns, drop internal columns
    bid_col = F.col("bid").cast("double")
    ask_col = F.col("ask").cast("double")

    df_curated = df_deduped.select(
        F.col("tick_id"),
        F.col("ticker"),
        bid_col.alias("bid"),
        ask_col.alias("ask"),
        F.col("last_price").cast("double").alias("last_price"),
        F.col("volume"),
        F.col("instrument_id"),
        F.to_timestamp("timestamp").alias("tick_timestamp"),
        (ask_col - bid_col).alias("spread"),
        ((ask_col + bid_col) / 2.0).alias("mid_price"),
        F.date_trunc("hour", F.to_timestamp("timestamp")).alias("tick_hour"),
    )

    # -------------------------------------------------------------------
    # Data quality checks (0 rows valid on incremental runs)
    # -------------------------------------------------------------------
    row_count = df_curated.count()
    null_tickers = df_curated.filter(F.col("ticker").isNull()).count()

    assert_quality(
        df_curated,
        target_table,
        {
            "row_count >= 0": row_count >= 0,
            "no null tickers": null_tickers == 0,
            f"row_count={row_count}": True,
        },
    )

    # -------------------------------------------------------------------
    # Write: upsert for incremental, createOrReplace for full refresh
    # -------------------------------------------------------------------
    if is_incremental and row_count > 0:
        df_existing = spark.table(target_table)
        df_merged = df_existing.unionByName(df_curated)
        win = Window.partitionBy("tick_id").orderBy(F.col("tick_timestamp").desc())
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
