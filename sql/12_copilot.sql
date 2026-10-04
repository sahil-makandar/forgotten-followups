-- 12 Copilot layer: guideline text, Cortex Search, agent tools (explain priority, draft letter), approvals, semantic view.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

-- Paraphrased guideline rules (our own words, from docs/RULE_SHEET.md) so answers can cite them.
CREATE OR REPLACE TABLE APP.RULE_TEXT (rule_id STRING, title STRING, text STRING, source STRING);
INSERT INTO APP.RULE_TEXT VALUES
 ('R1','Lung nodule size and intervals (Fleischner 2017)','Nodule size is the average of the long and short axis, rounded to the nearest mm; a 9 x 7 mm nodule counts as 8 mm. Part-solid nodules are judged by the solid part. Solid under 6 mm: no routine follow-up. Solid 6 to 8 mm: CT at 6 to 12 months. Solid over 8 mm: CT at about 3 months, PET/CT or tissue sampling, tier 1. Part-solid 6 mm or more: CT at 3 to 6 months, tier 1 if the solid part is 6 mm or more. Ground-glass 6 mm or more: CT at 6 to 12 months, tier 3.','https://pubs.rsna.org/doi/full/10.1148/radiol.2017161659'),
 ('R2','What closes a CT loop','CT chest (CPT 71250, 71260, 71270), PET/CT (78815) or biopsy (32405) after the index report closes the loop only when the new report discusses the nodule (checked by AI_FILTER). Low-dose screening CT (71271) closes only on the lung screening pathway. A chest X-ray (71045, 71046) is the wrong test and never closes a CT loop.','docs/RULE_SHEET.md'),
 ('R3','Chest X-ray recommending CT','Action is CT chest within 1 month unless another interval is stated. Tier 1 if the wording is suspicious or mass, otherwise tier 2.','Radiologist recommendation'),
 ('R4','Abdominal aortic aneurysm (SVS 2018)','5.5 cm or more in men or 5.0 cm or more in women: vascular surgery referral within 1 month, tier 1. Otherwise surveillance ultrasound about every 6 months at 5.0 to 5.4 cm, every 12 months at 4.0 to 4.9 cm (tier 2), every 3 years at 3.0 to 3.9 cm (tier 3). Closing one surveillance loop opens the next check-up.','Chaikof EL et al., J Vasc Surg 2018;67:2-77'),
 ('R5','Pathway routing','Known cancer goes to oncology surveillance; immunosuppression or age under 35 goes to clinician review; screening enrolment goes to the lung screening pathway (Lung-RADS). These patients are listed with the reason and never silently dropped.','Fleischner 2017 exclusions'),
 ('R6','Loop states','OPEN: not due yet. RED: past the due date with no matching test. AMBER: a payer claim shows the right test at another hospital but no report yet; an outside-report request is created. GREEN: a follow-up report exists and AI_FILTER confirms it discusses the finding. CANCELLED needs a written reason plus clinician sign-off. REROUTED: moved to another pathway with the reason shown.','docs/RULE_SHEET.md'),
 ('R7','Priority','Score = tier band (tier 1: 3000, tier 2: 2000, tier 3: 1000) + share of due window elapsed x 150 (capped at 900) + context (age 65+ +25, current smoker +25, former smoker +15; at most 50). Bands never overlap. TB history is context only and never raises priority. Subsolid nodules in never-smoker women are never downgraded (Asia consensus 2016).','https://pubmed.ncbi.nlm.nih.gov/26923625');

-- Search corpus: report text (full-detail only) plus guideline rules.
CREATE OR REPLACE TABLE APP.SEARCH_CORPUS AS
SELECT 'REPORT' AS doc_type, report_id AS doc_id, patient_id, report_date::STRING AS doc_date, modality AS title, text FROM RAW.REPORTS
UNION ALL
SELECT 'RULE', rule_id, NULL, NULL, title, title || ': ' || text || ' Source: ' || source FROM APP.RULE_TEXT;
ALTER TABLE APP.SEARCH_CORPUS SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE CORTEX SEARCH SERVICE APP.REPORT_SEARCH
  ON text ATTRIBUTES doc_type, doc_id, patient_id, doc_date, title
  WAREHOUSE = COMPUTE_WH TARGET_LAG = '1 day'
  AS SELECT text, doc_type, doc_id, patient_id, doc_date, title FROM APP.SEARCH_CORPUS;

-- Tool 1: explain priority, with citations (report line, record, rule). One shared view feeds the UDF and the agent tool.
CREATE OR REPLACE VIEW APP.LOOP_EXPLANATION AS
SELECT s.loop_id, s.patient_id,
  'Loop ' || s.loop_id || ' (patient ' || s.patient_id || ') is ' || s.status || ', tier ' || s.tier || ', priority ' || s.priority:score::STRING || '. '
    || 'Breakdown: ' || s.priority:tier_points::STRING || ' tier + ' || s.priority:time_points::STRING || ' time (' || ROUND(s.priority:elapsed_share::FLOAT * 100) || '% of due window elapsed) + '
    || s.priority:context_points::STRING || ' context' || IFF(ARRAY_SIZE(s.priority:notes) > 0, ' [' || ARRAY_TO_STRING(s.priority:notes::ARRAY, '; ') || ']', '') || '. '
    || 'Status: ' || s.status_reason || '. Due ' || s.due_start || ' to ' || s.due_end || '. '
    || 'Clinician acknowledged: ' || s.clinician_acked || '; patient notified: ' || s.patient_notified || '. '
    || 'Report line [' || s.report_id || ', ' || s.report_date || ']: "' || s.quote || '"' || IFF(s.quote_verified, ' (verified word for word)', ' (QUOTE NOT VERIFIED)') || '. '
    || 'Rule: ' || CASE WHEN s.finding_type = 'LUNG_NODULE' THEN 'R1 Fleischner 2017' WHEN s.finding_type = 'AAA' THEN 'R4 SVS 2018'
                        WHEN s.finding_type = 'CXR_RECOMMEND_CT' THEN 'R3 radiologist recommendation' ELSE s.finding_type END
    || '; priority rule R7.' || COALESCE(' QA: ' || s.qa_flag, '') AS explanation,
  w.rank, (SELECT COUNT(*) FROM CORE.WORKLIST) AS worklist_size
FROM CORE.LOOP_STATUS s LEFT JOIN CORE.WORKLIST w ON w.loop_id = s.loop_id;

CREATE OR REPLACE FUNCTION APP.EXPLAIN_PRIORITY(P_LOOP_ID STRING)
RETURNS STRING AS
$$
  SELECT MAX(explanation) FROM FFU.APP.LOOP_EXPLANATION WHERE loop_id = P_LOOP_ID
$$;

-- Agent tool: accepts a loop_id, a patient_id, or TOP (rank-1 worklist loop); adds the worklist rank.
CREATE OR REPLACE PROCEDURE APP.EXPLAIN_PRIORITY_TOOL(ID STRING)
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER AS
$$
DECLARE out STRING;
BEGIN
  out := (SELECT LISTAGG(IFF(rank IS NULL, 'Not on the red/amber worklist. ',
                             'Worklist rank ' || rank || ' of ' || worklist_size || ' (ordered by tier, then priority score, then days overdue). ')
                         || explanation, ' || ')
          FROM FFU.APP.LOOP_EXPLANATION
          WHERE loop_id = :ID OR patient_id = :ID OR (UPPER(:ID) = 'TOP' AND rank = 1));
  RETURN COALESCE(out, 'No loop found for ' || :ID);
END;
$$;

-- Tool 2: draft a patient recall letter or a referral. Always a DRAFT until a clinician approves it.
CREATE TABLE IF NOT EXISTS APP.APPROVALS (draft_id STRING DEFAULT UUID_STRING(), loop_id STRING, kind STRING, draft STRING,
  status STRING DEFAULT 'PENDING_CLINICIAN_APPROVAL', created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  approved_by STRING, approved_at TIMESTAMP_NTZ);

CREATE OR REPLACE PROCEDURE APP.DRAFT_LETTER(LOOP_ID STRING, KIND STRING)
RETURNS STRING LANGUAGE SQL AS
$$
DECLARE d STRING; ctx STRING;
BEGIN
  ctx := (SELECT APP.EXPLAIN_PRIORITY(:LOOP_ID));
  IF (ctx IS NULL) THEN RETURN 'Unknown loop ' || :LOOP_ID; END IF;
  d := (SELECT AI_COMPLETE('claude-sonnet-4-5',
    'Write a short ' || IFF(UPPER(:KIND) = 'REFERRAL', 'referral letter to the appropriate specialist', 'patient recall letter in plain, kind English (reading age about 12)')
    || ' asking for the follow-up described below. Do not diagnose, do not state a cancer risk, do not invent facts, dates or names. '
    || 'Use [Clinician name] and [Hospital phone] as placeholders. End with the line "Evidence: " followed by the quoted report line and its report id. '
    || 'Facts: ' || :ctx));
  INSERT INTO APP.APPROVALS (loop_id, kind, draft) VALUES (:LOOP_ID, UPPER(:KIND), :d);
  RETURN 'DRAFT - pending clinician approval (nothing has been sent).' || CHR(10) || :d;
END;
$$;

CREATE OR REPLACE PROCEDURE APP.APPROVE_DRAFT(DRAFT_ID STRING, CLINICIAN STRING)
RETURNS STRING LANGUAGE SQL AS
$$
BEGIN
  UPDATE APP.APPROVALS SET status = 'APPROVED', approved_by = :CLINICIAN, approved_at = CURRENT_TIMESTAMP()
  WHERE draft_id = :DRAFT_ID AND status = 'PENDING_CLINICIAN_APPROVAL';
  RETURN IFF(SQLROWCOUNT = 1, 'Approved by ' || :CLINICIAN || ' (logged).', 'No pending draft ' || :DRAFT_ID);
END;
$$;

-- Quote verification as a callable check (used by the app and agent answers).
CREATE OR REPLACE FUNCTION APP.VERIFY_QUOTE(P_REPORT_ID STRING, P_QUOTE STRING)
RETURNS BOOLEAN AS
$$
  SELECT COALESCE(MAX(CONTAINS(REGEXP_REPLACE(LOWER(text), '\\s+', ' '), REGEXP_REPLACE(LOWER(TRIM(P_QUOTE)), '\\s+', ' '))), FALSE)
  FROM RAW.REPORTS WHERE report_id = P_REPORT_ID
$$;

-- Semantic view over the role-aware secure view, for Cortex Analyst.
CREATE OR REPLACE SEMANTIC VIEW APP.LOOPS_SV
  TABLES (loops AS SEC.LOOPS_V PRIMARY KEY (loop_id)
          COMMENT = 'One row per follow-up loop: a recommended next step from a scan report and whether it happened')
  FACTS (loops.avg_mm AS avg_mm COMMENT = 'Lung nodule size in mm (average of long and short axis)',
         loops.aorta_cm AS aorta_cm COMMENT = 'Aortic aneurysm diameter in cm',
         loops.days_overdue_f AS days_overdue COMMENT = 'Days past the due date (0 if not overdue)',
         loops.priority_f AS priority_score COMMENT = 'Priority score; tier band 3000/2000/1000 plus time and context')
  DIMENSIONS (loops.loop_id AS loop_id, loops.patient_id AS patient_id, loops.clinic_id AS clinic_id,
              loops.finding_type AS finding_type COMMENT = 'LUNG_NODULE, CXR_RECOMMEND_CT, AAA, THYROID_NODULE',
              loops.nodule_type AS nodule_type, loops.tier AS tier COMMENT = 'Danger tier: 1 is most dangerous',
              loops.pathway AS pathway, loops.action AS action,
              loops.status AS status COMMENT = 'OPEN, RED (overdue), AMBER (done elsewhere, report needed), GREEN (verified), REROUTED, CANCELLED',
              loops.report_date AS report_date, loops.due_end AS due_end,
              loops.patient_notified AS patient_notified, loops.clinician_acked AS clinician_acked,
              loops.closed_by_outside_claim_only AS closed_by_outside_claim_only COMMENT = 'TRUE when the only evidence is a payer claim from another hospital',
              loops.wrong_test_seen AS wrong_test_seen COMMENT = 'TRUE when a wrong test (e.g. chest X-ray for a CT loop) was found')
  METRICS (loops.loop_count AS COUNT(loop_id) COMMENT = 'Number of loops',
           loops.overdue_count AS COUNT_IF(status = 'RED') COMMENT = 'Number of overdue loops',
           loops.avg_days_overdue AS AVG(NULLIF(days_overdue, 0)) COMMENT = 'Average days overdue among overdue loops')
  COMMENT = 'Forgotten Follow-ups loop status (synthetic data)';

GRANT USAGE ON SCHEMA FFU.APP TO ROLE FFU_COORDINATOR;
GRANT USAGE ON SCHEMA FFU.APP TO ROLE FFU_ANALYST;
GRANT SELECT ON SEMANTIC VIEW APP.LOOPS_SV TO ROLE FFU_COORDINATOR;
GRANT SELECT ON SEMANTIC VIEW APP.LOOPS_SV TO ROLE FFU_ANALYST;
