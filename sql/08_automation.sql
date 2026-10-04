-- 08 Automation: AI_FILTER checks, pipeline procedure, outside-report requests, overdue Alert, Stream + Task.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CREATE TABLE IF NOT EXISTS APP.OUTSIDE_REPORT_REQUESTS (
  loop_id STRING, patient_id STRING, claim STRING, requested_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), status STRING DEFAULT 'REQUESTED');
CREATE TABLE IF NOT EXISTS APP.ALERTS (
  loop_id STRING, patient_id STRING, tier NUMBER, message STRING, sim_date DATE,
  fired_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

-- Ask AI_FILTER once per (loop, hospital follow-up report) pair; results are cached.
CREATE OR REPLACE PROCEDURE AI.CHECK_FOLLOWUPS()
RETURNS NUMBER LANGUAGE SQL AS
$$
BEGIN
  INSERT INTO AI.FOLLOWUP_CHECKS (loop_id, evidence_id, discusses)
  SELECT l.loop_id, r.report_id,
    AI_FILTER(PROMPT('A prior study reported: {0}. Does the following later report explicitly discuss that same finding (for example stable, changed, resolved or re-measured)? Later report: {1}',
      l.finding_type || ' ' || COALESCE(l.location, '') || ' - "' || l.quote || '"', r.text))
  FROM CORE.LOOPS l
  JOIN RAW.REPORTS r ON r.patient_id = l.patient_id AND r.report_date > l.report_date AND r.report_id <> l.report_id
  JOIN CORE.CLOSURE_CODES c ON c.action = l.action AND c.cpt = r.cpt AND c.closes
  WHERE NOT EXISTS (SELECT 1 FROM AI.FOLLOWUP_CHECKS x WHERE x.loop_id = l.loop_id AND x.evidence_id = r.report_id);
  RETURN SQLROWCOUNT;
END;
$$;

-- Full pipeline: extract new reports, rebuild loops, check follow-ups, refresh status, file outside-report requests.
CREATE OR REPLACE PROCEDURE CORE.RUN_PIPELINE()
RETURNS STRING LANGUAGE SQL AS
$$
DECLARE n_extract NUMBER; n_check NUMBER;
BEGIN
  n_extract := (CALL AI.EXTRACT_NEW('claude-haiku-4-5', 1000));
  ALTER DYNAMIC TABLE CORE.FINDINGS REFRESH;
  ALTER DYNAMIC TABLE CORE.EXTRA_RULES REFRESH;
  ALTER DYNAMIC TABLE CORE.LOOPS REFRESH;
  n_check := (CALL AI.CHECK_FOLLOWUPS());
  ALTER DYNAMIC TABLE CORE.LOOP_STATUS REFRESH;
  INSERT INTO APP.OUTSIDE_REPORT_REQUESTS (loop_id, patient_id, claim)
  SELECT loop_id, patient_id, amber_evidence FROM CORE.LOOP_STATUS s
  WHERE status = 'AMBER' AND clinic_id <> 'EVAL' AND NOT EXISTS (SELECT 1 FROM APP.OUTSIDE_REPORT_REQUESTS o WHERE o.loop_id = s.loop_id);
  RETURN 'extracted=' || n_extract || ' followup_checks=' || n_check;
END;
$$;

-- Move the demo clock and recompute.
CREATE OR REPLACE PROCEDURE CTRL.SET_SIM_DATE(D DATE)
RETURNS STRING LANGUAGE SQL AS
$$
BEGIN
  UPDATE CTRL.SIM_DATE SET sim_date = :D;
  ALTER DYNAMIC TABLE CORE.LOOP_STATUS REFRESH;
  RETURN 'sim_date=' || :D;
END;
$$;

-- Overdue Alert: a tier-1 loop goes red. Serverless, hourly; the app can also run EXECUTE ALERT.
CREATE OR REPLACE ALERT APP.OVERDUE_ALERT
  SCHEDULE = '60 MINUTE'
  IF (EXISTS (SELECT 1 FROM CORE.LOOP_STATUS s WHERE status = 'RED' AND tier = 1 AND clinic_id <> 'EVAL'
              AND NOT EXISTS (SELECT 1 FROM APP.ALERTS a WHERE a.loop_id = s.loop_id)))
  THEN
    INSERT INTO APP.ALERTS (loop_id, patient_id, tier, message, sim_date)
    SELECT loop_id, patient_id, tier, 'Tier 1 ' || finding_type || ' overdue: ' || status_reason, sim_date
    FROM CORE.LOOP_STATUS s WHERE status = 'RED' AND tier = 1 AND clinic_id <> 'EVAL'
      AND NOT EXISTS (SELECT 1 FROM APP.ALERTS a WHERE a.loop_id = s.loop_id);
ALTER ALERT APP.OVERDUE_ALERT RESUME;

-- New reports landing trigger the pipeline.
CREATE STREAM IF NOT EXISTS RAW.REPORTS_STREAM ON TABLE RAW.REPORTS APPEND_ONLY = TRUE;
CREATE TABLE IF NOT EXISTS RAW.REPORT_ARRIVALS (report_id STRING, seen_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
CREATE OR REPLACE TASK AI.ON_NEW_REPORT
  WAREHOUSE = COMPUTE_WH SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('RAW.REPORTS_STREAM')
AS EXECUTE IMMEDIATE $$
BEGIN
  INSERT INTO FFU.RAW.REPORT_ARRIVALS (report_id) SELECT report_id FROM FFU.RAW.REPORTS_STREAM;
  CALL FFU.CORE.PROCESS_NEW_REPORTS();
END;
$$;
ALTER TASK AI.ON_NEW_REPORT RESUME;



