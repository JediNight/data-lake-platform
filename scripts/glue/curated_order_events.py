"""
Curated Order Events: Clean + type-cast CDC order data.

Source: raw_mnpi_{env}.orders   (Iceberg, CDC from Debezium via MSK Connect)
Target: curated_mnpi_{env}.order_events (Iceberg, deduplicated + typed)

Transform logic:
  1. Filter out CDC deletes (_cdc.op != 'd') and tombstones
  2. Cast string fields to proper types (quantity -> bigint, limit_price -> double,
     created_at/updated_at -> timestamp)
  3. Deduplicate by order_id (latest updated_at wins via ROW_NUMBER)
  4. Add derived columns: is_buy flag, order_hour for time-based analysis
  5. Drop internal columns (_topic, _cdc)
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

# --- Read raw CDC orders ---
source_table = f"glue_catalog.raw_mnpi_{env}.orders"
df = spark.table(source_table)

# 1. Filter out CDC deletes and tombstones
df_filtered = df.filter(
    (F.col("_cdc.op") != "d")
    & F.col("order_id").isNotNull()
)

# 2. Deduplicate by order_id (latest updated_at wins)
window = Window.partitionBy("order_id").orderBy(F.col("updated_at").desc())
df_deduped = df_filtered.withColumn("rn", F.row_number().over(window)).filter(
    F.col("rn") == 1
).drop("rn")

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

# 4. Data quality checks
target_table = f"glue_catalog.curated_mnpi_{env}.order_events"

row_count = df_curated.count()
null_order_ids = df_curated.filter(F.col("order_id").isNull()).count()

assert_quality(df_curated, target_table, {
    "row_count > 0": row_count > 0,
    "no null order_ids": null_order_ids == 0,
    f"row_count={row_count}": True,
})

# 5. Write to curated Iceberg table (overwrite for full refresh)
df_curated.writeTo(target_table).using("iceberg").createOrReplace()

job.commit()
