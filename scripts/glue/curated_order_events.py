"""
Curated Order Events: Clean + type-cast streaming order events.

Source: raw_mnpi_{env}.mnpi_events   (Iceberg, append-only from Kafka)
Target: curated_mnpi_{env}.order_events (Iceberg, deduplicated + typed)

Transform logic:
  1. Filter out empty/tombstone records (ticker IS NOT NULL AND != '')
  2. Cast string fields to proper types (quantity -> bigint, timestamp -> timestamp)
  3. Deduplicate by event_id (take latest per event_id via ROW_NUMBER)
  4. Add derived columns: is_buy flag, event_hour for partitioning
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

# --- Read raw MNPI events ---
source_table = f"glue_catalog.raw_mnpi_{env}.mnpi_events"
df = spark.table(source_table)

# 1. Filter nulls/tombstones
df_filtered = df.filter(
    F.col("ticker").isNotNull()
    & (F.col("ticker") != "")
    & F.col("event_type").isNotNull()
    & (F.col("event_type") != "")
)

# 2. Deduplicate by event_id (latest timestamp wins)
window = Window.partitionBy("event_id").orderBy(F.col("timestamp").desc())
df_deduped = df_filtered.withColumn("rn", F.row_number().over(window)).filter(
    F.col("rn") == 1
).drop("rn")

# 3. Cast types + add derived columns
df_curated = df_deduped.select(
    F.col("event_id"),
    F.col("event_type"),
    F.col("ticker"),
    F.col("side"),
    F.col("quantity").cast("bigint").alias("quantity"),
    F.col("order_id"),
    F.col("account_id"),
    F.col("instrument_id"),
    F.to_timestamp("timestamp").alias("event_timestamp"),
    (F.col("side") == "BUY").alias("is_buy"),
    F.date_trunc("hour", F.to_timestamp("timestamp")).alias("event_hour"),
)

# 4. Data quality checks
target_table = f"glue_catalog.curated_mnpi_{env}.order_events"

row_count = df_curated.count()
null_event_ids = df_curated.filter(F.col("event_id").isNull()).count()

assert_quality(df_curated, target_table, {
    "row_count > 0": row_count > 0,
    "no null event_ids": null_event_ids == 0,
    f"row_count={row_count}": True,
})

# 5. Write to curated Iceberg table (overwrite for full refresh)
df_curated.writeTo(target_table).using("iceberg").createOrReplace()

job.commit()
