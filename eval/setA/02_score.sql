-- Set A scoring: 120 real Indiana University chest X-ray reports vs hand labels (eval/setA/setA_labels.csv: uid + labels only).
-- Run from the repo root: snow sql -c hospital -f eval/setA/02_score.sql
-- Set A has no follow-up events, so the task is loop DETECTION: does the report open a follow-up loop (and of which type)?
-- Methods: SYSTEM (AI extraction + rules), KEYWORD (recommend/follow-up regex), AI_ONLY (model decides, no rules; cached).
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

PUT file://eval/setA/setA_labels.csv @EVAL.SETA_STAGE OVERWRITE = TRUE AUTO_COMPRESS = TRUE;
CREATE OR REPLACE TABLE EVAL.SETA_LABELS (uid STRING, expect_loop STRING, finding_type STRING, action STRING, hedged STRING);
COPY INTO EVAL.SETA_LABELS FROM @EVAL.SETA_STAGE/setA_labels.csv.gz FILE_FORMAT = (FORMAT_NAME = 'EVAL.CSV_QUOTED');

-- AI-only detection (cached; same model as extraction, no rules).
CREATE TABLE IF NOT EXISTS EVAL.SETA_AI_CACHE (report_id STRING, opens_loop BOOLEAN, raw VARIANT, run_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
INSERT INTO EVAL.SETA_AI_CACHE (report_id, opens_loop, raw)
SELECT report_id, r:value:opens_followup_loop::BOOLEAN, r:value FROM (
  SELECT report_id, AI_COMPLETE(model => 'claude-haiku-4-5',
    prompt => 'Does this chest X-ray report recommend a follow-up action (for example CT or further imaging) for a finding that must be tracked? '
           || 'Answer false for normal studies, negated or stable findings with no recommendation, or no follow-up needed. Report: ' || text,
    model_parameters => {'temperature': 0},
    response_format => {'type':'json','schema':{'type':'object','properties':{'opens_followup_loop':{'type':'boolean'}},'required':['opens_followup_loop']}},
    return_error_details => TRUE) AS r
  FROM RAW.REPORTS WHERE set_name = 'A' AND report_id NOT IN (SELECT report_id FROM EVAL.SETA_AI_CACHE));

CREATE OR REPLACE TABLE EVAL.SETA_RESULTS AS
WITH lab AS (SELECT 'RA' || uid AS report_id, expect_loop = 'Y' AS exp_loop, NULLIF(finding_type, 'NONE') AS exp_type, hedged = 'Y' AS exp_hedged FROM EVAL.SETA_LABELS),
sys AS (SELECT report_id, MAX_BY(finding_type, -tier) AS got_type, BOOLOR_AGG(hedged) AS got_hedged FROM CORE.LOOPS WHERE report_id LIKE 'RA%' GROUP BY 1),
kw AS (SELECT report_id,
         REGEXP_LIKE(text, '.*(recommend|follow-up|follow up|further evaluation|ct (is|may be) (recommended|considered)).*', 'is')
         AND NOT REGEXP_LIKE(text, '.*(no (routine )?follow-up|no further follow).*', 'is') AS got_loop
       FROM RAW.REPORTS WHERE set_name = 'A')
SELECT l.report_id, l.exp_loop, l.exp_type, l.exp_hedged,
  s.report_id IS NOT NULL AS sys_loop, s.got_type AS sys_type, s.got_hedged AS sys_hedged,
  k.got_loop AS kw_loop, a.opens_loop AS ai_loop,
  e.err IS NOT NULL AS extraction_error
FROM lab l LEFT JOIN sys s USING (report_id) LEFT JOIN kw k USING (report_id) LEFT JOIN EVAL.SETA_AI_CACHE a USING (report_id)
LEFT JOIN (SELECT report_id, MAX(err) err FROM AI.EXTRACTIONS WHERE err IS NOT NULL AND report_id NOT IN (SELECT report_id FROM AI.EXTRACTIONS WHERE err IS NULL) GROUP BY 1) e USING (report_id);

-- Per-method detection metrics (precision, recall, accuracy with Wilson 95% CI).
CREATE OR REPLACE TABLE EVAL.SETA_SUMMARY AS
WITH m AS (
  SELECT 'SYSTEM' method, exp_loop, sys_loop got FROM EVAL.SETA_RESULTS
  UNION ALL SELECT 'KEYWORD', exp_loop, kw_loop FROM EVAL.SETA_RESULTS
  UNION ALL SELECT 'AI_ONLY', exp_loop, COALESCE(ai_loop, FALSE) FROM EVAL.SETA_RESULTS),
c AS (SELECT method, COUNT(*) n, COUNT_IF(exp_loop AND got) tp, COUNT_IF(NOT exp_loop AND got) fp, COUNT_IF(exp_loop AND NOT got) fn,
             COUNT_IF(exp_loop = got) k FROM m GROUP BY 1)
SELECT method, n, tp, fp, fn, k AS correct, ROUND(k / n, 3) AS accuracy,
  ROUND((k / n + 1.92 / n - 1.96 * SQRT((k / n) * (1 - k / n) / n + 0.9604 / (n * n))) / (1 + 3.8416 / n), 3) AS acc_ci_low,
  ROUND((k / n + 1.92 / n + 1.96 * SQRT((k / n) * (1 - k / n) / n + 0.9604 / (n * n))) / (1 + 3.8416 / n), 3) AS acc_ci_high,
  ROUND(tp / NULLIF(tp + fp, 0), 3) AS precision, ROUND(tp / NULLIF(tp + fn, 0), 3) AS recall
FROM c ORDER BY method;

SELECT * FROM EVAL.SETA_SUMMARY;
-- Field accuracy for the system on true positives.
SELECT COUNT_IF(exp_loop AND sys_loop) AS tp, COUNT_IF(exp_loop AND sys_loop AND sys_type = exp_type) AS type_ok,
       COUNT_IF(exp_loop AND sys_loop AND sys_hedged = exp_hedged) AS hedged_ok, COUNT_IF(extraction_error) AS extraction_errors
FROM EVAL.SETA_RESULTS;
