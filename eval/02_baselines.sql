-- Baselines vs the system, on the same report-level ground truth.
--   KEYWORD : "recommend / follow-up" opens a loop; ANY later event (any CPT, any source) closes it; due = 6 months.
--   AI_ONLY : claude-haiku-4-5 reads the report plus the later events and picks the status itself (no rules).
--   SYSTEM  : this project (AI extraction + deterministic rules).
-- Ground truth: Set C = hidden answer key; Set B = finding 1 label of each case. Scored at sim_date 2026-10-04.
-- AI-only runs on all Set B reports and a fixed 100-report sample of Set C (cost control); results are cached.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CREATE OR REPLACE TABLE EVAL.TRUTH AS
SELECT 'C' AS set_name, k.report_id,
  CASE WHEN expected_action = 'NONE_REQUIRED' THEN 'NO_LOOP' WHEN expected_pathway <> 'STANDARD' THEN 'REROUTED'
       WHEN outcome = 'HOSP_DONE' THEN 'GREEN' WHEN outcome = 'OUTSIDE_CLAIM' THEN 'AMBER'
       WHEN DATEADD(day, ROUND(30.4 * due_max_months), report_date) < '2026-10-04' THEN 'RED' ELSE 'OPEN' END AS exp
FROM KEY.ANSWER_KEY k
UNION ALL
SELECT 'B', 'RB' || SUBSTR(case_id, 2), expect_status FROM EVAL.SETB_LABELS WHERE finding_no = 1;

-- Later events visible to every method (hospital reports and payer claims), up to the scoring date.
CREATE OR REPLACE TEMPORARY TABLE EVAL.T_EVENTS AS
SELECT t.report_id, LISTAGG(e.source || ' ' || e.event_date || ' CPT ' || e.cpt, '; ') WITHIN GROUP (ORDER BY e.event_date) AS events, COUNT(*) AS n
FROM EVAL.TRUTH t JOIN RAW.REPORTS r ON r.report_id = t.report_id
JOIN CORE.EVIDENCE e ON e.patient_id = r.patient_id AND e.event_date > r.report_date AND e.event_date <= '2026-10-04' AND e.evidence_id <> r.report_id
GROUP BY 1;

-- Keyword baseline.
CREATE OR REPLACE TABLE EVAL.BASELINE_KEYWORD AS
SELECT t.set_name, t.report_id, t.exp,
  CASE WHEN NOT REGEXP_LIKE(r.text, '.*(recommend|follow-up|follow up|further evaluation).*', 'is')
         OR REGEXP_LIKE(r.text, '.*(no (routine )?follow-up|no further follow|follow-up is not).*', 'is') THEN 'NO_LOOP'
       WHEN COALESCE(ev.n, 0) > 0 THEN 'GREEN'
       WHEN DATEADD(month, 6, r.report_date) < '2026-10-04' THEN 'RED' ELSE 'OPEN' END AS got
FROM EVAL.TRUTH t JOIN RAW.REPORTS r ON r.report_id = t.report_id LEFT JOIN EVAL.T_EVENTS ev ON ev.report_id = t.report_id;

-- AI-only baseline (cached).
CREATE TABLE IF NOT EXISTS EVAL.BASELINE_AI_CACHE (report_id STRING, got STRING, raw VARIANT, model STRING, run_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
INSERT INTO EVAL.BASELINE_AI_CACHE (report_id, got, raw, model)
SELECT report_id, r:value:status::STRING, r:value, 'claude-haiku-4-5' FROM (
  SELECT t.report_id, AI_COMPLETE(model => 'claude-haiku-4-5',
    prompt => 'You track whether follow-up recommendations from radiology reports were completed. Today is 2026-10-04. '
      || 'Patient: ' || p.age || ' year old ' || p.sex || IFF(p.known_cancer, ', known cancer', '') || IFF(p.immunosuppressed, ', immunosuppressed', '')
      || IFF(p.screening_enrolled, ', in a lung screening programme', '') || '. Report dated ' || r.report_date || ':' || CHR(10) || r.text || CHR(10)
      || 'Later events (hospital reports and insurance claims with CPT codes): ' || COALESCE(ev.events, 'none') || '. '
      || 'Choose one status: NO_LOOP (no follow-up recommended), OPEN (recommended, not yet due), RED (overdue, not done), '
      || 'AMBER (done at another hospital per a claim, no report), GREEN (done and a follow-up report confirms it), REROUTED (patient should be on a different pathway).',
    model_parameters => {'temperature': 0},
    response_format => {'type':'json','schema':{'type':'object','properties':{'status':{'type':'string','enum':['NO_LOOP','OPEN','RED','AMBER','GREEN','REROUTED']}},'required':['status']}},
    return_error_details => TRUE) AS r
  FROM EVAL.TRUTH t JOIN RAW.REPORTS r ON r.report_id = t.report_id JOIN RAW.PATIENTS p ON p.patient_id = r.patient_id
  LEFT JOIN EVAL.T_EVENTS ev ON ev.report_id = t.report_id
  WHERE (t.set_name = 'B' OR ABS(HASH(t.report_id, 'ai_sample')) % 7 = 0)
    AND t.report_id NOT IN (SELECT report_id FROM EVAL.BASELINE_AI_CACHE));

-- System status per report (same rule as EVAL.RUN_EVAL: highest-tier loop).
CREATE OR REPLACE TABLE EVAL.BASELINE_COMPARE AS
WITH sys AS (SELECT report_id, MAX_BY(status, -tier) AS got FROM CORE.LOOP_STATUS GROUP BY 1)
SELECT 'SYSTEM' AS method, t.set_name, t.report_id, t.exp, COALESCE(s.got, 'NO_LOOP') AS got FROM EVAL.TRUTH t LEFT JOIN sys s USING (report_id)
UNION ALL SELECT 'KEYWORD', set_name, report_id, exp, got FROM EVAL.BASELINE_KEYWORD
UNION ALL SELECT 'AI_ONLY', t.set_name, t.report_id, t.exp, COALESCE(a.got, 'ERROR') FROM EVAL.TRUTH t JOIN EVAL.BASELINE_AI_CACHE a USING (report_id);

-- Summary per method and set, with a Wilson 95% interval on accuracy. False-green rate is over loops that should NOT be green
-- (the safety question: "of the loops still open, how many did we wrongly close?"); rule of three gives the bound when zero.
CREATE OR REPLACE TABLE EVAL.BASELINE_SUMMARY AS
WITH s AS (
  SELECT method, set_name, COUNT(*) n, COUNT_IF(exp = got) k, COUNT_IF(got = 'GREEN' AND exp <> 'GREEN') fg, COUNT_IF(exp <> 'GREEN') not_green
  FROM EVAL.BASELINE_COMPARE GROUP BY 1, 2)
SELECT method, set_name, n, k AS correct, ROUND(k / n, 3) AS accuracy,
  ROUND((k / n + 1.92 / n - 1.96 * SQRT((k / n) * (1 - k / n) / n + 0.9604 / (n * n))) / (1 + 3.8416 / n), 3) AS acc_ci_low,
  ROUND((k / n + 1.92 / n + 1.96 * SQRT((k / n) * (1 - k / n) / n + 0.9604 / (n * n))) / (1 + 3.8416 / n), 3) AS acc_ci_high,
  fg AS false_greens, not_green AS should_not_be_green, ROUND(fg / not_green, 3) AS false_green_rate,
  ROUND(IFF(fg = 0, 3 / not_green, NULL), 3) AS false_green_upper95_rule_of_3
FROM s ORDER BY set_name, method;

SELECT * FROM EVAL.BASELINE_SUMMARY;
