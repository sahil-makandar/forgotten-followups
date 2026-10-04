-- 10 Demo inputs. Two fixed demo patients plus one seeded decoy report that demo-reset keeps.
--   P09901: the hero. New 9 mm solid RUL nodule arrives during the demo (demo/inbox/RDEMO001_ct_chest.txt).
--   P09902: the decoy. Earlier 9 mm nodule; during the demo a chest X-ray claim arrives and must NOT close it.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

-- Landing procedure used by the followup-intake skill and the app. The Stream + Task pick up the row.
CREATE OR REPLACE PROCEDURE CORE.INGEST_REPORT(REPORT_ID STRING, PATIENT_ID STRING, REPORT_DATE DATE,
  MODALITY STRING, CPT STRING, FACILITY STRING, TEXT STRING)
RETURNS STRING LANGUAGE SQL AS
$$
BEGIN
  INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, set_name, gen_model)
  SELECT :REPORT_ID, :PATIENT_ID, :REPORT_DATE, :MODALITY, :CPT, :FACILITY, :TEXT, 'DEMO', 'human'
  WHERE NOT EXISTS (SELECT 1 FROM RAW.REPORTS WHERE report_id = :REPORT_ID);
  RETURN 'ingested ' || :REPORT_ID;
END;
$$;

INSERT INTO RAW.PATIENTS (patient_id, age, sex, smoking, known_cancer, immunosuppressed, screening_enrolled, tb_history, clinic_id)
SELECT * FROM VALUES ('P09901', 62, 'F', 'FORMER', FALSE, FALSE, FALSE, FALSE, 'C1'),
                     ('P09902', 58, 'M', 'CURRENT', FALSE, FALSE, FALSE, FALSE, 'C1') v
WHERE v.$1 NOT IN (SELECT patient_id FROM RAW.PATIENTS);

INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, set_name, gen_model)
SELECT 'RSEED902', 'P09902', '2026-05-04', 'CT_CHEST', '71260', 'HOSPITAL',
'CLINICAL HISTORY
58-year-old male, current smoker, with cough.

TECHNIQUE
CT chest with intravenous contrast.

FINDINGS
There is a 10 x 8 mm solid pulmonary nodule in the left upper lobe. No lymphadenopathy. No pleural effusion.

IMPRESSION
10 x 8 mm solid left upper lobe nodule. Follow-up CT chest is recommended in 3 months.', 'DEMO_SEED', 'human'
WHERE NOT EXISTS (SELECT 1 FROM RAW.REPORTS WHERE report_id = 'RSEED902');
