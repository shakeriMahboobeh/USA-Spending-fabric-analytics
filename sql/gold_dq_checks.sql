-- 1. ROW COUNT RECONCILIATION: Gold fact vs. Silver source
-- Expectation: fact_award count should equal the combined Silver count
-- (silver_assistance + silver_contracts), since fact_award has no
-- surrogate/synthetic key of its own and preserves every Silver row.
SELECT
    (SELECT COUNT(*) FROM lh_silver_usaspending.dbo.silver_assistance) +
    (SELECT COUNT(*) FROM lh_silver_usaspending.dbo.silver_contracts) AS silver_total_rows,
    (SELECT COUNT(*) FROM lh_gold_usaspending.dbo.fact_award) AS gold_fact_rows,
    ((SELECT COUNT(*) FROM lh_silver_usaspending.dbo.silver_assistance) +
     (SELECT COUNT(*) FROM lh_silver_usaspending.dbo.silver_contracts)) -
    (SELECT COUNT(*) FROM lh_gold_usaspending.dbo.fact_award) AS row_diff;


-- 2. FINANCIAL TOTAL RECONCILIATION (the check that matters most)
-- Expectation: totals should match exactly. Any diff here means money is
-- being lost or duplicated somewhere in the Silver -> Gold join/merge.
SELECT
    (SELECT ROUND(SUM(transaction_obligated_amount), 2)
       FROM lh_silver_usaspending.dbo.silver_assistance) +
    (SELECT ROUND(SUM(transaction_obligated_amount), 2)
       FROM lh_silver_usaspending.dbo.silver_contracts) AS silver_total_obligated,
    (SELECT ROUND(SUM(transaction_obligated_amount), 2)
       FROM lh_gold_usaspending.dbo.fact_award) AS gold_total_obligated;


-- 3. FACT TABLE KEY UNIQUENESS
-- Expectation: total_rows == distinct_keys. Any gap means the merge key
-- is colliding again (the same class of bug found earlier in Silver).
SELECT
    COUNT(*) AS total_rows
FROM lh_gold_usaspending.dbo.fact_award
UNION ALL
SELECT
    COUNT(*) AS distinct_keys 
FROM (
    SELECT COUNT(1) as cnt
    FROM lh_gold_usaspending.dbo.fact_award
    GROUP BY award_unique_key
    , parent_award_id_piid
    , federal_account_symbol
    , program_activity_code
    , program_activity_name
    , object_class_code
    , direct_or_reimbursable_funding_source
    , disaster_emergency_fund_code
    , submission_period
    , program_activity_reporting_key
    , award_category )f


-- 4. ORPHANED FOREIGN KEYS — fact rows with no matching dimension row
-- Expectation: all four counts should be 0. A non-zero count means a
-- dimension lookup failed to match during the Gold build (e.g. a business
-- key value slipped through with different casing/whitespace/nulls between
-- fact and dimension).
SELECT 'agency_key' AS fk_column, COUNT(*) AS orphaned_rows
FROM lh_gold_usaspending.dbo.fact_award WHERE agency_key IS NULL
UNION ALL
SELECT 'account_key', COUNT(*)
FROM lh_gold_usaspending.dbo.fact_award WHERE account_key IS NULL
UNION ALL
SELECT 'program_activity_key', COUNT(*)
FROM lh_gold_usaspending.dbo.fact_award WHERE program_activity_key IS NULL
UNION ALL
SELECT 'recipient_key', COUNT(*)
FROM lh_gold_usaspending.dbo.fact_award WHERE recipient_key IS NULL;
-- Note: recipient_key CAN legitimately be null for balance-sheet-style rows
-- with no recipient_uei in the source — don't treat that one as an error
-- without checking the source data first.


-- 5. DIMENSION KEY UNIQUENESS — surrogate keys should never repeat
-- Expectation: all four return 0 rows.
SELECT 'dim_agency' AS dim, agency_key, COUNT(*) AS cnt
FROM lh_gold_usaspending.dbo.dim_agency GROUP BY agency_key HAVING COUNT(*) > 1
UNION ALL
SELECT 'dim_account', account_key, COUNT(*)
FROM lh_gold_usaspending.dbo.dim_account GROUP BY account_key HAVING COUNT(*) > 1
UNION ALL
SELECT 'dim_program_activity', program_activity_key, COUNT(*)
FROM lh_gold_usaspending.dbo.dim_program_activity GROUP BY program_activity_key HAVING COUNT(*) > 1
UNION ALL
SELECT 'dim_recipient', recipient_key, COUNT(*)
FROM lh_gold_usaspending.dbo.dim_recipient GROUP BY recipient_key HAVING COUNT(*) > 1;


-- 6. DIMENSION BUSINESS-KEY UNIQUENESS — no duplicate members
-- Expectation: all four return 0 rows.
SELECT 'dim_agency' AS dim, agency_code, COUNT(*) AS cnt
FROM lh_gold_usaspending.dbo.dim_agency GROUP BY agency_code HAVING COUNT(*) > 1
UNION ALL
SELECT 'dim_account', federal_account_symbol, COUNT(*)
FROM lh_gold_usaspending.dbo.dim_account GROUP BY federal_account_symbol HAVING COUNT(*) > 1
UNION ALL
SELECT 'dim_recipient', recipient_uei, COUNT(*)
FROM lh_gold_usaspending.dbo.dim_recipient GROUP BY recipient_uei HAVING COUNT(*) > 1;
-- dim_program_activity is intentionally excluded here — it's keyed on the
-- (code, name) PAIR, not code alone, since the same code can legitimately
-- pair with different names (see project notes).


-- 7. agency_code COVERAGE — every agency in the fact table must exist in
-- DimSecurityMapping, or that agency's data becomes invisible to everyone
-- once RLS is applied (a silent, hard-to-notice failure mode).
SELECT DISTINCT f.agency_code
FROM lh_gold_usaspending.dbo.fact_award f
Left JOIN lh_gold_usaspending.dbo.dim_security_mapping sm
  ON f.agency_code = sm.agency_code
WHERE sm.agency_code IS NULL;
-- Expectation: 0 rows. If any agency_code appears here, add it to
-- DimSecurityMapping (or confirm it's meant to be covered by the 'ALL' row).


-- 8. WATERMARK HEALTH CHECK — confirm Gold isn't silently falling behind
-- Compares the max _silver_load_ts actually available vs. what Gold's
-- watermark table has recorded as processed.
SELECT
    (SELECT MAX(_silver_load_ts) FROM lh_silver_usaspending.dbo.silver_assistance) AS max_silver_ts_assistance,
    (SELECT MAX(_silver_load_ts) FROM lh_silver_usaspending.dbo.silver_contracts) AS max_silver_ts_contracts,
    (SELECT last_watermark FROM lh_gold_usaspending.dbo.gold_watermark WHERE table_name = 'fact_award') AS gold_fact_watermark;
-- Expectation: gold_fact_watermark should be equal to (or only slightly
-- behind, if a run is currently mid-flight) the max Silver timestamps.
-- A large gap means Gold's last run failed silently or wasn't triggered.


-- 9. NULL / BLANK CHECK ON KEY DIMENSION ATTRIBUTES
-- Catches cases where a dimension member was inserted with missing
-- descriptive text (won't break joins, but makes for a confusing report).
SELECT COUNT(*) AS agencies_missing_name
FROM lh_gold_usaspending.dbo.dim_agency
WHERE awarding_agency_name IS NULL OR awarding_agency_name = '';


-- 10. MEASURE SANITY — unexpectedly extreme values worth a manual look
-- Not a pass/fail check, just a way to catch obvious data issues (e.g. a
-- parsing bug reintroducing itself) before trusting the numbers in a report.
SELECT
    MIN(transaction_obligated_amount) AS min_obligated,
    MAX(transaction_obligated_amount) AS max_obligated,
    AVG(transaction_obligated_amount) AS avg_obligated,
    COUNT(CASE WHEN transaction_obligated_amount IS NULL THEN 1 END) AS null_amount_rows
FROM lh_gold_usaspending.dbo.fact_award;

SELECT
    (SELECT ROUND(SUM(transaction_obligated_amount), 2) FROM lh_silver_usaspending.dbo.silver_assistance) +
    (SELECT ROUND(SUM(transaction_obligated_amount), 2) FROM lh_silver_usaspending.dbo.silver_contracts) AS silver_total,
    (SELECT ROUND(SUM(transaction_obligated_amount), 2) FROM lh_gold_usaspending.dbo.fact_award) AS gold_total

SELECT COUNT(*) AS total_rows
FROM lh_gold_usaspending.dbo.fact_award
UNION ALL
SELECT COUNT(*) AS distinct_keys
FROM(
  SELECT award_unique_key, parent_award_id_piid, federal_account_symbol,
                   program_activity_code, program_activity_name, object_class_code,
                   direct_or_reimbursable_funding_source, disaster_emergency_fund_code,
                   submission_period, program_activity_reporting_key, award_category
  FROM lh_gold_usaspending.dbo.fact_award
  GROUP BY award_unique_key, parent_award_id_piid, federal_account_symbol,
                   program_activity_code, program_activity_name, object_class_code,
                   direct_or_reimbursable_funding_source, disaster_emergency_fund_code,
                   submission_period, program_activity_reporting_key, award_category
) s
select Distinct agency_code FROM [dbo].[dim_agency]