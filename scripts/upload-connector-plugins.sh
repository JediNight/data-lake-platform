#!/usr/bin/env bash
# scripts/upload-connector-plugins.sh
# Downloads Debezium + Iceberg connector JARs and uploads to S3.
set -euo pipefail

ENV="${1:?Usage: $0 <environment>}"
BUCKET="datalake-msk-connect-plugins-${ENV}"
DEBEZIUM_VERSION="2.5.0.Final"
ICEBERG_VERSION="1.8.1"
TMP_DIR=$(mktemp -d)

echo "==> Downloading Debezium PostgreSQL connector ${DEBEZIUM_VERSION}"
curl -sL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz" \
  -o "${TMP_DIR}/debezium-plugin.tar.gz"

echo "==> Downloading Iceberg Kafka Connect runtime ${ICEBERG_VERSION}"
curl -sL "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-kafka-connect-runtime/${ICEBERG_VERSION}/iceberg-kafka-connect-runtime-${ICEBERG_VERSION}.jar" \
  -o "${TMP_DIR}/iceberg-sink.jar"

echo "==> Uploading to s3://${BUCKET}/"
aws s3 cp "${TMP_DIR}/debezium-plugin.tar.gz" \
  "s3://${BUCKET}/debezium-postgres/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"
aws s3 cp "${TMP_DIR}/iceberg-sink.jar" \
  "s3://${BUCKET}/iceberg-sink/iceberg-kafka-connect-runtime-${ICEBERG_VERSION}.jar"

echo "==> Done. Plugins uploaded to s3://${BUCKET}/"
rm -rf "${TMP_DIR}"
