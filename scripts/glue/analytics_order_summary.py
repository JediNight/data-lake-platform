"""
Analytics: Order Activity Summary per Instrument per Hour.

Source: curated_mnpi_{env}.order_events
Target: analytics_mnpi_{env}.order_summary (Iceberg, pre-aggregated)

Business metrics (per instrument per hour):
  - Total orders, buy/sell split, volume per instrument
  - Average order size
  - Buy/sell ratio (values > 1 = net buying pressure)
  - First and last order timestamps

QuickSight can roll up across hours for all-time view, or slice by
order_hour for intraday trend analysis and trading heat maps.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

from incremental import assert_quality

args = getResolvedOptions(sys.argv, ["JOB_NAME", "environment", "iceberg-warehouse"])
env = args["environment"]
warehouse = args["iceberg_warehouse"]

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

# --- Read curated order events ---
source_table = f"glue_catalog.curated_mnpi_{env}.order_events"
df = spark.table(source_table)

# --- Aggregate per instrument per hour ---
df_summary = df.groupBy("instrument_id", "order_hour").agg(
    F.count("*").alias("total_orders"),
    F.count(F.when(F.col("is_buy"), 1)).alias("buy_orders"),
    F.count(F.when(~F.col("is_buy"), 1)).alias("sell_orders"),
    F.sum("quantity").alias("total_volume"),
    F.round(F.avg("quantity"), 0).cast("bigint").alias("avg_order_size"),
    F.round(
        F.count(F.when(F.col("is_buy"), 1)).cast("double")
        / F.when(
            F.count(F.when(~F.col("is_buy"), 1)) > 0,
            F.count(F.when(~F.col("is_buy"), 1)),
        ).cast("double"),
        2,
    ).alias("buy_sell_ratio"),
    F.min("created_at").alias("first_order_at"),
    F.max("created_at").alias("last_order_at"),
)

# --- Data quality checks ---
target_table = f"glue_catalog.analytics_mnpi_{env}.order_summary"

row_count = df_summary.count()

assert_quality(
    df_summary,
    target_table,
    {
        "row_count > 0": row_count > 0,
        f"row_count={row_count}": True,
    },
)

# --- Write to analytics Iceberg table (full recompute from curated) ---
df_summary.writeTo(target_table).using("iceberg").createOrReplace()

job.commit()
