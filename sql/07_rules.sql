-- 07 Rules engine: control date, closure codes, priority UDF, Dynamic Tables.
-- Pure SQL rules over cached AI output. Never reads the answer key.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

-- Demo clock. Dynamic Tables can't read session variables, so the date lives here.
CREATE TABLE IF NOT EXISTS CTRL.SIM_DATE (sim_date DATE);
INSERT INTO CTRL.SIM_DATE SELECT '2026-10-04' WHERE NOT EXISTS (SELECT 1 FROM CTRL.SIM_DATE);

-- Which test closes which action. The wrong test never closes a loop.
CREATE OR REPLACE TABLE CORE.CLOSURE_CODES (action STRING, cpt STRING, closes BOOLEAN, screening_only BOOLEAN, note STRING);
INSERT INTO CORE.CLOSURE_CODES VALUES
 ('CT_CHEST','71250',TRUE,FALSE,'CT chest without contrast'),
 ('CT_CHEST','71260',TRUE,FALSE,'CT chest with contrast'),
 ('CT_CHEST','71270',TRUE,FALSE,'CT chest without and with contrast'),
 ('CT_CHEST','78815',TRUE,FALSE,'PET/CT'),
 ('CT_CHEST','32405',TRUE,FALSE,'Lung biopsy'),
 ('CT_CHEST','71271',TRUE,TRUE,'Low-dose screening CT: closes only on the screening pathway'),
 ('CT_CHEST','71045',FALSE,FALSE,'Chest X-ray 1 view is the wrong test for a CT follow-up'),
 ('CT_CHEST','71046',FALSE,FALSE,'Chest X-ray 2 views is the wrong test for a CT follow-up'),
 ('AAA_ULTRASOUND','76775',TRUE,FALSE,'US aorta limited'),
 ('AAA_ULTRASOUND','76770',TRUE,FALSE,'US retroperitoneum complete'),
 ('AAA_ULTRASOUND','74177',TRUE,FALSE,'CT abdomen and pelvis with contrast'),
 ('AAA_ULTRASOUND','74178',TRUE,FALSE,'CT abdomen and pelvis without and with contrast'),
 ('AAA_ULTRASOUND','75635',TRUE,FALSE,'CTA abdominal aorta'),
 ('VASCULAR_REFERRAL','99242',TRUE,FALSE,'Consult'),('VASCULAR_REFERRAL','99243',TRUE,FALSE,'Consult'),
 ('VASCULAR_REFERRAL','99244',TRUE,FALSE,'Consult'),('VASCULAR_REFERRAL','99245',TRUE,FALSE,'Consult'),
 ('VASCULAR_REFERRAL','99203',TRUE,FALSE,'New patient visit'),('VASCULAR_REFERRAL','99204',TRUE,FALSE,'New patient visit'),
 ('VASCULAR_REFERRAL','99205',TRUE,FALSE,'New patient visit');

-- Transparent priority: returns the score and its breakdown.
CREATE OR REPLACE FUNCTION CORE.PRIORITY(tier NUMBER, elapsed FLOAT, age NUMBER, smoking STRING,
                                         sex STRING, nodule_type STRING, tb_history BOOLEAN)
RETURNS OBJECT LANGUAGE PYTHON IMMUTABLE RUNTIME_VERSION = '3.11' HANDLER = 'priority'
AS $$
def priority(tier, elapsed, age, smoking, sex, nodule_type, tb_history):
    tier_pts = {1: 300, 2: 200, 3: 100}.get(int(tier) if tier is not None else 3, 100)
    e = 0.0 if elapsed is None else max(0.0, min(float(elapsed), 2.0))
    time_pts = round(e * 50, 1)
    ctx, notes = 0, []
    if age is not None and age >= 65:
        ctx += 5; notes.append("age 65+ (+5)")
    if smoking == "CURRENT":
        ctx += 5; notes.append("current smoker (+5)")
    elif smoking == "FORMER":
        ctx += 3; notes.append("former smoker (+3)")
    if tb_history:
        notes.append("TB history shown as context only (no change)")
    if sex == "F" and smoking == "NEVER" and nodule_type in ("PART_SOLID", "GROUND_GLASS"):
        notes.append("subsolid nodule in never-smoker woman: not downgraded (Asia 2016)")
    return {"score": tier_pts + time_pts + ctx, "tier_points": tier_pts,
            "time_points": time_pts, "context_points": ctx,
            "elapsed_share": round(e, 2), "notes": notes}
$$;

-- One row per extracted finding, with the quote checked word for word against the source.
CREATE OR REPLACE DYNAMIC TABLE CORE.FINDINGS TARGET_LAG = DOWNSTREAM WAREHOUSE = COMPUTE_WH REFRESH_MODE = FULL AS
SELECT
  e.report_id || '-' || f.index AS finding_key, e.report_id, r.patient_id, r.report_date, r.modality,
  CASE WHEN r.modality = 'XR' AND f.value:finding_type::STRING IN ('LUNG_NODULE','CXR_OPACITY') THEN 'CXR_RECOMMEND_CT'
       ELSE f.value:finding_type::STRING END AS finding_type,
  NULLIF(f.value:nodule_type::STRING, 'NA') AS nodule_type,
  f.value:location::STRING AS location,
  NULLIF(f.value:long_mm::FLOAT, -1) AS long_mm,
  NULLIF(f.value:short_mm::FLOAT, -1) AS short_mm,
  ROUND((NULLIF(f.value:long_mm::FLOAT, -1) + COALESCE(NULLIF(f.value:short_mm::FLOAT, -1), NULLIF(f.value:long_mm::FLOAT, -1))) / 2) AS avg_mm,
  NULLIF(f.value:solid_mm::FLOAT, -1) AS solid_mm,
  NULLIF(f.value:aorta_cm::FLOAT, -1) AS aorta_cm,
  f.value:recommended_action::STRING AS rec_action,
  NULLIF(f.value:due_min_months::FLOAT, -1) AS stated_min_months,
  NULLIF(f.value:due_max_months::FLOAT, -1) AS stated_max_months,
  f.value:hedged::BOOLEAN AS hedged, f.value:negated::BOOLEAN AS negated,
  f.value:stable::BOOLEAN AS stable, f.value:suspicious::BOOLEAN AS suspicious,
  f.value:quote::STRING AS quote,
  CONTAINS(REGEXP_REPLACE(LOWER(r.text), '\\s+', ' '), REGEXP_REPLACE(LOWER(TRIM(f.value:quote::STRING)), '\\s+', ' ')) AS quote_verified,
  COALESCE(e.j:history:known_cancer::BOOLEAN, FALSE) AS hx_cancer,
  COALESCE(e.j:history:immunosuppressed::BOOLEAN, FALSE) AS hx_immuno,
  COALESCE(e.j:history:screening_programme::BOOLEAN, FALSE) AS hx_screening
FROM (SELECT * FROM AI.EXTRACTIONS WHERE err IS NULL QUALIFY ROW_NUMBER() OVER (PARTITION BY report_id ORDER BY extracted_at) = 1) e
JOIN RAW.REPORTS r ON r.report_id = e.report_id,
LATERAL FLATTEN(input => e.j:findings) f
WHERE e.err IS NULL;

-- Extension slot: rules added later by the guideline-rule-compiler skill (e.g. thyroid). Starts empty.
-- IF NOT EXISTS so a rebuild never wipes a compiled rule. EXTRA_RULES_EMPTY is the reset target.
CREATE OR REPLACE VIEW CORE.EXTRA_RULES_EMPTY AS
SELECT NULL::STRING loop_id, NULL::STRING finding_key, NULL::STRING report_id, NULL::STRING patient_id, NULL::STRING clinic_id,
  NULL::DATE report_date, NULL::STRING finding_type, NULL::STRING nodule_type, NULL::STRING location, NULL::FLOAT long_mm,
  NULL::FLOAT short_mm, NULL::FLOAT avg_mm, NULL::FLOAT solid_mm, NULL::FLOAT aorta_cm, NULL::BOOLEAN hedged, NULL::BOOLEAN stable,
  NULL::BOOLEAN suspicious, NULL::STRING quote, NULL::BOOLEAN quote_verified, NULL::NUMBER age, NULL::STRING sex, NULL::STRING smoking,
  NULL::BOOLEAN tb_history, NULL::NUMBER tier, NULL::STRING pathway, NULL::STRING reroute_reason, NULL::STRING guideline_action,
  NULL::STRING action, NULL::FLOAT due_min_months, NULL::FLOAT due_max_months, NULL::DATE due_start, NULL::DATE due_end, NULL::STRING qa_flag
WHERE FALSE;
-- A Dynamic Table (not a view): Dynamic Tables can't read views that wrap other Dynamic Tables.
CREATE DYNAMIC TABLE IF NOT EXISTS CORE.EXTRA_RULES TARGET_LAG = DOWNSTREAM WAREHOUSE = COMPUTE_WH REFRESH_MODE = FULL AS SELECT * FROM CORE.EXTRA_RULES_EMPTY;

-- Loops: one per finding where the radiologist recommended an action. Guideline values feed tier and QA flags.
CREATE OR REPLACE DYNAMIC TABLE CORE.LOOPS TARGET_LAG = DOWNSTREAM WAREHOUSE = COMPUTE_WH REFRESH_MODE = FULL AS
WITH g AS (
  SELECT f.*, p.age, p.sex, p.smoking, p.tb_history, p.clinic_id,
    -- Guideline action and window (months)
    CASE
      WHEN f.finding_type = 'LUNG_NODULE' AND f.avg_mm < 6 THEN 'NONE'
      WHEN f.finding_type IN ('LUNG_NODULE','CXR_RECOMMEND_CT') THEN 'CT_CHEST'
      WHEN f.finding_type = 'AAA' AND ((p.sex = 'M' AND f.aorta_cm >= 5.5) OR (p.sex = 'F' AND f.aorta_cm >= 5.0)) THEN 'VASCULAR_REFERRAL'
      WHEN f.finding_type = 'AAA' AND f.aorta_cm >= 3.0 THEN 'AAA_ULTRASOUND'
      ELSE 'NONE' END AS guideline_action,
    CASE
      WHEN f.finding_type = 'LUNG_NODULE' AND f.nodule_type = 'SOLID' AND f.avg_mm > 8 THEN 0
      WHEN f.finding_type = 'LUNG_NODULE' AND f.nodule_type = 'PART_SOLID' THEN 3
      WHEN f.finding_type = 'LUNG_NODULE' THEN 6
      WHEN f.finding_type = 'CXR_RECOMMEND_CT' THEN 0
      WHEN f.finding_type = 'AAA' AND ((p.sex = 'M' AND f.aorta_cm >= 5.5) OR (p.sex = 'F' AND f.aorta_cm >= 5.0)) THEN 0
      WHEN f.finding_type = 'AAA' AND f.aorta_cm >= 5.0 THEN 5
      WHEN f.finding_type = 'AAA' AND f.aorta_cm >= 4.0 THEN 11
      WHEN f.finding_type = 'AAA' THEN 35 END AS g_min,
    CASE
      WHEN f.finding_type = 'LUNG_NODULE' AND f.nodule_type = 'SOLID' AND f.avg_mm > 8 THEN 3
      WHEN f.finding_type = 'LUNG_NODULE' AND f.nodule_type = 'PART_SOLID' THEN 6
      WHEN f.finding_type = 'LUNG_NODULE' THEN 12
      WHEN f.finding_type = 'CXR_RECOMMEND_CT' THEN 1
      WHEN f.finding_type = 'AAA' AND ((p.sex = 'M' AND f.aorta_cm >= 5.5) OR (p.sex = 'F' AND f.aorta_cm >= 5.0)) THEN 1
      WHEN f.finding_type = 'AAA' AND f.aorta_cm >= 5.0 THEN 7
      WHEN f.finding_type = 'AAA' AND f.aorta_cm >= 4.0 THEN 13
      WHEN f.finding_type = 'AAA' THEN 37 END AS g_max,
    CASE
      WHEN f.finding_type = 'LUNG_NODULE' AND f.nodule_type = 'SOLID' AND f.avg_mm > 8 THEN 1
      WHEN f.finding_type = 'LUNG_NODULE' AND f.nodule_type = 'PART_SOLID' AND f.solid_mm >= 6 THEN 1
      WHEN f.finding_type = 'LUNG_NODULE' AND f.nodule_type IN ('SOLID','PART_SOLID') THEN 2
      WHEN f.finding_type = 'LUNG_NODULE' THEN 3
      WHEN f.finding_type = 'CXR_RECOMMEND_CT' AND f.suspicious THEN 1
      WHEN f.finding_type = 'CXR_RECOMMEND_CT' THEN 2
      WHEN f.finding_type = 'AAA' AND ((p.sex = 'M' AND f.aorta_cm >= 5.5) OR (p.sex = 'F' AND f.aorta_cm >= 5.0)) THEN 1
      WHEN f.finding_type = 'AAA' AND f.aorta_cm >= 4.0 THEN 2
      ELSE 3 END AS tier,
    CASE WHEN f.finding_type <> 'LUNG_NODULE' THEN 'STANDARD'
         WHEN p.known_cancer OR f.hx_cancer THEN 'ONCOLOGY_SURVEILLANCE'
         WHEN p.immunosuppressed OR f.hx_immuno THEN 'CLINICIAN_REVIEW'
         WHEN p.age < 35 THEN 'CLINICIAN_REVIEW'
         WHEN p.screening_enrolled OR f.hx_screening THEN 'LUNG_SCREENING'
         ELSE 'STANDARD' END AS pathway,
    CASE WHEN f.finding_type <> 'LUNG_NODULE' THEN NULL
         WHEN p.known_cancer OR f.hx_cancer THEN 'Known cancer: Fleischner does not apply'
         WHEN p.immunosuppressed OR f.hx_immuno THEN 'Immunosuppressed: Fleischner does not apply'
         WHEN p.age < 35 THEN 'Age under 35: Fleischner does not apply'
         WHEN p.screening_enrolled OR f.hx_screening THEN 'Screening programme: managed by Lung-RADS' END AS reroute_reason
  FROM CORE.FINDINGS f JOIN RAW.PATIENTS p ON p.patient_id = f.patient_id
  WHERE NOT f.negated AND f.finding_type IN ('LUNG_NODULE','CXR_RECOMMEND_CT','AAA')
)
SELECT
  'L-' || finding_key AS loop_id, finding_key, report_id, patient_id, clinic_id, report_date, finding_type, nodule_type,
  location, long_mm, short_mm, avg_mm, solid_mm, aorta_cm, hedged, stable, suspicious, quote, quote_verified,
  age, sex, smoking, tb_history, tier, pathway, reroute_reason, guideline_action,
  -- Radiologist action wins; guideline only used when the action is not stated.
  CASE WHEN rec_action IN ('PET_CT','BIOPSY') THEN 'CT_CHEST' ELSE rec_action END AS action,
  COALESCE(stated_min_months, stated_max_months, g_min) AS due_min_months,
  COALESCE(stated_max_months, stated_min_months, g_max) AS due_max_months,
  DATEADD(day, ROUND(30.4 * COALESCE(stated_min_months, stated_max_months, g_min)), report_date) AS due_start,
  DATEADD(day, ROUND(30.4 * COALESCE(stated_max_months, stated_min_months, g_max)), report_date) AS due_end,
  CASE WHEN rec_action <> guideline_action AND NOT (rec_action IN ('PET_CT','BIOPSY') AND guideline_action = 'CT_CHEST')
         THEN 'Radiologist action ' || rec_action || ' differs from guideline ' || guideline_action
       WHEN stated_max_months IS NOT NULL AND (stated_max_months > g_max OR stated_max_months < g_min)
         THEN 'Stated interval ' || stated_max_months || ' months is outside guideline ' || g_min || '-' || g_max
       END AS qa_flag
FROM g
WHERE rec_action NOT IN ('NONE','OTHER')
UNION ALL
SELECT * FROM CORE.EXTRA_RULES;

-- Evidence that something happened after the index report: hospital reports and payer claims.
CREATE OR REPLACE VIEW CORE.EVIDENCE AS
SELECT 'HOSPITAL' AS source, report_id AS evidence_id, patient_id, report_date AS event_date, cpt, facility
FROM RAW.REPORTS
UNION ALL
SELECT 'PAYER_CLAIM', event_id, patient_id, service_date, cpt, facility
FROM PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS;

-- Cached AI_FILTER checks: does the hospital follow-up report discuss the original finding?
CREATE TABLE IF NOT EXISTS AI.FOLLOWUP_CHECKS (loop_id STRING, evidence_id STRING, discusses BOOLEAN,
  checked_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
CREATE TABLE IF NOT EXISTS APP.CANCELLATIONS (loop_id STRING, reason STRING, clinician STRING, signed_at TIMESTAMP_NTZ);

-- Loop status, recomputed from raw rows against CTRL.SIM_DATE.
CREATE OR REPLACE DYNAMIC TABLE CORE.LOOP_STATUS TARGET_LAG = '1 hour' WAREHOUSE = COMPUTE_WH REFRESH_MODE = FULL AS
WITH s AS (SELECT MAX(sim_date) AS sim_date FROM CTRL.SIM_DATE),
m AS (  -- every evidence row matched to a loop with its closure meaning
  SELECT l.loop_id, ev.source, ev.evidence_id, ev.event_date, ev.cpt, ev.facility, c.closes, c.screening_only, c.note,
         fc.discusses
  FROM CORE.LOOPS l CROSS JOIN s
  JOIN CORE.EVIDENCE ev ON ev.patient_id = l.patient_id AND ev.event_date > l.report_date AND ev.event_date <= s.sim_date
  JOIN CORE.CLOSURE_CODES c ON c.action = l.action AND c.cpt = ev.cpt
  LEFT JOIN AI.FOLLOWUP_CHECKS fc ON fc.loop_id = l.loop_id AND fc.evidence_id = ev.evidence_id
  WHERE ev.evidence_id <> l.report_id
), agg AS (
  SELECT l.loop_id,
    MIN(IFF(m.source = 'HOSPITAL' AND m.closes AND (NOT m.screening_only OR l.pathway = 'LUNG_SCREENING') AND m.discusses, m.event_date, NULL)) AS green_date,
    MIN(IFF(m.source = 'PAYER_CLAIM' AND m.closes AND (NOT m.screening_only OR l.pathway = 'LUNG_SCREENING'), m.event_date, NULL)) AS amber_date,
    MAX(IFF(m.source = 'HOSPITAL' AND m.closes AND m.discusses, m.evidence_id, NULL)) AS green_evidence,
    MAX(IFF(m.source = 'PAYER_CLAIM' AND m.closes, m.evidence_id || ' (' || m.cpt || ' at ' || m.facility || ')', NULL)) AS amber_evidence,
    MAX(IFF(NOT m.closes, m.cpt || ' on ' || m.event_date || ': ' || m.note, NULL)) AS wrong_test,
    MAX(IFF(m.source = 'HOSPITAL' AND m.closes AND COALESCE(m.discusses, FALSE) = FALSE, m.evidence_id, NULL)) AS unverified_hosp
  FROM CORE.LOOPS l LEFT JOIN m ON m.loop_id = l.loop_id GROUP BY l.loop_id
)
SELECT l.*, s.sim_date, a.green_date, a.green_evidence, a.amber_date, a.amber_evidence, a.wrong_test, a.unverified_hosp,
  ak.ack_date IS NOT NULL AS clinician_acked, n.notified_date IS NOT NULL AS patient_notified,
  CASE WHEN l.pathway <> 'STANDARD' THEN 'REROUTED'
       WHEN cx.loop_id IS NOT NULL THEN 'CANCELLED'
       WHEN a.green_date IS NOT NULL THEN 'GREEN'
       WHEN a.amber_date IS NOT NULL THEN 'AMBER'
       WHEN s.sim_date > l.due_end THEN 'RED'
       ELSE 'OPEN' END AS status,
  CASE WHEN l.pathway <> 'STANDARD' THEN l.reroute_reason
       WHEN cx.loop_id IS NOT NULL THEN 'Cancelled by ' || cx.clinician || ': ' || cx.reason
       WHEN a.green_date IS NOT NULL THEN 'Verified follow-up report ' || a.green_evidence || ' discusses the finding'
       WHEN a.amber_date IS NOT NULL THEN 'Claim ' || a.amber_evidence || '; outside report requested'
       WHEN s.sim_date > l.due_end THEN 'Overdue by ' || DATEDIFF(day, l.due_end, s.sim_date) || ' days'
            || IFF(a.wrong_test IS NOT NULL, '. Does not close: ' || a.wrong_test, '')
            || IFF(a.unverified_hosp IS NOT NULL, '. Report ' || a.unverified_hosp || ' found but not confirmed to discuss the finding: needs review', '')
       ELSE 'Due ' || l.due_start || ' to ' || l.due_end END AS status_reason,
  GREATEST(DATEDIFF(day, l.due_end, s.sim_date), 0) AS days_overdue,
  DATEDIFF(day, l.report_date, s.sim_date) / NULLIF(DATEDIFF(day, l.report_date, l.due_end), 0) AS elapsed_share,
  CORE.PRIORITY(l.tier, DATEDIFF(day, l.report_date, s.sim_date) / NULLIF(DATEDIFF(day, l.report_date, l.due_end), 0),
                l.age, l.smoking, l.sex, l.nodule_type, l.tb_history) AS priority
FROM CORE.LOOPS l CROSS JOIN s
JOIN agg a ON a.loop_id = l.loop_id
LEFT JOIN RAW.ACKS ak ON ak.report_id = l.report_id
LEFT JOIN RAW.NOTIFICATIONS n ON n.report_id = l.report_id
LEFT JOIN (SELECT DISTINCT loop_id, reason, clinician FROM APP.CANCELLATIONS WHERE clinician IS NOT NULL AND reason IS NOT NULL) cx
  ON cx.loop_id = l.loop_id;

-- Ranked worklist: red and amber only, most dangerous first, then most overdue.
CREATE OR REPLACE VIEW CORE.WORKLIST AS
SELECT ROW_NUMBER() OVER (ORDER BY tier, priority:score::FLOAT DESC, days_overdue DESC) AS rank, *
FROM CORE.LOOP_STATUS WHERE status IN ('RED','AMBER');

-- Surveillance continues: a closed surveillance loop opens the next check-up.
CREATE OR REPLACE VIEW CORE.NEXT_CHECKS AS
SELECT loop_id AS previous_loop_id, patient_id, finding_type, action, green_date AS closed_on,
  DATEADD(day, ROUND(30.4 * due_max_months), green_date) AS next_due,
  'Next surveillance check after verified follow-up' AS reason
FROM CORE.LOOP_STATUS
WHERE status = 'GREEN' AND (action = 'AAA_ULTRASOUND' OR finding_type = 'LUNG_NODULE');



