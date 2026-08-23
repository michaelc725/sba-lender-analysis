-- ============================================================
-- SBA 7(a) Loan Analysis
-- Data: SBA FOIA 7(a) loan-level file, FY2000-FY2009
-- Source: https://data.sba.gov/dataset/7-a-504-foia
--
-- Question: Which lenders underwrite better than their
-- portfolio mix would predict?
--
-- Note on LoanStatus values:
--   'P I F'  = paid in full   (note the spaces)
--   'CHGOFF' = charged off
--   'CANCLD' = approved but never funded  -> excluded
--   'COMMIT' = undisbursed                -> excluded
--   'EXEMPT' = outstanding, withheld under FOIA Exemption 4
-- Only CHGOFF and P I F represent resolved outcomes, so every
-- query below filters to those two.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Status distribution
-- Establishes the working population.
-- Result: 460,222 paid in full / 144,351 charged off /
--         82,276 cancelled / 3,484 exempt.
-- Only 0.6% exempt, so censoring is negligible for this decade.
-- Base default rate = 23.9%.
-- ------------------------------------------------------------
SELECT LoanStatus, COUNT(*) AS loans
FROM loans
GROUP BY LoanStatus;


-- ------------------------------------------------------------
-- 2. Is InitialInterestRate usable?
-- Result: only 32,159 of 604,573 resolved loans have a rate.
-- The field is not reliably populated for this decade, so any
-- risk-pricing analysis is off the table.
-- ------------------------------------------------------------
SELECT COUNT(*) AS total,
       COUNT(InitialInterestRate) AS has_rate
FROM loans
WHERE LoanStatus IN ('CHGOFF', 'P I F');


-- ------------------------------------------------------------
-- 3. Default rate by approval year (the vintage effect)
-- Result: 13.5% (2002) rising to 37.0% (2007), falling back
-- to 14.9% (2009). Loans originated in 2006-2007 hit the
-- recession partway through their term.
-- Vintage is the single largest driver of outcome and must be
-- controlled for in any lender comparison.
-- ------------------------------------------------------------
SELECT
    ApprovalFY,
    COUNT(*) AS resolved_loans,
    SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1 ELSE 0 END) AS charged_off,
    ROUND(
        SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100,
        2
    ) AS default_rate_pct
FROM loans
WHERE LoanStatus IN ('CHGOFF', 'P I F')
GROUP BY ApprovalFY
ORDER BY ApprovalFY;


-- ------------------------------------------------------------
-- 4. Default rate by industry sector (first two NAICS digits)
-- Result: 30.8% (53 real estate) down to 13.1% (21 mining).
-- Health care (62) stands out: 14.4% across 42,268 loans --
-- the second-lowest rate on a large sample.
-- 16,884 loans have a blank NAICS code.
-- ------------------------------------------------------------
SELECT
    SUBSTR(NaicsCode, 1, 2) AS sector,
    COUNT(*) AS loan_count,
    SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1 ELSE 0 END) AS charged_off,
    ROUND(
        SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100,
        2
    ) AS default_rate_pct
FROM loans
WHERE LoanStatus IN ('CHGOFF', 'P I F')
GROUP BY SUBSTR(NaicsCode, 1, 2)
HAVING COUNT(*) >= 1000
ORDER BY default_rate_pct DESC;


-- ------------------------------------------------------------
-- 5. Sector x vintage interaction
-- Tests whether the sector ranking above is really a vintage
-- artifact -- real estate and construction lending was
-- concentrated in exactly the years that failed.
--
-- Result: every sector roughly tripled from trough to peak.
--   Real estate (53):  15.5% (2003) -> 47.5% (2007)
--   Construction (23): 13.7% (2002) -> 39.3% (2007)
--   Health care (62):   7.3% (2002) -> 23.1% (2007)
-- The multiplier is similar across sectors; the base rate is
-- what differs. Health care's worst year is roughly real
-- estate's average year.
-- ------------------------------------------------------------
SELECT
    ApprovalFY,
    SUBSTR(NaicsCode, 1, 2) AS sector,
    COUNT(*) AS loan_count,
    SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1 ELSE 0 END) AS charged_off,
    ROUND(
        SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100,
        2
    ) AS default_rate_pct
FROM loans
WHERE LoanStatus IN ('CHGOFF', 'P I F')
  AND SUBSTR(NaicsCode, 1, 2) IN ('53', '23', '62')
GROUP BY SUBSTR(NaicsCode, 1, 2), ApprovalFY
HAVING COUNT(*) >= 200
ORDER BY sector, ApprovalFY;


-- ------------------------------------------------------------
-- 6. Lender comparison, FIRST ATTEMPT (flawed -- see query 7)
--
-- Builds an expected default rate for each lender from the
-- year-and-sector mix of its own portfolio, then compares that
-- to what the lender actually experienced.
-- Negative actual_minus_expected = better than its mix predicts.
--
-- This version produced implausible results at the top:
-- Citibank (West), FSB showed 0.00% default across 574 loans
-- and Wachovia SBA Lending 0.16% across 1,286 -- against a
-- 23.9% base rate. See query 7 for the diagnosis.
-- ------------------------------------------------------------
WITH benchmark AS (
    SELECT
        ApprovalFY,
        SUBSTR(NaicsCode, 1, 2) AS sector,
        SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100 AS expected_rate
    FROM loans
    WHERE LoanStatus IN ('CHGOFF', 'P I F')
    GROUP BY ApprovalFY, SUBSTR(NaicsCode, 1, 2)
    HAVING COUNT(*) >= 200
)
SELECT
    l.BankName,
    COUNT(*) AS loans,
    ROUND(
        SUM(CASE WHEN l.LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100,
        2
    ) AS actual_rate_pct,
    ROUND(AVG(b.expected_rate), 2) AS expected_rate_pct,
    ROUND(
        SUM(CASE WHEN l.LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100
        - AVG(b.expected_rate),
        2
    ) AS actual_minus_expected
FROM loans l
JOIN benchmark b
    ON l.ApprovalFY = b.ApprovalFY
   AND SUBSTR(l.NaicsCode, 1, 2) = b.sector
WHERE l.LoanStatus IN ('CHGOFF', 'P I F')
GROUP BY l.BankName
HAVING COUNT(*) >= 500
ORDER BY actual_minus_expected;


-- ------------------------------------------------------------
-- 7. DIAGNOSTIC: why the top performers were not credible
--
-- The data dictionary defines BankName as "the bank that the
-- loan is CURRENTLY ASSIGNED TO" -- not the originating lender.
-- Loans get reassigned through mergers, acquisitions, and
-- bank failures.
--
-- Result:
--   Citibank (West), FSB     -- loans stop after 2007, zero
--                               charge-offs in any year
--   Wachovia SBA Lending     -- loans stop after 2007, two
--                               charge-offs across 1,286 loans
--   FDIC                     -- 4,058 loans spanning all ten
--                               years, charge-offs rising
--                               through the crisis as expected
--
-- Both defunct entities show near-zero defaults across a
-- decade that averaged 23.9%. When these institutions were
-- absorbed, their charged-off loans were reassigned elsewhere
-- while performing loans kept the legacy name -- leaving a
-- survivorship-filtered remnant.
--
-- The FDIC row confirms the mechanism: it originates nothing,
-- so its 4,058 loans are inherited from failed banks.
-- ------------------------------------------------------------
SELECT
    BankName,
    ApprovalFY,
    COUNT(*) AS loans,
    SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1 ELSE 0 END) AS charged_off
FROM loans
WHERE BankName IN (
        'Citibank (West), FSB',
        'Wachovia SBA Lending, Inc.',
        'Federal Deposit Insurance Corporation'
      )
  AND LoanStatus IN ('CHGOFF', 'P I F')
GROUP BY BankName, ApprovalFY
ORDER BY BankName, ApprovalFY;


-- ------------------------------------------------------------
-- 8. Lender comparison, CORRECTED
--
-- Two changes from query 6:
--   (a) require at least 50 loans in both 2003 and 2008, so
--       only lenders originating across the full period appear.
--       Institutions absorbed mid-decade drop out.
--   (b) exclude the FDIC explicitly -- it holds inherited
--       loans rather than originating any.
--
-- Result: 73 lenders, spread of roughly 34 percentage points.
--   Best:  Commerce Bank        -14.01  (1,905 loans)
--          First Community Bank -13.61
--          KeyBank              -10.90  (7,819 loans)
--   Worst: HSBC                 +19.68  (3,911 loans)
--          Popular Bank         +17.36  (7,313 loans)
--          Bank of Hope         +16.63  (27,744 loans)
--          Capital One          +14.94  (19,477 loans)
--          Bank of America       +7.10  (68,606 loans)
--
-- Mid-size regional banks occupy most of the top 20.
-- ------------------------------------------------------------
WITH benchmark AS (
    SELECT
        ApprovalFY,
        SUBSTR(NaicsCode, 1, 2) AS sector,
        SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100 AS expected_rate
    FROM loans
    WHERE LoanStatus IN ('CHGOFF', 'P I F')
    GROUP BY ApprovalFY, SUBSTR(NaicsCode, 1, 2)
    HAVING COUNT(*) >= 200
)
SELECT
    l.BankName,
    COUNT(*) AS loans,
    ROUND(
        SUM(CASE WHEN l.LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100,
        2
    ) AS actual_rate_pct,
    ROUND(AVG(b.expected_rate), 2) AS expected_rate_pct,
    ROUND(
        SUM(CASE WHEN l.LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100
        - AVG(b.expected_rate),
        2
    ) AS actual_minus_expected
FROM loans l
JOIN benchmark b
    ON l.ApprovalFY = b.ApprovalFY
   AND SUBSTR(l.NaicsCode, 1, 2) = b.sector
WHERE l.LoanStatus IN ('CHGOFF', 'P I F')
  AND l.BankName != 'Federal Deposit Insurance Corporation'
GROUP BY l.BankName
HAVING COUNT(*) >= 500
   AND SUM(CASE WHEN l.ApprovalFY = 2003 THEN 1 ELSE 0 END) >= 50
   AND SUM(CASE WHEN l.ApprovalFY = 2008 THEN 1 ELSE 0 END) >= 50
ORDER BY actual_minus_expected;


-- ------------------------------------------------------------
-- 9. Does geography explain the lender spread?
--
-- Tested before adding state as a third benchmark dimension,
-- to check whether the extra control would change anything.
--
-- Result: no.
--   Bank of Hope (worst) defaults at 30-59% in every state it
--   lends in -- 39.9% CA, 46.4% TX, 53.3% GA, 59.0% FL. Even
--   its best market (WA, 18.0%) is close to the national base
--   rate. Poor outcomes follow the lender across 15+ states.
--
--   Commerce Bank (best) runs 12-13% across MO, KS, and IL --
--   consistently good in ordinary Midwest markets.
--
-- Geography is not driving the spread, so the benchmark was
-- left at two dimensions rather than adding ~11,000 mostly
-- sparse year x sector x state cells.
-- ------------------------------------------------------------
SELECT
    BorrState,
    COUNT(*) AS loans,
    ROUND(
        SUM(CASE WHEN LoanStatus = 'CHGOFF' THEN 1.0 ELSE 0 END) / COUNT(*) * 100,
        2
    ) AS default_rate_pct
FROM loans
WHERE BankName = 'Bank of Hope'
  AND LoanStatus IN ('CHGOFF', 'P I F')
GROUP BY BorrState
ORDER BY loans DESC
LIMIT 15;
