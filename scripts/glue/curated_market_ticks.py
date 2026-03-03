"""
Curated Market Ticks: Clean + type-cast streaming market data.

Source: raw_nonmnpi_{env}.market_data (Iceberg, append-only from Kafka)
Target: curated_nonmnpi_{env}.market_ticks (Iceberg, typed + enriched)

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

# --- Read raw market data ---
source_table = f"glue_catalog.raw_nonmnpi_{env}.market_data"
df = spark.table(source_table)

# 1. Filter nulls/tombstones
df_filtered = df.filter(
    F.col("ticker").isNotNull() & (F.col("ticker") != "")
)

# 2. Deduplicate by tick_id (latest timestamp wins)
window = Window.partitionBy("tick_id").orderBy(F.col("timestamp").desc())
df_deduped = df_filtered.withColumn("rn", F.row_number().over(window)).filter(
    F.col("rn") == 1
).drop("rn")

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

# 4. Data quality checks
target_table = f"glue_catalog.curated_nonmnpi_{env}.market_ticks"

row_count = df_curated.count()
null_tickers = df_curated.filter(F.col("ticker").isNull()).count()

assert_quality(df_curated, target_table, {
    "row_count > 0": row_count > 0,
    "no null tickers": null_tickers == 0,
    f"row_count={row_count}": True,
})

# 5. Write to curated Iceberg table (overwrite for full refresh)
df_curated.writeTo(target_table).using("iceberg").createOrReplace()

job.commit()
