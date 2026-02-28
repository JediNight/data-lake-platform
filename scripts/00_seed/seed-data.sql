-- Seed data for trading platform demo
-- Provides realistic financial data for CDC and query demos

-- Instruments (non-MNPI: publicly available reference data)
INSERT INTO instruments (ticker, cusip, isin, name, instrument_type, exchange) VALUES
('AAPL',  '037833100', 'US0378331005', 'Apple Inc.',                  'EQUITY', 'NASDAQ'),
('MSFT',  '594918104', 'US5949181045', 'Microsoft Corporation',       'EQUITY', 'NASDAQ'),
('GOOGL', '02079K305', 'US02079K3059', 'Alphabet Inc.',               'EQUITY', 'NASDAQ'),
('JPM',   '46625H100', 'US46625H1005', 'JPMorgan Chase & Co.',       'EQUITY', 'NYSE'),
('GS',    '38141G104', 'US38141G1040', 'The Goldman Sachs Group',    'EQUITY', 'NYSE'),
('BRK.B', '084670702', 'US0846707026', 'Berkshire Hathaway Inc.',    'EQUITY', 'NYSE'),
('SPY',   '78462F103', 'US78462F1030', 'SPDR S&P 500 ETF Trust',    'ETF',    'NYSE'),
('AGG',   '464287226', 'US4642872265', 'iShares Core US Agg Bond',  'ETF',    'NYSE');

-- Accounts (non-MNPI: account metadata)
INSERT INTO accounts (account_name, account_type, status) VALUES
('Alpha Growth Fund',       'FUND',          'ACTIVE'),
('Beta Income Portfolio',   'FUND',          'ACTIVE'),
('J. Smith Individual',     'INDIVIDUAL',    'ACTIVE'),
('Gamma Institutional',     'INSTITUTIONAL', 'ACTIVE'),
('Dormant Holdings LLC',    'INSTITUTIONAL', 'SUSPENDED');

-- Orders (MNPI: non-public trading intent)
INSERT INTO orders (account_id, instrument_id, side, quantity, order_type, limit_price, status, disclosure_status) VALUES
(1, 1, 'BUY',  1000.0000, 'LIMIT',  185.50, 'FILLED',    'DISCLOSED'),
(1, 2, 'BUY',  500.0000,  'MARKET', NULL,    'FILLED',    'DISCLOSED'),
(2, 4, 'BUY',  2000.0000, 'LIMIT',  198.00, 'FILLED',    'MNPI'),
(2, 7, 'BUY',  5000.0000, 'MARKET', NULL,    'FILLED',    'MNPI'),
(3, 1, 'SELL', 200.0000,  'LIMIT',  190.00, 'PENDING',   'MNPI'),
(4, 5, 'BUY',  1500.0000, 'LIMIT',  450.00, 'PARTIAL',   'MNPI'),
(1, 3, 'BUY',  300.0000,  'MARKET', NULL,    'CANCELLED', 'DISCLOSED');

-- Trades (MNPI: non-public execution data)
INSERT INTO trades (order_id, instrument_id, quantity, price, execution_venue, settlement_date, disclosure_status) VALUES
(1, 1, 1000.0000, 185.25, 'NASDAQ', CURRENT_DATE + INTERVAL '2 days', 'DISCLOSED'),
(2, 2, 500.0000,  420.10, 'NASDAQ', CURRENT_DATE + INTERVAL '2 days', 'DISCLOSED'),
(3, 4, 2000.0000, 197.85, 'NYSE',   CURRENT_DATE + INTERVAL '2 days', 'MNPI'),
(4, 7, 5000.0000, 525.30, 'NYSE',   CURRENT_DATE + INTERVAL '2 days', 'MNPI'),
(6, 5, 750.0000,  449.50, 'NYSE',   CURRENT_DATE + INTERVAL '2 days', 'MNPI');

-- Positions (MNPI: non-public holdings)
INSERT INTO positions (account_id, instrument_id, quantity, market_value, position_date) VALUES
(1, 1, 1000.0000, 185250.00, CURRENT_DATE),
(1, 2, 500.0000,  210050.00, CURRENT_DATE),
(2, 4, 2000.0000, 395700.00, CURRENT_DATE),
(2, 7, 5000.0000, 2626500.00, CURRENT_DATE),
(3, 1, 800.0000,  148200.00, CURRENT_DATE),
(4, 5, 750.0000,  337125.00, CURRENT_DATE);
