#!/usr/bin/env bash
# scripts/upload-connector-plugins.sh
# Downloads Debezium connector and assembles Iceberg Kafka Connect plugin
# from stable Maven Central JARs, then uploads both to the MSK Connect
# plugins S3 bucket.
#
# Prerequisites: curl, zip, aws CLI
set -euo pipefail

ENV="${1:?Usage: $0 <environment>}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="datalake-msk-connect-plugins-${ACCOUNT_ID}-${ENV}"
DEBEZIUM_VERSION="2.5.0.Final"
ICEBERG_VERSION="1.9.2"
HADOOP_VERSION="3.4.1"
FAILSAFE_VERSION="3.3.2"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

MAVEN="https://repo1.maven.org/maven2"

# =============================================================================
# Debezium PostgreSQL Connector
# =============================================================================
echo "==> Downloading Debezium PostgreSQL connector ${DEBEZIUM_VERSION}"
curl -sL "${MAVEN}/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz" \
  -o "${TMP_DIR}/debezium-plugin.tar.gz"

echo "==> Repackaging Debezium plugin as ZIP (MSK Connect requires ZIP, not tar.gz)"
mkdir -p "${TMP_DIR}/debezium-extracted"
tar xzf "${TMP_DIR}/debezium-plugin.tar.gz" -C "${TMP_DIR}/debezium-extracted"
(cd "${TMP_DIR}/debezium-extracted" && zip -qr "${TMP_DIR}/debezium-plugin.zip" .)
echo "    ZIP created: $(du -h "${TMP_DIR}/debezium-plugin.zip" | cut -f1)"

# =============================================================================
# Iceberg Kafka Connect Plugin (assembled from Maven Central JARs)
# =============================================================================
# Instead of building from source (which produces SNAPSHOT artifacts),
# download stable release JARs directly from Maven Central. This matches
# the JAR set proven in dev (Strimzi Dockerfile.connect).
echo "==> Assembling Iceberg Kafka Connect plugin from Maven Central JARs"
ICEBERG_DIR="${TMP_DIR}/iceberg-sink"
mkdir -p "${ICEBERG_DIR}"

JARS=(
  # Core Iceberg Kafka Connect connector
  "org/apache/iceberg/iceberg-kafka-connect/${ICEBERG_VERSION}/iceberg-kafka-connect-${ICEBERG_VERSION}.jar"
  # Iceberg core + API
  "org/apache/iceberg/iceberg-core/${ICEBERG_VERSION}/iceberg-core-${ICEBERG_VERSION}.jar"
  "org/apache/iceberg/iceberg-api/${ICEBERG_VERSION}/iceberg-api-${ICEBERG_VERSION}.jar"
  "org/apache/iceberg/iceberg-common/${ICEBERG_VERSION}/iceberg-common-${ICEBERG_VERSION}.jar"
  "org/apache/iceberg/iceberg-data/${ICEBERG_VERSION}/iceberg-data-${ICEBERG_VERSION}.jar"
  # Bundled Guava (relocated under org.apache.iceberg.relocated.com.google.common.*)
  # Required by iceberg-core — without this: NoClassDefFoundError on Resources
  "org/apache/iceberg/iceberg-bundled-guava/${ICEBERG_VERSION}/iceberg-bundled-guava-${ICEBERG_VERSION}.jar"
  # AWS integration (S3FileIO, GlueCatalog)
  "org/apache/iceberg/iceberg-aws/${ICEBERG_VERSION}/iceberg-aws-${ICEBERG_VERSION}.jar"
  "org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar"
  # Parquet support (default Iceberg file format)
  "org/apache/iceberg/iceberg-parquet/${ICEBERG_VERSION}/iceberg-parquet-${ICEBERG_VERSION}.jar"
  # Iceberg Kafka Connect events (control topic protocol)
  "org/apache/iceberg/iceberg-kafka-connect-events/${ICEBERG_VERSION}/iceberg-kafka-connect-events-${ICEBERG_VERSION}.jar"
  # Iceberg Kafka Connect transforms (DebeziumTransform, DmsTransform, etc.)
  # Added in Iceberg 1.9.0 as a separate module
  "org/apache/iceberg/iceberg-kafka-connect-transforms/${ICEBERG_VERSION}/iceberg-kafka-connect-transforms-${ICEBERG_VERSION}.jar"
  # Hadoop client (needed by Iceberg FileIO)
  "org/apache/hadoop/hadoop-client-api/${HADOOP_VERSION}/hadoop-client-api-${HADOOP_VERSION}.jar"
  "org/apache/hadoop/hadoop-client-runtime/${HADOOP_VERSION}/hadoop-client-runtime-${HADOOP_VERSION}.jar"
  # Failsafe (retry/circuit-breaker for S3FileIO)
  "dev/failsafe/failsafe/${FAILSAFE_VERSION}/failsafe-${FAILSAFE_VERSION}.jar"
  # Avro (used by Iceberg core for schema serialization)
  "org/apache/avro/avro/1.12.0/avro-1.12.0.jar"
  # Parquet libs
  "org/apache/parquet/parquet-avro/1.15.0/parquet-avro-1.15.0.jar"
  "org/apache/parquet/parquet-column/1.15.0/parquet-column-1.15.0.jar"
  "org/apache/parquet/parquet-common/1.15.0/parquet-common-1.15.0.jar"
  "org/apache/parquet/parquet-encoding/1.15.0/parquet-encoding-1.15.0.jar"
  "org/apache/parquet/parquet-format-structures/1.15.0/parquet-format-structures-1.15.0.jar"
  "org/apache/parquet/parquet-hadoop/1.15.0/parquet-hadoop-1.15.0.jar"
  "org/apache/parquet/parquet-jackson/1.15.0/parquet-jackson-1.15.0.jar"
)

for jar_path in "${JARS[@]}"; do
  jar_name=$(basename "${jar_path}")
  echo "    Downloading ${jar_name}"
  curl -sfL "${MAVEN}/${jar_path}" -o "${ICEBERG_DIR}/${jar_name}" || {
    echo "    WARN: Failed to download ${jar_name}, skipping"
    continue
  }
done

echo "==> Packaging Iceberg plugin as ZIP"
(cd "${TMP_DIR}" && zip -qr "${TMP_DIR}/iceberg-plugin.zip" iceberg-sink/)
echo "    ZIP created: $(du -h "${TMP_DIR}/iceberg-plugin.zip" | cut -f1) ($(ls "${ICEBERG_DIR}" | wc -l | tr -d ' ') JARs)"

# =============================================================================
# Upload to S3
# =============================================================================
echo "==> Uploading to s3://${BUCKET}/"
aws s3 cp "${TMP_DIR}/debezium-plugin.zip" \
  "s3://${BUCKET}/debezium-postgres/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.zip"
aws s3 cp "${TMP_DIR}/iceberg-plugin.zip" \
  "s3://${BUCKET}/iceberg-sink/iceberg-kafka-connect-runtime-${ICEBERG_VERSION}.zip"

echo "==> Done. Plugins uploaded to s3://${BUCKET}/"
echo "    Debezium: debezium-postgres/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.zip"
echo "    Iceberg:  iceberg-sink/iceberg-kafka-connect-runtime-${ICEBERG_VERSION}.zip"
