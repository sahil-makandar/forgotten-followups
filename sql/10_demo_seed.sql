-- 10 Demo inputs. Two fixed demo patients plus one seeded decoy report that demo-reset keeps.
--   P09901: the hero. New 9 mm solid RUL nodule arrives during the demo (demo/inbox/RDEMO001_ct_chest.txt).
--   P09902: the decoy. Earlier 9 mm nodule; during the demo a chest X-ray claim arrives and must NOT close it.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

-- Landing procedure used by the followup-intake skill and the app. The Stream + Task pick up the row.
-- Refuses (with a clear message, nothing inserted) a missing id, an unknown patient, an empty report or a duplicate id,
-- so a bad file never disappears silently later in the pipeline.
CREATE OR REPLACE PROCEDURE CORE.INGEST_REPORT(REPORT_ID STRING, PATIENT_ID STRING, REPORT_DATE DATE,
  MODALITY STRING, CPT STRING, FACILITY STRING, TEXT STRING)
RETURNS STRING LANGUAGE SQL AS
$$
BEGIN
  IF (NULLIF(TRIM(:REPORT_ID), '') IS NULL) THEN RETURN 'not ingested: missing report id'; END IF;
  IF (NOT EXISTS (SELECT 1 FROM RAW.PATIENTS WHERE patient_id = :PATIENT_ID)) THEN
    RETURN 'not ingested ' || :REPORT_ID || ': unknown patient ' || COALESCE(:PATIENT_ID, '(none)');
  END IF;
  IF (LENGTH(REGEXP_REPLACE(COALESCE(:TEXT, ''), '\\s', '')) < 20) THEN
    RETURN 'not ingested ' || :REPORT_ID || ': report text is empty or too short to read';
  END IF;
  IF (EXISTS (SELECT 1 FROM RAW.REPORTS WHERE report_id = :REPORT_ID)) THEN
    RETURN 'skipped ' || :REPORT_ID || ': already ingested';
  END IF;
  INSERT INTO RAW.REPORTS (report_id, patient_id, report_date, modality, cpt, facility, text, set_name, gen_model)
  SELECT :REPORT_ID, :PATIENT_ID, :REPORT_DATE, :MODALITY, :CPT, :FACILITY, :TEXT, 'DEMO', 'human';
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
