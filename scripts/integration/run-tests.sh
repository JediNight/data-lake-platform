#!/usr/bin/env bash
# Local integration tests for data-lake-platform.
# Requires: Kind cluster running with all services deployed.
# Usage: bash scripts/integration/run-tests.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & counters
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
CLUSTER_NAME="${CLUSTER_NAME:-data-lake}"
PASSED=0
FAILED=0
SKIPPED=0
PF_PIDS=()
TMPDIR_TESTS=$(mktemp -d)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    for pid in "${PF_PIDS[@]+"${PF_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$TMPDIR_TESTS"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test runner helpers
# ---------------------------------------------------------------------------
run_test() {
    local name="$1"
    shift
    printf "  %-45s" "$name"
    if output=$("$@" 2>&1); then
        printf "${GREEN}[PASS]${NC}\n"
        ((PASSED++))
    else
        printf "${RED}[FAIL]${NC}\n"
        if [ -n "$output" ]; then
            echo "    $output" | head -3
        fi
        ((FAILED++))
    fi
}

skip_test() {
    local name="$1"
    local reason="$2"
    printf "  %-45s${YELLOW}[SKIP]${NC} %s\n" "$name" "$reason"
    ((SKIPPED++))
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
echo "==========================================="
echo " Data Lake Platform - Integration Tests"
echo "==========================================="
echo ""

echo "--- Pre-flight checks ---"

# Check Kind cluster exists
if ! kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo -e "${RED}ERROR: Kind cluster '$CLUSTER_NAME' is not running.${NC}"
    echo "Run: task up"
    exit 1
fi
echo "  Kind cluster '$CLUSTER_NAME': OK"

# Check kubectl context
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null 2>&1
echo "  kubectl context: kind-$CLUSTER_NAME"

# Check namespaces have running pods
for ns in data strimzi argocd; do
    pod_count=$(kubectl -n "$ns" get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pod_count" -eq 0 ]; then
        echo -e "${RED}ERROR: No running pods in namespace '$ns'.${NC}"
        echo "Run: task status"
        exit 1
    fi
    echo "  Namespace '$ns': $pod_count running pod(s)"
done

echo ""

# ---------------------------------------------------------------------------
# Port-forward setup
# ---------------------------------------------------------------------------
echo "--- Setting up port-forwards ---"

# Producer API (8000)
kubectl -n data port-forward svc/producer-api 8000:8000 >/dev/null 2>&1 &
PF_PIDS+=($!)
echo "  producer-api → localhost:8000 (pid: ${PF_PIDS[-1]})"

# Wait for port-forward to be ready
sleep 2

# Verify port-forward is alive
if ! kill -0 "${PF_PIDS[0]}" 2>/dev/null; then
    echo -e "${RED}ERROR: Port-forward to producer-api failed.${NC}"
    exit 1
fi

echo ""

# ===========================================================================
# Tests
# ===========================================================================

# ---------------------------------------------------------------------------
# 1. Service health
# ---------------------------------------------------------------------------
echo "--- Service Health ---"

test_producer_api_health() {
    local resp
    resp=$(curl -s --max-time 5 http://localhost:8000/health)
    echo "$resp" | grep -q '"healthy"'
}

test_argocd_apps_healthy() {
    local apps
    apps=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}:{.status.sync.status}:{.status.health.status}{"\n"}{end}' 2>/dev/null)
    if [ -z "$apps" ]; then
        echo "No ArgoCD applications found"
        return 1
    fi
    # Fail if any app is not Synced:Healthy (allow Progressing as transient)
    local bad
    bad=$(echo "$apps" | grep -v "Synced:Healthy" | grep -v "Synced:Progressing" | grep -v "^$" || true)
    [ -z "$bad" ]
}

run_test "producer_api_health" test_producer_api_health
run_test "argocd_apps_healthy" test_argocd_apps_healthy

echo ""

# ---------------------------------------------------------------------------
# 2. Order pipeline (API → Postgres → Kafka)
# ---------------------------------------------------------------------------
echo "--- Order Pipeline ---"

test_producer_api_create_order() {
    local resp
    resp=$(curl -s --max-time 5 -X POST http://localhost:8000/api/v1/orders \
        -H "Content-Type: application/json" \
        -d '{"account_id":1,"instrument_id":1,"ticker":"AAPL","side":"BUY","quantity":"100","order_type":"MARKET"}')
    local order_id
    order_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['order_id'])" 2>/dev/null)
    if [ -z "$order_id" ]; then
        echo "No order_id in response: $resp"
        return 1
    fi
    echo "$order_id" > "$TMPDIR_TESTS/order_id"
}

test_postgres_order_persisted() {
    if [ ! -f "$TMPDIR_TESTS/order_id" ]; then
        echo "No order_id from previous test"
        return 1
    fi
    local order_id
    order_id=$(cat "$TMPDIR_TESTS/order_id")
    local count
    count=$(kubectl -n data exec statefulset/sample-postgres -- \
        psql -U postgres -d trading -t -c "SELECT count(*) FROM orders WHERE order_id = $order_id" 2>/dev/null)
    [ "$(echo "$count" | tr -d ' \n')" -ge 1 ]
}

test_kafka_order_topic() {
    local msg
    msg=$(kubectl -n strimzi exec data-lake-kafka-0 -- \
        bin/kafka-console-consumer.sh \
        --bootstrap-server localhost:9092 \
        --topic stream.order-events \
        --from-beginning \
        --max-messages 1 \
        --timeout-ms 10000 2>/dev/null || true)
    echo "$msg" | grep -q "ORDER_CREATED"
}

run_test "producer_api_create_order" test_producer_api_create_order
run_test "postgres_order_persisted" test_postgres_order_persisted
run_test "kafka_order_topic" test_kafka_order_topic

echo ""

# ---------------------------------------------------------------------------
# 3. Market data pipeline
# ---------------------------------------------------------------------------
echo "--- Market Data Pipeline ---"

test_producer_api_market_data() {
    local resp
    resp=$(curl -s --max-time 5 -X POST http://localhost:8000/api/v1/market-data \
        -H "Content-Type: application/json" \
        -d "{\"tick_id\":\"integ-$(date +%s)\",\"instrument_id\":1,\"ticker\":\"AAPL\",\"bid\":\"178.40\",\"ask\":\"178.60\",\"last_price\":\"178.50\",\"volume\":1000,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
    echo "$resp" | grep -q "tick_id"
}

test_kafka_market_data_topic() {
    local msg
    msg=$(kubectl -n strimzi exec data-lake-kafka-0 -- \
        bin/kafka-console-consumer.sh \
        --bootstrap-server localhost:9092 \
        --topic stream.market-data \
        --from-beginning \
        --max-messages 1 \
        --timeout-ms 10000 2>/dev/null || true)
    echo "$msg" | grep -q "AAPL"
}

run_test "producer_api_market_data" test_producer_api_market_data
run_test "kafka_market_data_topic" test_kafka_market_data_topic

echo ""

# ---------------------------------------------------------------------------
# 4. CDC & Kafka Connect
# ---------------------------------------------------------------------------
echo "--- CDC & Kafka Connect ---"

test_debezium_connector_running() {
    local status
    # Try getting connector status via kubectl exec into the connect pod
    status=$(kubectl -n strimzi exec deploy/data-lake-connect -- \
        curl -s http://localhost:8083/connectors/debezium-source/status 2>/dev/null || true)
    if [ -z "$status" ]; then
        echo "Could not reach Kafka Connect REST API"
        return 1
    fi
    echo "$status" | grep -q '"RUNNING"'
}

test_cdc_topic_exists() {
    local topics
    topics=$(kubectl -n strimzi exec data-lake-kafka-0 -- \
        bin/kafka-topics.sh \
        --bootstrap-server localhost:9092 \
        --list 2>/dev/null || true)
    echo "$topics" | grep -q "cdc.trading"
}

# Debezium connector name may vary — check if connect pod exists first
if kubectl -n strimzi get deploy/data-lake-connect >/dev/null 2>&1; then
    run_test "debezium_connector_running" test_debezium_connector_running
else
    skip_test "debezium_connector_running" "Kafka Connect not deployed"
fi

run_test "cdc_topic_exists" test_cdc_topic_exists

echo ""

# ===========================================================================
# Summary
# ===========================================================================
TOTAL=$((PASSED + FAILED + SKIPPED))
echo "==========================================="
printf " Results: ${GREEN}%d passed${NC}" "$PASSED"
if [ "$FAILED" -gt 0 ]; then
    printf ", ${RED}%d failed${NC}" "$FAILED"
fi
if [ "$SKIPPED" -gt 0 ]; then
    printf ", ${YELLOW}%d skipped${NC}" "$SKIPPED"
fi
echo " / $TOTAL total"
echo "==========================================="

exit "$FAILED"
