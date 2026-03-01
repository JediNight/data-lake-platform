-- Access Validation Queries
-- Run each query as the respective persona to demonstrate LF-Tag enforcement
--
-- Personas (defined in terraform/aws/modules/identity-center):
--   Finance Analyst : Can query curated_mnpi.*, curated_nonmnpi.*, and analytics_*
--   Data Analyst    : Can query curated_nonmnpi.* and analytics_nonmnpi.* ONLY
--   Data Engineer   : Can query ALL databases including raw_*
--
-- Expected results:
--   Finance Analyst: MNPI + non-MNPI curated and analytics -- all SUCCEED
--   Data Analyst:    Non-MNPI curated and analytics only -- MNPI queries FAIL
--   Data Engineer:   All databases including raw layer -- all SUCCEED
--
-- Usage:
--   1. Assume the persona role via AWS STS or Athena workgroup
--   2. Run the queries for that persona
--   3. Verify SUCCEED / FAIL matches expectations

-- ============================================================
-- Test 1: Finance Analyst queries (should all SUCCEED)
-- ============================================================

-- Query MNPI curated data (should SUCCEED for finance analyst)
SELECT COUNT(*) AS total_orders FROM curated_mnpi.orders;
SELECT COUNT(*) AS total_trades FROM curated_mnpi.trades;
SELECT COUNT(*) AS total_positions FROM curated_mnpi.positions;

-- Query non-MNPI curated data (should SUCCEED for finance analyst)
SELECT COUNT(*) AS total_instruments FROM curated_nonmnpi.instruments;
SELECT COUNT(*) AS total_accounts FROM curated_nonmnpi.accounts;

-- Query analytics (should SUCCEED for finance analyst)
SELECT * FROM analytics_mnpi.daily_trade_summary LIMIT 5;
SELECT * FROM analytics_mnpi.position_report LIMIT 5;

-- ============================================================
-- Test 2: Data Analyst queries (MNPI should FAIL)
-- ============================================================

-- Query non-MNPI curated (should SUCCEED for data analyst)
SELECT COUNT(*) AS total_accounts FROM curated_nonmnpi.accounts;
SELECT COUNT(*) AS total_instruments FROM curated_nonmnpi.instruments;

-- Query MNPI curated (should FAIL for data analyst -- AccessDeniedException)
-- Uncomment to test; expect AccessDeniedException from Lake Formation:
-- SELECT COUNT(*) FROM curated_mnpi.orders;     -- EXPECTED: AccessDenied
-- SELECT COUNT(*) FROM curated_mnpi.trades;      -- EXPECTED: AccessDenied
-- SELECT COUNT(*) FROM curated_mnpi.positions;   -- EXPECTED: AccessDenied

-- Query MNPI analytics (should FAIL for data analyst)
-- SELECT * FROM analytics_mnpi.daily_trade_summary LIMIT 1;  -- EXPECTED: AccessDenied

-- ============================================================
-- Test 3: Data Engineer queries (should all SUCCEED, including raw)
-- ============================================================

-- Query raw layer (should SUCCEED for data engineer only)
SELECT COUNT(*) AS raw_order_events FROM raw_mnpi.orders;
SELECT COUNT(*) AS raw_trade_events FROM raw_mnpi.trades;
SELECT COUNT(*) AS raw_position_events FROM raw_mnpi.positions;
SELECT COUNT(*) AS raw_instrument_events FROM raw_nonmnpi.instruments;
SELECT COUNT(*) AS raw_account_events FROM raw_nonmnpi.accounts;

-- Query curated layer (should SUCCEED for data engineer)
SELECT COUNT(*) AS curated_orders FROM curated_mnpi.orders;
SELECT COUNT(*) AS curated_instruments FROM curated_nonmnpi.instruments;

-- Query analytics layer (should SUCCEED for data engineer)
SELECT * FROM analytics_mnpi.daily_trade_summary LIMIT 5;
