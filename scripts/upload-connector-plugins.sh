#!/usr/bin/env bash
# scripts/upload-connector-plugins.sh
# Downloads Debezium connector and builds Iceberg Kafka Connect runtime,
# then uploads both to the MSK Connect plugins S3 bucket.
#
# Prerequisites: Java 17+, git, curl, aws CLI
set -euo pipefail

ENV="${1:?Usage: $0 <environment>}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="datalake-msk-connect-plugins-${ACCOUNT_ID}-${ENV}"
DEBEZIUM_VERSION="2.5.0.Final"
ICEBERG_VERSION="1.8.1"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> Downloading Debezium PostgreSQL connector ${DEBEZIUM_VERSION}"
curl -sL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz" \
  -o "${TMP_DIR}/debezium-plugin.tar.gz"

echo "==> Repackaging Debezium plugin as ZIP (MSK Connect requires ZIP, not tar.gz)"
mkdir -p "${TMP_DIR}/debezium-extracted"
tar xzf "${TMP_DIR}/debezium-plugin.tar.gz" -C "${TMP_DIR}/debezium-extracted"
(cd "${TMP_DIR}/debezium-extracted" && zip -qr "${TMP_DIR}/debezium-plugin.zip" .)
echo "    ZIP created: $(du -h "${TMP_DIR}/debezium-plugin.zip" | cut -f1)"

echo "==> Building Iceberg Kafka Connect runtime ${ICEBERG_VERSION} from source"
echo "    (runtime ZIP is not published to Maven Central — must build from source)"
git clone --depth 1 --branch "apache-iceberg-${ICEBERG_VERSION}" \
  https://github.com/apache/iceberg.git "${TMP_DIR}/iceberg"
(cd "${TMP_DIR}/iceberg" && \
  ./gradlew :iceberg-kafka-connect:iceberg-kafka-connect-runtime:distZip \
    -x test -x integrationTest --quiet)
ICEBERG_ZIP=$(ls "${TMP_DIR}"/iceberg/kafka-connect/kafka-connect-runtime/build/distributions/*.zip)
echo "    Built: $(basename "${ICEBERG_ZIP}") ($(du -h "${ICEBERG_ZIP}" | cut -f1))"

echo "==> Uploading to s3://${BUCKET}/"
aws s3 cp "${TMP_DIR}/debezium-plugin.zip" \
  "s3://${BUCKET}/debezium-postgres/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.zip"
aws s3 cp "${ICEBERG_ZIP}" \
  "s3://${BUCKET}/iceberg-sink/iceberg-kafka-connect-runtime-${ICEBERG_VERSION}.zip"

echo "==> Done. Plugins uploaded to s3://${BUCKET}/"
