-- Set B generation: report text from the labels (written first), by a DIFFERENT model than extraction.
-- Patients go in clinic 'EVAL' so they never appear on the demo worklist, alerts or outside-report requests.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

INSERT INTO RAW.PATIENTS (patient_id, age, sex, smoking, known_cancer, immunosuppressed, screening_enrolled, tb_history, clinic_id)
SELECT 'PB' || SUBSTR(case_id, 2),
  COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR(o, 'age=(\\d+)', 1, 1, 'e')), 60),
  COALESCE(REGEXP_SUBSTR(o, 'sex=(\\w)', 1, 1, 'e'), 'M'),
  COALESCE(REGEXP_SUBSTR(o, 'smoking=(\\w+)', 1, 1, 'e'), 'FORMER'),
  CONTAINS(o, 'known_cancer=TRUE'), CONTAINS(o, 'immunosuppressed=TRUE'), CONTAINS(o, 'screening_enrolled=TRUE'),
  CONTAINS(o, 'tb_history=TRUE'), 'EVAL'
FROM (SELECT DISTINCT case_id, COALESCE(patient_overrides, '') o FROM EVAL.SETB_LABELS)
WHERE 'PB' || SUBSTR(case_id, 2) NOT IN (SELECT patient_id FROM RAW.PATIENTS);

-- Index reports (one per case), written by claude-sonnet-4-5 from the case facts.
INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, set_name, gen_model)
SELECT 'RB' || SUBSTR(case_id, 2), 'PB' || SUBSTR(case_id, 2), '2026-03-01', modality,
  CASE modality WHEN 'XR' THEN '71046' WHEN 'CT_ABD' THEN '74177' ELSE '71260' END, 'HOSPITAL',
  AI_COMPLETE('claude-sonnet-4-5',
    'Write a realistic radiology report (100-180 words) with sections CLINICAL HISTORY, TECHNIQUE, FINDINGS, IMPRESSION. '
    || 'Use exactly these facts, keep every measurement and recommendation word for word in meaning, and add no other actionable findings. '
    || 'If the facts mention an ADDENDUM, end the report with a separate ADDENDUM section. Output the report text only, no markdown. '
    || 'Patient: ' || p.age || ' year old ' || IFF(p.sex = 'M', 'male', 'female') || ', ' || LOWER(p.smoking) || ' smoker. Facts: ' || l.facts),
  'B', 'claude-sonnet-4-5'
FROM EVAL.SETB_LABELS l JOIN RAW.PATIENTS p ON p.patient_id = 'PB' || SUBSTR(l.case_id, 2)
WHERE l.finding_no = 1 AND 'RB' || SUBSTR(l.case_id, 2) NOT IN (SELECT report_id FROM RAW.REPORTS);

-- Hospital follow-up reports for REPORT_DISCUSSES / REPORT_UNRELATED cases.
INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, set_name, gen_model)
SELECT 'FB' || SUBSTR(case_id, 2), 'PB' || SUBSTR(case_id, 2), TO_DATE(SPLIT_PART(evidence, ':', 2)), 'CT_CHEST', '71250', 'HOSPITAL',
  AI_COMPLETE('claude-sonnet-4-5',
    IFF(STARTSWITH(evidence, 'REPORT_DISCUSSES'),
      'Write a concise follow-up CT chest report (80-120 words) comparing with the CT of 2026-03-01 and stating that the previously reported nodule is stable in size. Facts of the prior: ' || facts,
      'Write a concise CT chest report (80-120 words) for a patient after a car accident, describing rib fractures and a small pneumothorax only. Do not mention any lung nodule or prior study.')
    || ' Output the report text only, no markdown.'),
  'B', 'claude-sonnet-4-5'
FROM EVAL.SETB_LABELS
WHERE finding_no = 1 AND STARTSWITH(evidence, 'REPORT_') AND 'FB' || SUBSTR(case_id, 2) NOT IN (SELECT report_id FROM RAW.REPORTS);

-- Payer claims for CLAIM:<cpt>:<date> cases are generated as SQL for the payer account (eval/setB/03_payer_claims.sql).
SELECT 'INSERT INTO PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS (event_id, patient_id, service_date, cpt, cpt_desc, facility, partner_account) SELECT * FROM VALUES '
  || LISTAGG('(''EB' || SUBSTR(case_id, 2) || ''', ''PB' || SUBSTR(case_id, 2) || ''', ''' || SPLIT_PART(evidence, ':', 3) || '''::DATE, '''
             || SPLIT_PART(evidence, ':', 2) || ''', ''Set B claim'', ''Lakeside Medical Centre'', ''AZ66410'')', ', ')
  || ' v WHERE v.$1 NOT IN (SELECT event_id FROM PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS);' AS payer_sql
FROM EVAL.SETB_LABELS WHERE finding_no = 1 AND STARTSWITH(evidence, 'CLAIM:');
