-- 03 Generate report text from the hidden answer key with AI_COMPLETE.
-- Index reports (one per finding) plus follow-up reports for loops done in-hospital.
-- Output is cached in RAW.REPORTS; re-running only fills reports that are missing.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CREATE TABLE IF NOT EXISTS RAW.REPORTS (
  report_id STRING PRIMARY KEY, patient_id STRING, report_date DATE,
  modality STRING, cpt STRING, facility STRING, text STRING,
  is_addendum BOOLEAN DEFAULT FALSE, parent_report_id STRING,
  set_name STRING, gen_model STRING, loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, set_name, gen_model)
SELECT k.report_id, k.patient_id, k.report_date,
  IFF(k.finding_type = 'CXR_RECOMMEND_CT', 'XR', IFF(k.finding_type = 'AAA', 'CT_ABD', 'CT_CHEST')),
  IFF(k.finding_type = 'CXR_RECOMMEND_CT', '71046', IFF(k.finding_type = 'AAA', '74177', '71260')),
  'HOSPITAL',
  AI_COMPLETE('claude-haiku-4-5',
    'Write a realistic, concise radiology report (120-200 words) with sections CLINICAL HISTORY, TECHNIQUE, FINDINGS, IMPRESSION. '
    || 'Use only these facts and do not add other actionable findings. Output the report text only, no markdown. '
    || 'Patient: ' || p.age || ' year old ' || IFF(p.sex = 'M', 'male', 'female') || ', smoking status ' || LOWER(p.smoking)
    || IFF(p.known_cancer, ', history of colorectal cancer under treatment', '')
    || IFF(p.immunosuppressed, ', on immunosuppression after renal transplant', '')
    || IFF(p.screening_enrolled, ', enrolled in the lung cancer screening programme', '')
    || IFF(p.tb_history, ', remote history of treated tuberculosis', '') || '. '
    || CASE k.finding_type
         WHEN 'LUNG_NODULE' THEN 'Exam: CT chest with contrast. Finding: ' || LOWER(REPLACE(k.nodule_type, '_', '-'))
              || ' pulmonary nodule in the ' || k.location || ' measuring ' || k.long_mm || ' x ' || k.short_mm || ' mm'
              || IFF(k.solid_mm IS NOT NULL, ' with a solid component of ' || k.solid_mm || ' mm', '') || '. '
              || IFF(k.expected_action = 'NONE_REQUIRED', 'Recommendation: no routine follow-up needed.',
                     'Recommendation: follow-up CT chest in ' || IFF(k.due_min_months = 0, k.due_max_months, k.due_min_months)
                     || IFF(k.due_min_months = 0, ' months', '-' || k.due_max_months || ' months')
                     || IFF(k.hedged, ', if clinically indicated', '') || '.')
         WHEN 'CXR_RECOMMEND_CT' THEN 'Exam: chest X-ray PA and lateral. Finding: ' || IFF(k.suspicious, 'suspicious mass-like opacity', 'indeterminate opacity')
              || ' in the ' || k.location || '. Recommendation: CT chest for further evaluation'
              || IFF(k.hedged, ', if clinically indicated', '') || '.'
         WHEN 'AAA' THEN 'Exam: CT abdomen and pelvis. Finding: infrarenal abdominal aortic aneurysm, maximal diameter ' || k.aaa_cm || ' cm. '
              || IFF(k.expected_action = 'VASCULAR_REFERRAL', 'Recommendation: urgent vascular surgery referral.',
                     'Recommendation: surveillance ultrasound in ' || (k.due_max_months - 1) || ' months'
                     || IFF(k.hedged, ', if clinically indicated', '') || '.')
         ELSE 'Exam: CT chest with contrast. Finding: no pulmonary nodules, no mass, no acute abnormality. Impression: normal study.'
       END),
  'C', 'claude-haiku-4-5'
FROM KEY.ANSWER_KEY k JOIN RAW.PATIENTS p USING (patient_id)
WHERE k.report_id NOT IN (SELECT report_id FROM RAW.REPORTS);

-- Follow-up reports for loops closed inside the hospital.
INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, parent_report_id, set_name, gen_model)
SELECT 'FU' || SUBSTR(k.report_id, 2), k.patient_id, k.outcome_date,
  IFF(k.expected_action = 'AAA_ULTRASOUND', 'US', IFF(k.expected_action = 'VASCULAR_REFERRAL', 'NOTE', 'CT_CHEST')),
  IFF(k.expected_action = 'AAA_ULTRASOUND', '76775', IFF(k.expected_action = 'VASCULAR_REFERRAL', '99244', '71250')),
  'HOSPITAL',
  AI_COMPLETE('claude-haiku-4-5',
    'Write a concise (80-140 words) follow-up ' || IFF(k.expected_action = 'VASCULAR_REFERRAL', 'vascular surgery clinic note', 'radiology report')
    || ' that explicitly compares with the prior study dated ' || k.report_date || ' and states the result. Output text only, no markdown. Facts: '
    || CASE WHEN k.finding_type = 'AAA' THEN 'abdominal aortic aneurysm previously ' || k.aaa_cm || ' cm, now ' || (k.aaa_cm + 0.1) || ' cm.'
            ELSE 'the previously reported ' || COALESCE(k.location, 'lung') || ' finding is stable / unchanged, no new nodules.' END),
  k.report_id, 'C', 'claude-haiku-4-5'
FROM KEY.ANSWER_KEY k
WHERE k.outcome = 'HOSP_DONE' AND ('FU' || SUBSTR(k.report_id, 2)) NOT IN (SELECT report_id FROM RAW.REPORTS);
