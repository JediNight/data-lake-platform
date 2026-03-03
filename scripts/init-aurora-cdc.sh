#!/usr/bin/env bash
# scripts/init-aurora-cdc.sh
# Initializes Aurora PostgreSQL for Debezium CDC via the RDS Data API.
# Creates trading tables + Debezium publication.
#
# Prerequisites: aws CLI, Aurora Data API enabled (enable_http_endpoint = true)
# Usage: ./scripts/init-aurora-cdc.sh <environment>
set -euo pipefail

ENV="${1:?Usage: $0 <environment>}"
if [[ -z "${CLUSTER_ARN:-}" ]]; then
  CLUSTER_ARN=$(aws rds describe-db-clusters \
    --db-cluster-identifier "datalake-${ENV}" \
    --query 'DBClusters[0].DBClusterArn' --output text)
fi
if [[ -z "${SECRET_ARN:-}" ]]; then
  SECRET_ARN=$(aws secretsmanager describe-secret \
    --secret-id "datalake/aurora/${ENV}/master-password" \
    --query 'ARN' --output text)
fi
DATABASE="trading"

echo "==> Cluster: ${CLUSTER_ARN}"
echo "==> Secret:  ${SECRET_ARN}"
echo "==> Database: ${DATABASE}"

run_sql() {
  local sql="$1"
  local desc="${2:-SQL statement}"
  echo "  -> ${desc}"
  aws rds-data execute-statement \
    --resource-arn "${CLUSTER_ARN}" \
    --secret-arn "${SECRET_ARN}" \
    --database "${DATABASE}" \
    --sql "${sql}" \
    --output text 2>&1 || true
}

echo ""
echo "==> Creating MNPI tables (orders, trades, positions)"

run_sql "
CREATE TABLE IF NOT EXISTS orders (
    order_id        SERIAL PRIMARY KEY,
    account_id      INTEGER NOT NULL,
    instrument_id   INTEGER NOT NULL,
    side            VARCHAR(4) NOT NULL CHECK (side IN ('BUY', 'SELL')),
    quantity        DECIMAL(18,4) NOT NULL,
    order_type      VARCHAR(10) NOT NULL CHECK (order_type IN ('MARKET', 'LIMIT', 'STOP')),
    limit_price     DECIMAL(18,4),
    status          VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING', 'FILLED', 'PARTIAL', 'CANCELLED')),
    disclosure_status VARCHAR(10) NOT NULL DEFAULT 'MNPI'
                    CHECK (disclosure_status IN ('MNPI', 'DISCLOSED', 'PUBLIC')),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
)" "CREATE TABLE orders"

run_sql "
CREATE TABLE IF NOT EXISTS trades (
    trade_id        SERIAL PRIMARY KEY,
    order_id        INTEGER NOT NULL REFERENCES orders(order_id),
    instrument_id   INTEGER NOT NULL,
    quantity        DECIMAL(18,4) NOT NULL,
    price           DECIMAL(18,4) NOT NULL,
    execution_venue VARCHAR(20) NOT NULL DEFAULT 'NYSE',
    settlement_date DATE,
    disclosure_status VARCHAR(10) NOT NULL DEFAULT 'MNPI'
                    CHECK (disclosure_status IN ('MNPI', 'DISCLOSED', 'PUBLIC')),
    executed_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
)" "CREATE TABLE trades"

run_sql "
CREATE TABLE IF NOT EXISTS positions (
    position_id     SERIAL PRIMARY KEY,
    account_id      INTEGER NOT NULL,
    instrument_id   INTEGER NOT NULL,
    quantity        DECIMAL(18,4) NOT NULL DEFAULT 0,
    market_value    DECIMAL(18,2),
    position_date   DATE NOT NULL DEFAULT CURRENT_DATE,
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (account_id, instrument_id, position_date)
)" "CREATE TABLE positions"

echo ""
echo "==> Creating non-MNPI tables (accounts, instruments)"

run_sql "
CREATE TABLE IF NOT EXISTS accounts (
    account_id      SERIAL PRIMARY KEY,
    account_name    VARCHAR(100) NOT NULL,
    account_type    VARCHAR(20) NOT NULL CHECK (account_type IN ('INDIVIDUAL', 'INSTITUTIONAL', 'FUND')),
    status          VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
)" "CREATE TABLE accounts"

run_sql "
CREATE TABLE IF NOT EXISTS instruments (
    instrument_id   SERIAL PRIMARY KEY,
    ticker          VARCHAR(10) NOT NULL UNIQUE,
    cusip           CHAR(9),
    isin            CHAR(12),
    name            VARCHAR(200) NOT NULL,
    instrument_type VARCHAR(10) NOT NULL CHECK (instrument_type IN ('EQUITY', 'BOND', 'ETF', 'OPTION')),
    exchange        VARCHAR(10) NOT NULL DEFAULT 'NYSE',
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
)" "CREATE TABLE instruments"

echo ""
echo "==> Creating indexes"

run_sql "CREATE INDEX IF NOT EXISTS idx_orders_account ON orders(account_id)" "idx_orders_account"
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_instrument ON orders(instrument_id)" "idx_orders_instrument"
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status)" "idx_orders_status"
run_sql "CREATE INDEX IF NOT EXISTS idx_trades_order ON trades(order_id)" "idx_trades_order"
run_sql "CREATE INDEX IF NOT EXISTS idx_trades_instrument ON trades(instrument_id)" "idx_trades_instrument"
run_sql "CREATE INDEX IF NOT EXISTS idx_positions_account ON positions(account_id)" "idx_positions_account"
run_sql "CREATE INDEX IF NOT EXISTS idx_positions_instrument ON positions(instrument_id)" "idx_positions_instrument"
run_sql "CREATE INDEX IF NOT EXISTS idx_instruments_cusip ON instruments(cusip)" "idx_instruments_cusip"
run_sql "CREATE INDEX IF NOT EXISTS idx_instruments_isin ON instruments(isin)" "idx_instruments_isin"

echo ""
echo "==> Creating Debezium publication"
run_sql "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'debezium_publication') THEN
    CREATE PUBLICATION debezium_publication FOR TABLE orders, trades, positions, accounts, instruments;
    RAISE NOTICE 'Publication created';
  ELSE
    RAISE NOTICE 'Publication already exists';
  END IF;
END \$\$
" "CREATE PUBLICATION debezium_publication"

echo ""
echo "==> Seeding reference data (instruments + accounts)"

run_sql "
INSERT INTO instruments (ticker, cusip, isin, name, instrument_type, exchange) VALUES
  ('AAPL', '037833100', 'US0378331005', 'Apple Inc.', 'EQUITY', 'NASDAQ'),
  ('MSFT', '594918104', 'US5949181045', 'Microsoft Corp.', 'EQUITY', 'NASDAQ'),
  ('GOOGL', '02079K305', 'US02079K3059', 'Alphabet Inc.', 'EQUITY', 'NASDAQ'),
  ('AMZN', '023135106', 'US0231351067', 'Amazon.com Inc.', 'EQUITY', 'NASDAQ'),
  ('JPM', '46625H100', 'US46625H1005', 'JPMorgan Chase', 'EQUITY', 'NYSE'),
  ('GS', '38141G104', 'US38141G1040', 'Goldman Sachs', 'EQUITY', 'NYSE'),
  ('SPY', '78462F103', 'US78462F1030', 'SPDR S&P 500 ETF', 'ETF', 'NYSE'),
  ('QQQ', '46090E103', 'US46090E1038', 'Invesco QQQ ETF', 'ETF', 'NASDAQ')
ON CONFLICT (ticker) DO NOTHING
" "Seed instruments"

run_sql "
INSERT INTO accounts (account_name, account_type, status) VALUES
  ('Alpha Capital Partners', 'FUND', 'ACTIVE'),
  ('Jane Smith IRA', 'INDIVIDUAL', 'ACTIVE'),
  ('BlueStar Institutional', 'INSTITUTIONAL', 'ACTIVE'),
  ('Omega Growth Fund', 'FUND', 'ACTIVE'),
  ('Tech Ventures LLC', 'INSTITUTIONAL', 'ACTIVE')
ON CONFLICT DO NOTHING
" "Seed accounts"

echo ""
echo "==> Verifying tables"
run_sql "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename" "List tables"

echo ""
echo "==> Verifying publication"
run_sql "SELECT pubname, puballtables FROM pg_publication WHERE pubname = 'debezium_publication'" "Check publication"

echo ""
echo "==> Done. Aurora CDC is configured for Debezium."
