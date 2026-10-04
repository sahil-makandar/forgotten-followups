-- Set B scoring: compares every labelled finding with what the system produced. Run after the pipeline.
-- A label matches the loop on the same report with the same finding type (nearest size if several).
-- Writes one row per label to EVAL.SETB_RESULTS and returns the summary.
USE ROLE ACCOUNTADMIN;
USE DATABASE FFU;

CREATE OR REPLACE TABLE EVAL.SETB_RESULTS AS
WITH lab AS (
  SELECT l.*, 'RB' || SUBSTR(l.case_id, 2) AS report_id FROM EVAL.SETB_LABELS l
), cand AS (
  SELECT lab.case_id, lab.finding_no, s.loop_id, s.finding_type, s.avg_mm, s.aorta_cm, s.tier, s.action, s.pathway, s.status,
         s.quote_verified, s.qa_flag,
         ROW_NUMBER() OVER (PARTITION BY lab.case_id, lab.finding_no
                            ORDER BY ABS(COALESCE(s.avg_mm, s.aorta_cm * 10, 0) - COALESCE(lab.avg_mm, lab.aorta_cm * 10, 0))) AS rn
  FROM lab JOIN CORE.LOOP_STATUS s
    ON s.report_id = lab.report_id
   AND (s.finding_type = lab.finding_type OR (lab.finding_type IS NULL))
)
SELECT lab.case_id, lab.finding_no, lab.trap, lab.expect_loop, lab.expect_status,
  c.loop_id IS NOT NULL AS got_loop, COALESCE(c.status, 'NO_LOOP') AS got_status,
  lab.finding_type AS exp_type, c.finding_type AS got_type,
  lab.avg_mm AS exp_mm, c.avg_mm AS got_mm, lab.aorta_cm AS exp_cm, c.aorta_cm AS got_cm,
  lab.tier AS exp_tier, c.tier AS got_tier, lab.action AS exp_action, c.action AS got_action,
  lab.pathway AS exp_pathway, c.pathway AS got_pathway, c.quote_verified, c.qa_flag,
  -- Field checks only where a loop is expected AND produced.
  lab.expect_loop = (c.loop_id IS NOT NULL) AS loop_ok,
  COALESCE(c.status, 'NO_LOOP') = lab.expect_status AS status_ok,
  IFF(lab.expect_loop AND c.loop_id IS NOT NULL, (lab.avg_mm IS NULL OR c.avg_mm = lab.avg_mm) AND (lab.aorta_cm IS NULL OR c.aorta_cm = lab.aorta_cm), NULL) AS size_ok,
  IFF(lab.expect_loop AND c.loop_id IS NOT NULL, c.tier = lab.tier, NULL) AS tier_ok,
  IFF(lab.expect_loop AND c.loop_id IS NOT NULL, c.action = lab.action, NULL) AS action_ok,
  IFF(lab.expect_loop AND c.loop_id IS NOT NULL, c.pathway = lab.pathway, NULL) AS pathway_ok,
  COALESCE(c.status, 'NO_LOOP') = 'GREEN' AND lab.expect_status <> 'GREEN' AS false_green
FROM lab LEFT JOIN cand c ON c.case_id = lab.case_id AND c.finding_no = lab.finding_no AND c.rn = 1
  AND (lab.expect_loop OR lab.finding_type IS NULL OR c.avg_mm = lab.avg_mm);

SELECT COUNT(*) AS findings,
  COUNT_IF(status_ok) AS status_correct, ROUND(COUNT_IF(status_ok) / COUNT(*), 3) AS status_accuracy,
  COUNT_IF(loop_ok) AS loop_presence_correct,
  COUNT_IF(size_ok) || '/' || COUNT(size_ok) AS size, COUNT_IF(tier_ok) || '/' || COUNT(tier_ok) AS tier,
  COUNT_IF(action_ok) || '/' || COUNT(action_ok) AS action, COUNT_IF(pathway_ok) || '/' || COUNT(pathway_ok) AS pathway,
  COUNT_IF(false_green) AS false_greens,
  COUNT_IF(quote_verified) || '/' || COUNT(quote_verified) AS quotes_verified
FROM EVAL.SETB_RESULTS;
