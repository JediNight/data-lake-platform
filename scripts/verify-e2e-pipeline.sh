#!/usr/bin/env bash
# scripts/verify-e2e-pipeline.sh
# End-to-end pipeline verification: Lambda → Aurora → Debezium → MSK → Iceberg → S3
#
# Invokes the trading simulator Lambda, waits for the Iceberg sink commit cycle,
# and verifies new data landed in S3.
#
# Prerequisites: aws CLI, authenticated AWS profile
# Usage: ./scripts/verify-e2e-pipeline.sh [environment]
set -euo pipefail

ENV="${1:-prod}"
AWS_PROFILE="${AWS_PROFILE:-data-lake}"
export AWS_PROFILE

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
PASSED=0
FAILED=0

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------
check() {
  local name="$1"
  shift
  printf "  %-55s" "$name"
  if output=$("$@" 2>&1); then
    printf "${GREEN}[PASS]${NC}\n"
    PASSED=$((PASSED + 1))
  else
    printf "${RED}[FAIL]${NC}\n"
    if [ -n "$output" ]; then
      echo "    $output" | head -3
    fi
    FAILED=$((FAILED + 1))
  fi
}

echo "================================================"
echo "  Data Lake Platform — E2E Pipeline Verification"
echo "  Environment: ${ENV}"
echo "================================================"
echo ""

# =========================================================================
# Phase 1: Pre-flight — verify all components are healthy
# =========================================================================
echo "--- Phase 1: Pre-flight checks ---"

check "AWS credentials valid" \
  aws sts get-caller-identity --output text

check "Aurora cluster available" \
  bash -c 'STATUS=$(aws rds describe-db-clusters --db-cluster-identifier "datalake-'"${ENV}"'" --query "DBClusters[0].Status" --output text); [ "$STATUS" = "available" ]'

check "Debezium source connector RUNNING" \
  bash -c 'STATE=$(aws kafkaconnect list-connectors --query "connectors[?connectorName==\`debezium-source-'"${ENV}"'\`].connectorState" --output text); [ "$STATE" = "RUNNING" ]'

check "Iceberg sink MNPI connector RUNNING" \
  bash -c 'STATE=$(aws kafkaconnect list-connectors --query "connectors[?connectorName==\`iceberg-sink-mnpi-'"${ENV}"'\`].connectorState" --output text); [ "$STATE" = "RUNNING" ]'

check "Iceberg sink non-MNPI connector RUNNING" \
  bash -c 'STATE=$(aws kafkaconnect list-connectors --query "connectors[?connectorName==\`iceberg-sink-nonmnpi-'"${ENV}"'\`].connectorState" --output text); [ "$STATE" = "RUNNING" ]'

check "Debezium replication slot active" \
  bash -c '
    CLUSTER_ARN=$(aws rds describe-db-clusters --db-cluster-identifier "datalake-'"${ENV}"'" --query "DBClusters[0].DBClusterArn" --output text)
    SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "datalake/aurora/'"${ENV}"'/master-password" --query ARN --output text)
    RESULT=$(aws rds-data execute-statement --resource-arn "$CLUSTER_ARN" --secret-arn "$SECRET_ARN" --database trading --sql "SELECT active FROM pg_replication_slots WHERE slot_name='"'"'debezium_slot'"'"'" --output text)
    echo "$RESULT" | grep -q "True"'

echo ""

# =========================================================================
# Phase 2: Snapshot baseline — count current Iceberg data files
# =========================================================================
echo "--- Phase 2: Baseline snapshot ---"

BEFORE_COUNT=$(aws s3 ls "s3://datalake-mnpi-${ENV}/raw/orders/data/" 2>/dev/null | wc -l | tr -d ' ')
echo "  Orders data files before: ${BEFORE_COUNT}"

BEFORE_TRADES=$(aws s3 ls "s3://datalake-mnpi-${ENV}/raw/trades/data/" 2>/dev/null | wc -l | tr -d ' ')
echo "  Trades data files before: ${BEFORE_TRADES}"

BEFORE_MARKET=$(aws s3 ls "s3://datalake-nonmnpi-${ENV}/raw/market_data/data/" 2>/dev/null | wc -l | tr -d ' ')
echo "  Market data files before: ${BEFORE_MARKET}"

echo ""

# =========================================================================
# Phase 3: Invoke Lambda trading simulator
# =========================================================================
echo "--- Phase 3: Invoking Lambda trading simulator ---"

LAMBDA_TMPFILE=$(mktemp)
trap "rm -f $LAMBDA_TMPFILE" EXIT

aws lambda invoke \
  --function-name "datalake-trading-simulator-${ENV}" \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  "$LAMBDA_TMPFILE" > /dev/null 2>&1

LAMBDA_OUTPUT=$(cat "$LAMBDA_TMPFILE")

ORDER_ID=$(echo "$LAMBDA_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('order_id','?'))" 2>/dev/null || echo "?")
TRADE_ID=$(echo "$LAMBDA_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('trade_id','?'))" 2>/dev/null || echo "?")
TICKER=$(echo "$LAMBDA_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ticker','?'))" 2>/dev/null || echo "?")
SIDE=$(echo "$LAMBDA_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('side','?'))" 2>/dev/null || echo "?")
PRICE=$(echo "$LAMBDA_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('price','?'))" 2>/dev/null || echo "?")

echo "  Lambda response:"
echo "    order_id=${ORDER_ID}  trade_id=${TRADE_ID}"
echo "    ${TICKER} ${SIDE} @ ${PRICE}"

check "Lambda invocation succeeded" \
  bash -c '[ "'"${ORDER_ID}"'" != "?" ]'

echo ""

# =========================================================================
# Phase 4: Verify record in Aurora (immediate — no wait)
# =========================================================================
echo "--- Phase 4: Verify record in Aurora ---"

CLUSTER_ARN=$(aws rds describe-db-clusters --db-cluster-identifier "datalake-${ENV}" \
  --query 'DBClusters[0].DBClusterArn' --output text)
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "datalake/aurora/${ENV}/master-password" --query ARN --output text)

check "Order ${ORDER_ID} persisted in Aurora" \
  bash -c '
    RESULT=$(aws rds-data execute-statement \
      --resource-arn "'"${CLUSTER_ARN}"'" --secret-arn "'"${SECRET_ARN}"'" \
      --database trading \
      --sql "SELECT count(*) FROM orders WHERE order_id = '"${ORDER_ID}"'" \
      --output text)
    echo "$RESULT" | grep -qv "^0$"'

check "Trade ${TRADE_ID} persisted in Aurora" \
  bash -c '
    RESULT=$(aws rds-data execute-statement \
      --resource-arn "'"${CLUSTER_ARN}"'" --secret-arn "'"${SECRET_ARN}"'" \
      --database trading \
      --sql "SELECT count(*) FROM trades WHERE trade_id = '"${TRADE_ID}"'" \
      --output text)
    echo "$RESULT" | grep -qv "^0$"'

echo ""

# =========================================================================
# Phase 5: Wait for Iceberg sink commit cycle (2 minutes)
# =========================================================================
echo "--- Phase 5: Waiting for Iceberg sink commit cycle ---"
echo "  Iceberg commit interval: 120 seconds"
echo "  Adding 15s buffer for propagation..."
echo ""

WAIT_SECS=135
for ((i=WAIT_SECS; i>0; i-=15)); do
  printf "  %3ds remaining...\r" "$i"
  sleep 15
done
echo "  Done waiting.              "
echo ""

# =========================================================================
# Phase 6: Verify new data in S3 (Iceberg tables)
# =========================================================================
echo "--- Phase 6: Verify new data in S3 ---"

AFTER_COUNT=$(aws s3 ls "s3://datalake-mnpi-${ENV}/raw/orders/data/" 2>/dev/null | wc -l | tr -d ' ')
AFTER_TRADES=$(aws s3 ls "s3://datalake-mnpi-${ENV}/raw/trades/data/" 2>/dev/null | wc -l | tr -d ' ')
AFTER_MARKET=$(aws s3 ls "s3://datalake-nonmnpi-${ENV}/raw/market_data/data/" 2>/dev/null | wc -l | tr -d ' ')

echo "  Orders data files:      ${BEFORE_COUNT} → ${AFTER_COUNT}"
echo "  Trades data files:      ${BEFORE_TRADES} → ${AFTER_TRADES}"
echo "  Market data data files: ${BEFORE_MARKET} → ${AFTER_MARKET}"

check "New orders Parquet file in S3" \
  bash -c '[ '"${AFTER_COUNT}"' -gt '"${BEFORE_COUNT}"' ]'

check "New trades Parquet file in S3" \
  bash -c '[ '"${AFTER_TRADES}"' -gt '"${BEFORE_TRADES}"' ]'

check "New market data Parquet file in S3" \
  bash -c '[ '"${AFTER_MARKET}"' -gt '"${BEFORE_MARKET}"' ]'

echo ""

# =========================================================================
# Summary
# =========================================================================
TOTAL=$((PASSED + FAILED))
echo "================================================"
printf "  Results: ${GREEN}%d passed${NC}" "$PASSED"
if [ "$FAILED" -gt 0 ]; then
  printf ", ${RED}%d failed${NC}" "$FAILED"
fi
echo " / ${TOTAL} total"
echo ""
echo "  Pipeline: Lambda → Aurora → Debezium → MSK → Iceberg → S3"
if [ "$FAILED" -eq 0 ]; then
  echo -e "  Status:   ${GREEN}ALL CHECKS PASSED${NC}"
else
  echo -e "  Status:   ${RED}${FAILED} CHECK(S) FAILED${NC}"
fi
echo "================================================"

exit "$FAILED"
