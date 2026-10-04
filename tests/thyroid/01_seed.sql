-- Thyroid extension tests (written BEFORE the rule exists). Seeds 6 synthetic CT reports and the expected outcome.
-- ACR 2015 incidental thyroid white paper (paraphrased): ultrasound if 1.5 cm or more (age 35+), 1.0 cm or more under 35,
-- or any size with suspicious features (local invasion, abnormal lymph nodes). Otherwise no follow-up.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

INSERT INTO RAW.PATIENTS (patient_id, age, sex, smoking, known_cancer, immunosuppressed, screening_enrolled, tb_history, clinic_id)
SELECT * FROM VALUES
 ('PT0001', 50, 'F', 'NEVER', FALSE, FALSE, FALSE, FALSE, 'C2'), ('PT0002', 50, 'M', 'NEVER', FALSE, FALSE, FALSE, FALSE, 'C2'),
 ('PT0003', 30, 'F', 'NEVER', FALSE, FALSE, FALSE, FALSE, 'C2'), ('PT0004', 60, 'M', 'FORMER', FALSE, FALSE, FALSE, FALSE, 'C2'),
 ('PT0005', 45, 'F', 'NEVER', FALSE, FALSE, FALSE, FALSE, 'C2'), ('PT0006', 70, 'F', 'NEVER', FALSE, FALSE, FALSE, FALSE, 'C2') v
WHERE v.$1 NOT IN (SELECT patient_id FROM RAW.PATIENTS);

INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, set_name, gen_model)
SELECT v.$1, v.$2, '2026-08-01'::DATE, 'CT_CHEST', '71260', 'HOSPITAL',
  'CLINICAL HISTORY\nCough.\n\nFINDINGS\nLungs are clear. ' || v.$3 || '\n\nIMPRESSION\n' || v.$4, 'THY_TEST', 'human'
FROM VALUES
 ('RTHY001','PT0001','There is an 18 x 14 mm hypodense nodule in the right thyroid lobe.','18 mm right thyroid nodule. Thyroid ultrasound is recommended.'),
 ('RTHY002','PT0002','There is a 12 x 10 mm hypodense nodule in the left thyroid lobe.','12 mm left thyroid nodule.'),
 ('RTHY003','PT0003','There is a 12 x 9 mm hypodense nodule in the left thyroid lobe.','12 mm left thyroid nodule in a patient under 35. Thyroid ultrasound is recommended.'),
 ('RTHY004','PT0004','There is an 8 x 7 mm thyroid nodule with an adjacent enlarged abnormal level IV lymph node.','8 mm thyroid nodule with an abnormal lymph node, suspicious. Thyroid ultrasound is recommended.'),
 ('RTHY005','PT0005','No thyroid nodule is seen. The thyroid gland is normal.','Normal thyroid.'),
 ('RTHY006','PT0006','There is a 15 x 12 mm nodule in the thyroid isthmus.','15 mm thyroid isthmus nodule. Thyroid ultrasound is recommended.') v
WHERE v.$1 NOT IN (SELECT report_id FROM RAW.REPORTS);

CREATE OR REPLACE TABLE EVAL.THYROID_EXPECTED (report_id STRING, expect_loop BOOLEAN, expect_tier NUMBER, why STRING);
INSERT INTO EVAL.THYROID_EXPECTED VALUES
 ('RTHY001', TRUE, 2, '18 mm, age 50: 1.5 cm or more -> ultrasound'),
 ('RTHY002', FALSE, NULL, '12 mm, age 50: under 1.5 cm -> no follow-up'),
 ('RTHY003', TRUE, 2, '12 mm, age 30: under 35 and 1.0 cm or more -> ultrasound'),
 ('RTHY004', TRUE, 1, '8 mm with abnormal node: suspicious -> ultrasound, tier 1'),
 ('RTHY005', FALSE, NULL, 'negated: no nodule'),
 ('RTHY006', TRUE, 2, '15 mm, age 70: exactly 1.5 cm -> ultrasound (boundary)');
