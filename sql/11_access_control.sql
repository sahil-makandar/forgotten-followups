-- 11 Access control (hospital account is Standard edition: no masking or row access policies).
-- Role-aware SECURE VIEWS: a COORDINATOR sees full detail for their own clinics; an ANALYST sees all clinics, masked.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CREATE ROLE IF NOT EXISTS FFU_COORDINATOR;
CREATE ROLE IF NOT EXISTS FFU_ANALYST;
CREATE ROLE IF NOT EXISTS FFU_APP_OWNER;   -- owns the Streamlit app; sees everything
GRANT ROLE FFU_COORDINATOR TO ROLE SYSADMIN;
GRANT ROLE FFU_ANALYST TO ROLE SYSADMIN;
GRANT ROLE FFU_APP_OWNER TO ROLE SYSADMIN;

-- Which clinics each coordinator role may see in full.
CREATE TABLE IF NOT EXISTS SEC.ROLE_CLINICS (role_name STRING, clinic_id STRING);
MERGE INTO SEC.ROLE_CLINICS t USING (SELECT * FROM VALUES ('FFU_COORDINATOR','C1'),('FFU_COORDINATOR','C2')) s(role_name, clinic_id)
ON t.role_name = s.role_name AND t.clinic_id = s.clinic_id WHEN NOT MATCHED THEN INSERT VALUES (s.role_name, s.clinic_id);

-- Full-detail roles: ACCOUNTADMIN / SYSADMIN / app owner (all clinics), coordinators (own clinics).
CREATE OR REPLACE SECURE VIEW SEC.LOOPS_V AS
WITH who AS (
  -- Primary role decides; secondary roles must not widen access.
  SELECT CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SYSADMIN', 'FFU_APP_OWNER') AS is_admin,
         CURRENT_ROLE() IN ('FFU_ANALYST', 'FFU_JUDGE') AS is_analyst)  -- judges see the masked analyst view
SELECT
  s.loop_id, s.clinic_id, s.finding_type, s.nodule_type, s.avg_mm, s.aorta_cm, s.tier, s.pathway, s.action,
  s.report_date, s.due_start, s.due_end, s.status, IFF(s.status = 'RED', s.days_overdue, 0) AS days_overdue, s.priority:score::FLOAT AS priority_score,
  s.clinician_acked, s.patient_notified, s.sim_date, s.qa_flag, s.wrong_test IS NOT NULL AS wrong_test_seen,
  s.status = 'AMBER' AS closed_by_outside_claim_only,
  -- Identifiable / free-text columns: masked for analysts.
  IFF(w.is_analyst, 'P-' || SUBSTR(SHA2(s.patient_id), 1, 8), s.patient_id) AS patient_id,
  IFF(w.is_analyst, NULL, s.report_id) AS report_id,
  IFF(w.is_analyst, '***', s.quote) AS quote,
  IFF(w.is_analyst, '***', s.status_reason) AS status_reason,
  IFF(w.is_analyst, NULL, s.age) AS age,
  IFF(w.is_analyst, FLOOR(s.age / 10) * 10 || 's', NULL) AS age_band
FROM CORE.LOOP_STATUS s CROSS JOIN who w
WHERE w.is_admin OR w.is_analyst
   OR s.clinic_id IN (SELECT clinic_id FROM SEC.ROLE_CLINICS WHERE role_name = CURRENT_ROLE());

-- Report text is full-detail only (never shown to analysts).
CREATE OR REPLACE SECURE VIEW SEC.REPORTS_V AS
SELECT r.report_id, r.patient_id, r.report_date, r.modality, r.cpt, r.facility, r.text
FROM RAW.REPORTS r JOIN RAW.PATIENTS p ON p.patient_id = r.patient_id
WHERE CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SYSADMIN', 'FFU_APP_OWNER')
   OR p.clinic_id IN (SELECT clinic_id FROM SEC.ROLE_CLINICS WHERE role_name = CURRENT_ROLE());

GRANT USAGE ON DATABASE FFU TO ROLE FFU_COORDINATOR;
GRANT USAGE ON DATABASE FFU TO ROLE FFU_ANALYST;
GRANT USAGE ON SCHEMA FFU.SEC TO ROLE FFU_COORDINATOR;
GRANT USAGE ON SCHEMA FFU.SEC TO ROLE FFU_ANALYST;
GRANT SELECT ON VIEW SEC.LOOPS_V TO ROLE FFU_COORDINATOR;
GRANT SELECT ON VIEW SEC.LOOPS_V TO ROLE FFU_ANALYST;
GRANT SELECT ON VIEW SEC.REPORTS_V TO ROLE FFU_COORDINATOR;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE FFU_COORDINATOR;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE FFU_ANALYST;
