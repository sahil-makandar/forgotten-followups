-- FALLBACK ONLY: reference thyroid rule, used if the live guideline-rule-compiler generation fails during the demo.
-- The live demo generates sql/rules/thyroid.sql from the guideline text; this file is not loaded by the rebuild.
-- ACR 2015 incidental thyroid white paper (paraphrased): ultrasound if 1.5 cm or more (age 35+), 1.0 cm or more under 35,
-- or any size with suspicious features. https://www.acr.org/Clinical-Resources/Clinical-Tools-and-Reference/Incidental-Findings
CREATE OR REPLACE DYNAMIC TABLE FFU.CORE.EXTRA_RULES TARGET_LAG = DOWNSTREAM WAREHOUSE = COMPUTE_WH REFRESH_MODE = FULL AS
SELECT * FROM FFU.CORE.EXTRA_RULES_EMPTY
UNION ALL
SELECT 'L-' || f.finding_key, f.finding_key, f.report_id, f.patient_id, p.clinic_id, f.report_date, f.finding_type, f.nodule_type,
  f.location, f.long_mm, f.short_mm, f.avg_mm, f.solid_mm, f.aorta_cm, f.hedged, f.stable, f.suspicious, f.quote, f.quote_verified,
  p.age, p.sex, p.smoking, p.tb_history,
  IFF(f.suspicious, 1, 2) AS tier, 'STANDARD', NULL, 'THYROID_ULTRASOUND', 'THYROID_ULTRASOUND',
  0, 3, f.report_date, DATEADD(day, ROUND(30.4 * 3), f.report_date), NULL
FROM FFU.CORE.FINDINGS f JOIN FFU.RAW.PATIENTS p ON p.patient_id = f.patient_id
WHERE f.finding_type = 'THYROID_NODULE' AND NOT f.negated
  AND (f.suspicious OR f.long_mm >= 15 OR (p.age < 35 AND f.long_mm >= 10));

INSERT INTO FFU.CORE.CLOSURE_CODES
SELECT * FROM VALUES ('THYROID_ULTRASOUND','76536',TRUE,FALSE,'US soft tissues of head and neck (thyroid)'),
                     ('THYROID_ULTRASOUND','70491',FALSE,FALSE,'CT neck is not the recommended test for a thyroid nodule') v
WHERE NOT EXISTS (SELECT 1 FROM FFU.CORE.CLOSURE_CODES WHERE action = 'THYROID_ULTRASOUND');

