"""
Analytics: Market Data Summary per Ticker.

Source: curated_nonmnpi_{env}.market_ticks
Target: analytics_nonmnpi_{env}.market_summary (Iceberg, pre-aggregated)

Business metrics:
  - Price range (low, high, average)
  - Average spread and mid-price
  - Total volume and tick count
  - Spread as percentage of mid-price (liquidity indicator)
  - First and last tick timestamps
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession
from pyspark.sql import functions as F



def assert_quality(df, table_name, checks):
    """Lightweight data quality gate — fails the job if any check fails."""
    for check_name, condition in checks.items():
        if not condition:
            raise ValueError(f"DQ FAILED [{table_name}]: {check_name}")
    print(f"DQ PASSED [{table_name}]: {list(checks.keys())}")


args = getResolvedOptions(sys.argv, ["JOB_NAME", "environment", "iceberg-warehouse"])
env = args["environment"]
warehouse = args["iceberg_warehouse"]

# Register the Iceberg catalog backed by AWS Glue Data Catalog.
# --datalake-formats=iceberg only adds the JARs; the named catalog
# must be registered explicitly so spark.table("glue_catalog.db.table") works.
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

# --- Read curated market ticks ---
source_table = f"glue_catalog.curated_nonmnpi_{env}.market_ticks"
df = spark.table(source_table)

# --- Aggregate per ticker ---
avg_spread = F.avg("spread")
avg_mid = F.avg("mid_price")

df_summary = df.groupBy("ticker").agg(
    F.count("*").alias("tick_count"),
    F.sum("volume").alias("total_volume"),
    F.round(F.min("last_price"), 2).alias("low_price"),
    F.round(F.max("last_price"), 2).alias("high_price"),
    F.round(F.avg("last_price"), 2).alias("avg_price"),
    F.round(avg_spread, 4).alias("avg_spread"),
    F.round(avg_mid, 2).alias("avg_mid_price"),
    F.round(
        avg_spread / F.when(avg_mid != 0, avg_mid) * 100,
        4,
    ).alias("spread_pct"),
    F.min("tick_timestamp").alias("first_tick_at"),
    F.max("tick_timestamp").alias("last_tick_at"),
)

# --- Data quality checks ---
target_table = f"glue_catalog.analytics_nonmnpi_{env}.market_summary"

row_count = df_summary.count()

assert_quality(df_summary, target_table, {
    "row_count > 0": row_count > 0,
    f"row_count={row_count}": True,
})

# --- Write to analytics Iceberg table (overwrite for full refresh) ---
df_summary.writeTo(target_table).using("iceberg").createOrReplace()

job.commit()
