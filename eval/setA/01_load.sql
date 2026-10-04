-- Set A load: 120 real Indiana University chest X-ray reports (Open-i, CC BY-NC-ND 4.0).
-- The text is NEVER committed: data/openi/ is git-ignored. Only report uids (eval/setA/setA_uids.txt), our labels and metrics are committed.
-- Run from the repo root: snow sql -c hospital -f eval/setA/01_load.sql
-- Open-i has no demographics: patients default to age 60, male, former smoker (a stated limitation for routing checks).
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CREATE STAGE IF NOT EXISTS EVAL.SETA_STAGE;
CREATE FILE FORMAT IF NOT EXISTS EVAL.CSV_QUOTED TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' ENCODING = 'UTF8';
PUT file://data/openi/setA_120.csv @EVAL.SETA_STAGE OVERWRITE = TRUE AUTO_COMPRESS = TRUE;

CREATE OR REPLACE TABLE EVAL.SETA_RAW (uid STRING, indication STRING, findings STRING, impression STRING);
COPY INTO EVAL.SETA_RAW FROM @EVAL.SETA_STAGE/setA_120.csv.gz FILE_FORMAT = (FORMAT_NAME = 'EVAL.CSV_QUOTED');

INSERT INTO RAW.PATIENTS (patient_id, age, sex, smoking, known_cancer, immunosuppressed, screening_enrolled, tb_history, clinic_id)
SELECT 'PA' || uid, 60, 'M', 'FORMER', FALSE, FALSE, FALSE, FALSE, 'EVAL' FROM EVAL.SETA_RAW
WHERE 'PA' || uid NOT IN (SELECT patient_id FROM RAW.PATIENTS);

INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, set_name, gen_model)
SELECT 'RA' || uid, 'PA' || uid, '2026-03-01', 'XR', '71046', 'HOSPITAL',
  'INDICATION' || CHR(10) || COALESCE(indication, '') || CHR(10) || CHR(10) || 'FINDINGS' || CHR(10) || COALESCE(findings, '')
    || CHR(10) || CHR(10) || 'IMPRESSION' || CHR(10) || COALESCE(impression, ''),
  'A', 'real (Open-i)'
FROM EVAL.SETA_RAW WHERE 'RA' || uid NOT IN (SELECT report_id FROM RAW.REPORTS);

SELECT COUNT(*) AS set_a_reports FROM RAW.REPORTS WHERE set_name = 'A';
