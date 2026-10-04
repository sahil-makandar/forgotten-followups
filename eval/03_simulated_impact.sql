-- SIMULATED impact on the synthetic hospital (Set C). Every number here is simulated, not a clinical result.
-- Loops in scope: standard-pathway loops whose due window has ended by the scoring date (2026-10-04).
--   1. Hospital-only view: what a single-hospital tracker can see as done (in-hospital follow-ups only).
--      The synthetic data was generated so this is about 37%, matching the published pre-tracking baseline.
--   2. With the payer share: outside follow-ups become visible (AMBER), so more loops are known to be done.
--   3. With recall from the worklist: an ASSUMED share of the remaining overdue loops is recalled and completed.
--      Assumption: 59% of not-done loops are recovered, taken from Nodule Net (37% -> 74% completion means
--      (74 - 37) / (100 - 37) = 59% of previously missed follow-ups were recovered after tracking).
-- Median days to close uses the synthetic completion dates; recalled loops are assumed to close 30 days after due date.
USE ROLE ACCOUNTADMIN;
USE DATABASE FFU;

CREATE OR REPLACE TABLE EVAL.SIMULATED_IMPACT AS
WITH due AS (
  SELECT k.*, DATEADD(day, ROUND(30.4 * due_max_months), report_date) AS due_end
  FROM KEY.ANSWER_KEY k
  WHERE expected_action <> 'NONE_REQUIRED' AND expected_pathway = 'STANDARD'
    AND DATEADD(day, ROUND(30.4 * due_max_months), report_date) <= '2026-10-04'
), sys AS (SELECT report_id, MAX_BY(status, -tier) AS status FROM CORE.LOOP_STATUS GROUP BY 1),
j AS (SELECT d.*, s.status FROM due d LEFT JOIN sys s USING (report_id)),
recall AS (
  SELECT j.*, ABS(HASH(report_id, 'recall')) % 100 < 59 AS recalled FROM j)
SELECT
  COUNT(*) AS loops_due,
  ROUND(COUNT_IF(status = 'GREEN') / COUNT(*), 3) AS hospital_only_completion,
  ROUND(COUNT_IF(status IN ('GREEN', 'AMBER')) / COUNT(*), 3) AS with_payer_share_completion,
  ROUND(COUNT_IF(status IN ('GREEN', 'AMBER') OR (status = 'RED' AND recalled)) / COUNT(*), 3) AS with_recall_completion_simulated,
  COUNT_IF(status = 'RED' AND recalled) AS recalled_loops_simulated,
  MEDIAN(IFF(status IN ('GREEN', 'AMBER'), DATEDIFF(day, report_date, outcome_date), NULL)) AS median_days_to_close_observed,
  MEDIAN(CASE WHEN status IN ('GREEN', 'AMBER') THEN DATEDIFF(day, report_date, outcome_date)
              WHEN status = 'RED' AND recalled THEN DATEDIFF(day, report_date, DATEADD(day, 30, due_end)) END) AS median_days_to_close_with_recall_simulated,
  0.37 AS published_baseline, 0.74 AS published_after_tracking,
  'SIMULATED on synthetic data; recall rate assumed from Nodule Net (Respiratory Medicine 2022)' AS label
FROM recall;

SELECT * FROM EVAL.SIMULATED_IMPACT;
