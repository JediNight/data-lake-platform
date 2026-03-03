-- Trading Platform Schema
-- 5 source tables for CDC ingestion to data lake

-- MNPI Tables (orders, trades, positions)

CREATE TABLE orders (
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
);

CREATE TABLE trades (
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
);

CREATE TABLE positions (
    position_id     SERIAL PRIMARY KEY,
    account_id      INTEGER NOT NULL,
    instrument_id   INTEGER NOT NULL,
    quantity        DECIMAL(18,4) NOT NULL DEFAULT 0,
    market_value    DECIMAL(18,2),
    position_date   DATE NOT NULL DEFAULT CURRENT_DATE,
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (account_id, instrument_id, position_date)
);

-- Non-MNPI Tables (accounts, instruments)

CREATE TABLE accounts (
    account_id      SERIAL PRIMARY KEY,
    account_name    VARCHAR(100) NOT NULL,
    account_type    VARCHAR(20) NOT NULL CHECK (account_type IN ('INDIVIDUAL', 'INSTITUTIONAL', 'FUND')),
    status          VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TABLE instruments (
    instrument_id   SERIAL PRIMARY KEY,
    ticker          VARCHAR(10) NOT NULL UNIQUE,
    cusip           CHAR(9),
    isin            CHAR(12),
    name            VARCHAR(200) NOT NULL,
    instrument_type VARCHAR(10) NOT NULL CHECK (instrument_type IN ('EQUITY', 'BOND', 'ETF', 'OPTION')),
    exchange        VARCHAR(10) NOT NULL DEFAULT 'NYSE',
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Indexes for query performance
CREATE INDEX idx_orders_account ON orders(account_id);
CREATE INDEX idx_orders_instrument ON orders(instrument_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_trades_order ON trades(order_id);
CREATE INDEX idx_trades_instrument ON trades(instrument_id);
CREATE INDEX idx_positions_account ON positions(account_id);
CREATE INDEX idx_positions_instrument ON positions(instrument_id);
CREATE INDEX idx_instruments_cusip ON instruments(cusip);
CREATE INDEX idx_instruments_isin ON instruments(isin);

-- Publication for Debezium CDC (all tables)
CREATE PUBLICATION debezium_publication FOR ALL TABLES;
