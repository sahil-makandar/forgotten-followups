-- 09 Product procedures shared by the CoCo skills, the Task and the Streamlit app.
--   CORE.PROCESS_NEW_REPORTS()   followup-intake skill, task AI.ON_NEW_REPORT, app refresh button
--   CORE.AUDIT_LOOP(id)          loop-auditor skill, app "audit" button
--   CTRL.DEMO_RESET()            demo-reset skill
--   EVAL.RUN_EVAL(label)         defined in eval/01_run_eval.sql (only EVAL may read KEY)
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

-- Intake: extract new reports, apply rules, refresh, and return the loops created by this run.
CREATE OR REPLACE PROCEDURE CORE.PROCESS_NEW_REPORTS()
RETURNS TABLE (loop_id STRING, patient_id STRING, finding_type STRING, size STRING, tier NUMBER, pathway STRING,
               status STRING, priority_score FLOAT, due_end DATE, patient_notified BOOLEAN, quote STRING,
               quote_verified BOOLEAN, status_reason STRING, qa_flag STRING)
LANGUAGE SQL AS
$$
DECLARE t0 TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ; res RESULTSET;
BEGIN
  CALL CORE.RUN_PIPELINE();
  res := (SELECT s.loop_id, s.patient_id, s.finding_type,
                 COALESCE(s.avg_mm || ' mm (' || s.long_mm || ' x ' || s.short_mm || ')', s.aorta_cm || ' cm'),
                 s.tier, s.pathway, s.status, s.priority:score::FLOAT, s.due_end, s.patient_notified,
                 s.quote, s.quote_verified, s.status_reason, s.qa_flag
          FROM CORE.LOOP_STATUS s
          WHERE s.report_id IN (SELECT report_id FROM AI.EXTRACTIONS WHERE extracted_at >= :t0)
          ORDER BY s.tier, s.priority:score::FLOAT DESC);
  RETURN TABLE(res);
END;
$$;

-- Audit: recompute status from raw rows (hospital reports + payer share), independent of CORE.LOOP_STATUS,
-- and compare with the label the app shows. Accepts a patient_id or a loop_id.
CREATE OR REPLACE PROCEDURE CORE.AUDIT_LOOP(ID STRING)
RETURNS TABLE (loop_id STRING, app_status STRING, audit_status STRING, match BOOLEAN, rule STRING,
               index_citation STRING, evidence STRING, communication STRING)
LANGUAGE SQL AS
$$
DECLARE res RESULTSET;
BEGIN
  res := (
    WITH d AS (SELECT MAX(sim_date) AS sim_date FROM CTRL.SIM_DATE),
    l AS (SELECT * FROM CORE.LOOPS WHERE patient_id = :ID OR loop_id = :ID),
    raw_ev AS (
      SELECT l.loop_id, 'HOSPITAL' src, r.report_id ev_id, r.report_date ev_date, r.cpt, r.facility,
             cc.closes, cc.screening_only, cc.note, fc.discusses
      FROM l JOIN RAW.REPORTS r ON r.patient_id = l.patient_id AND r.report_date > l.report_date AND r.report_id <> l.report_id
      JOIN CORE.CLOSURE_CODES cc ON cc.action = l.action AND cc.cpt = r.cpt
      LEFT JOIN AI.FOLLOWUP_CHECKS fc ON fc.loop_id = l.loop_id AND fc.evidence_id = r.report_id
      CROSS JOIN d WHERE r.report_date <= d.sim_date
      UNION ALL
      SELECT l.loop_id, 'PAYER_CLAIM', p.event_id, p.service_date, p.cpt, p.facility, cc.closes, cc.screening_only, cc.note, NULL
      FROM l JOIN PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS p ON p.patient_id = l.patient_id AND p.service_date > l.report_date
      JOIN CORE.CLOSURE_CODES cc ON cc.action = l.action AND cc.cpt = p.cpt
      CROSS JOIN d WHERE p.service_date <= d.sim_date),
    a AS (
      SELECT l.loop_id,
        CASE WHEN l.pathway <> 'STANDARD' THEN 'REROUTED'
             WHEN EXISTS (SELECT 1 FROM APP.CANCELLATIONS c WHERE c.loop_id = l.loop_id AND c.clinician IS NOT NULL AND c.reason IS NOT NULL) THEN 'CANCELLED'
             WHEN COUNT_IF(e.src = 'HOSPITAL' AND e.closes AND (NOT e.screening_only OR l.pathway = 'LUNG_SCREENING') AND e.discusses) > 0 THEN 'GREEN'
             WHEN COUNT_IF(e.src = 'PAYER_CLAIM' AND e.closes AND (NOT e.screening_only OR l.pathway = 'LUNG_SCREENING')) > 0 THEN 'AMBER'
             WHEN ANY_VALUE(d.sim_date) > l.due_end THEN 'RED' ELSE 'OPEN' END AS audit_status,
        LISTAGG(e.src || ' ' || e.ev_id || ' ' || e.ev_date || ' CPT ' || e.cpt || ' at ' || e.facility || ': '
                || IFF(e.closes, 'correct test', 'WRONG TEST - ' || e.note)
                || IFF(e.src = 'HOSPITAL', ', AI_FILTER discusses finding=' || COALESCE(e.discusses::STRING, 'not checked'), ''), ' | ') AS evidence
      FROM l CROSS JOIN d LEFT JOIN raw_ev e ON e.loop_id = l.loop_id
      GROUP BY l.loop_id, l.pathway, l.due_end)
    SELECT l.loop_id, s.status, a.audit_status, s.status = a.audit_status,
      l.finding_type || ' tier ' || l.tier || ', action ' || l.action || ', due ' || l.due_start || ' to ' || l.due_end
        || ', pathway ' || l.pathway || COALESCE(' (' || l.reroute_reason || ')', '') || COALESCE('; QA: ' || l.qa_flag, ''),
      l.report_id || ' (' || l.report_date || '): "' || l.quote || '"' || IFF(l.quote_verified, ' [quote verified]', ' [QUOTE NOT FOUND IN SOURCE]'),
      COALESCE(a.evidence, 'no follow-up evidence found'),
      'clinician acknowledged=' || s.clinician_acked || ', patient notified=' || s.patient_notified
    FROM l JOIN a ON a.loop_id = l.loop_id LEFT JOIN CORE.LOOP_STATUS s ON s.loop_id = l.loop_id
    ORDER BY l.loop_id);
  RETURN TABLE(res);
END;
$$;

-- Demo reset: clock back to the demo start, demo rows removed, derived tables rebuilt.
-- Payer-side demo claims (event_id LIKE 'EDEMO%') are removed by the demo-reset skill on the payer connection.
CREATE OR REPLACE PROCEDURE CTRL.DEMO_RESET(RESET_EXTENSIONS BOOLEAN)
RETURNS STRING LANGUAGE SQL AS
$$
BEGIN
  IF (:RESET_EXTENSIONS) THEN
    -- Remove rules added live by guideline-rule-compiler, so the thyroid extension can be shown again.
    CREATE OR REPLACE DYNAMIC TABLE CORE.EXTRA_RULES TARGET_LAG = DOWNSTREAM WAREHOUSE = COMPUTE_WH REFRESH_MODE = FULL AS SELECT * FROM CORE.EXTRA_RULES_EMPTY;
    DELETE FROM CORE.CLOSURE_CODES WHERE action = 'THYROID_ULTRASOUND';
  END IF;
  UPDATE CTRL.SIM_DATE SET sim_date = '2026-10-04';
  DELETE FROM AI.FOLLOWUP_CHECKS WHERE loop_id LIKE 'L-RDEMO%'
     OR evidence_id IN (SELECT report_id FROM RAW.REPORTS WHERE set_name = 'DEMO');
  DELETE FROM AI.EXTRACTIONS WHERE report_id IN (SELECT report_id FROM RAW.REPORTS WHERE set_name = 'DEMO');
  DELETE FROM RAW.REPORTS WHERE set_name = 'DEMO';
  DELETE FROM APP.ALERTS;
  DELETE FROM APP.OUTSIDE_REPORT_REQUESTS;
  DELETE FROM APP.CANCELLATIONS WHERE loop_id LIKE 'L-RDEMO%';
  ALTER DYNAMIC TABLE CORE.FINDINGS REFRESH;
  ALTER DYNAMIC TABLE CORE.EXTRA_RULES REFRESH;
  ALTER DYNAMIC TABLE CORE.LOOPS REFRESH;
  ALTER DYNAMIC TABLE CORE.LOOP_STATUS REFRESH;
  RETURN 'demo reset: sim_date=2026-10-04, demo reports, alerts and requests cleared';
END;
$$;

