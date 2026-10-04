-- 02 Synthetic patients and the hidden answer key (Set C).
-- All randomness is HASH-based, so the script is deterministic and re-runnable.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CREATE OR REPLACE TABLE RAW.PATIENTS AS
WITH g AS (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 2000)))
SELECT
  'P' || LPAD(i, 5, '0')                       AS patient_id,
  30 + ABS(HASH(i, 'age')) % 60                AS age,
  IFF(ABS(HASH(i, 'sex')) % 2 = 0, 'M', 'F')   AS sex,
  CASE WHEN ABS(HASH(i, 'smk')) % 100 < 25 THEN 'CURRENT'
       WHEN ABS(HASH(i, 'smk')) % 100 < 50 THEN 'FORMER' ELSE 'NEVER' END AS smoking,
  ABS(HASH(i, 'ca'))  % 100 < 5                AS known_cancer,
  ABS(HASH(i, 'imm')) % 100 < 3                AS immunosuppressed,
  ABS(HASH(i, 'scr')) % 100 < 5                AS screening_enrolled,
  ABS(HASH(i, 'tb'))  % 100 < 4                AS tb_history,
  'C' || (1 + ABS(HASH(i, 'cl')) % 4)          AS clinic_id
FROM g;

-- One index report per patient for the first 700 patients.
CREATE OR REPLACE TABLE KEY.ANSWER_KEY AS
WITH b AS (
  SELECT p.*, TO_NUMBER(SUBSTR(patient_id, 2)) AS i
  FROM RAW.PATIENTS p WHERE TO_NUMBER(SUBSTR(patient_id, 2)) <= 700
), r AS (
  SELECT b.*,
    ABS(HASH(i, 'ft')) % 100 AS hft,
    ABS(HASH(i, 'oc')) % 100 AS hoc,
    DATEADD(day, ABS(HASH(i, 'dt')) % 365, '2025-10-01'::DATE) AS report_date,
    4 + ABS(HASH(i, 'ln')) % 17 AS long_mm,
    ABS(HASH(i, 'sd')) % 4      AS short_delta,
    ABS(HASH(i, 'nt')) % 100    AS hnt,
    2 + ABS(HASH(i, 'sm')) % 9  AS solid_raw,
    ARRAY_CONSTRUCT('right upper lobe','right middle lobe','right lower lobe',
                    'left upper lobe','left lower lobe')[ABS(HASH(i, 'lb')) % 5]::STRING AS lobe,
    (30 + ABS(HASH(i, 'aaa')) % 31) / 10 AS aaa_cm,
    ABS(HASH(i, 'hg'))  % 100 < 15 AS hedged,
    ABS(HASH(i, 'sus')) % 100 < 40 AS suspicious,
    ABS(HASH(i, 'nf'))  % 100 < 70 AS patient_notified,
    ABS(HASH(i, 'ak'))  % 100 < 85 AS clinician_acked,
    ABS(HASH(i, 'dd'))  % 20       AS done_offset
  FROM b
), f AS (
  SELECT r.*,
    CASE WHEN hft < 60 THEN 'LUNG_NODULE' WHEN hft < 75 THEN 'CXR_RECOMMEND_CT'
         WHEN hft < 90 THEN 'AAA' ELSE 'NONE' END AS finding_type,
    GREATEST(long_mm - short_delta, 3) AS short_mm,
    CASE WHEN hnt < 75 THEN 'SOLID' WHEN hnt < 90 THEN 'PART_SOLID' ELSE 'GROUND_GLASS' END AS nodule_type
  FROM r
), s AS (
  SELECT f.*,
    ROUND((long_mm + short_mm) / 2) AS avg_mm,
    IFF(nodule_type = 'PART_SOLID', LEAST(solid_raw, short_mm - 1), NULL) AS solid_mm
  FROM f
), d AS (
  SELECT s.*,
    -- Rule outputs from docs/RULE_SHEET.md: action, window (months), tier
    CASE
      WHEN finding_type = 'LUNG_NODULE' AND avg_mm < 6 THEN 'NONE_REQUIRED'
      WHEN finding_type IN ('LUNG_NODULE','CXR_RECOMMEND_CT') THEN 'CT_CHEST'
      WHEN finding_type = 'AAA' AND ((sex = 'M' AND aaa_cm >= 5.5) OR (sex = 'F' AND aaa_cm >= 5.0)) THEN 'VASCULAR_REFERRAL'
      WHEN finding_type = 'AAA' THEN 'AAA_ULTRASOUND'
      ELSE 'NONE_REQUIRED' END AS expected_action,
    CASE
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type = 'SOLID' AND avg_mm > 8 THEN 0
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type = 'SOLID' THEN 6
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type = 'PART_SOLID' THEN 3
      WHEN finding_type = 'LUNG_NODULE' THEN 6
      WHEN finding_type = 'CXR_RECOMMEND_CT' THEN 0
      WHEN finding_type = 'AAA' AND ((sex = 'M' AND aaa_cm >= 5.5) OR (sex = 'F' AND aaa_cm >= 5.0)) THEN 0
      WHEN finding_type = 'AAA' AND aaa_cm >= 5.0 THEN 5
      WHEN finding_type = 'AAA' AND aaa_cm >= 4.0 THEN 11
      WHEN finding_type = 'AAA' THEN 35 END AS due_min_months,
    CASE
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type = 'SOLID' AND avg_mm > 8 THEN 3
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type = 'SOLID' THEN 12
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type = 'PART_SOLID' THEN 6
      WHEN finding_type = 'LUNG_NODULE' THEN 12
      WHEN finding_type = 'CXR_RECOMMEND_CT' THEN 1
      WHEN finding_type = 'AAA' AND ((sex = 'M' AND aaa_cm >= 5.5) OR (sex = 'F' AND aaa_cm >= 5.0)) THEN 1
      WHEN finding_type = 'AAA' AND aaa_cm >= 5.0 THEN 7
      WHEN finding_type = 'AAA' AND aaa_cm >= 4.0 THEN 13
      WHEN finding_type = 'AAA' THEN 37 END AS due_max_months,
    CASE
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type = 'SOLID' AND avg_mm > 8 THEN 1
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type = 'PART_SOLID' AND solid_mm >= 6 THEN 1
      WHEN finding_type = 'LUNG_NODULE' AND nodule_type IN ('SOLID','PART_SOLID') THEN 2
      WHEN finding_type = 'LUNG_NODULE' THEN 3
      WHEN finding_type = 'CXR_RECOMMEND_CT' AND suspicious THEN 1
      WHEN finding_type = 'CXR_RECOMMEND_CT' THEN 2
      WHEN finding_type = 'AAA' AND ((sex = 'M' AND aaa_cm >= 5.5) OR (sex = 'F' AND aaa_cm >= 5.0)) THEN 1
      WHEN finding_type = 'AAA' AND aaa_cm >= 4.0 THEN 2
      WHEN finding_type = 'AAA' THEN 3 END AS tier,
    CASE WHEN finding_type <> 'LUNG_NODULE' THEN 'STANDARD'
         WHEN known_cancer THEN 'ONCOLOGY_SURVEILLANCE'
         WHEN immunosuppressed THEN 'CLINICIAN_REVIEW'
         WHEN age < 35 THEN 'CLINICIAN_REVIEW'
         WHEN screening_enrolled THEN 'LUNG_SCREENING'
         ELSE 'STANDARD' END AS expected_pathway
  FROM s
), o AS (
  SELECT d.*,
    GREATEST(DATEADD(day, -done_offset, DATEADD(month, due_max_months, report_date)),
             DATEADD(day, 14, report_date)) AS planned_done_date,
    CASE WHEN expected_action = 'NONE_REQUIRED' THEN 'NONE'
         WHEN hoc < 37 THEN 'HOSP_DONE'
         WHEN hoc < 52 THEN 'OUTSIDE_CLAIM'
         WHEN hoc < 57 AND expected_action = 'CT_CHEST' THEN 'DECOY_CXR'
         ELSE 'NONE' END AS planned_outcome
  FROM d
)
SELECT
  'F' || LPAD(i, 5, '0') AS finding_id, 'R' || LPAD(i, 5, '0') AS report_id,
  patient_id, report_date, finding_type,
  IFF(finding_type = 'LUNG_NODULE', nodule_type, NULL) AS nodule_type,
  IFF(finding_type = 'LUNG_NODULE', long_mm, NULL)     AS long_mm,
  IFF(finding_type = 'LUNG_NODULE', short_mm, NULL)    AS short_mm,
  IFF(finding_type = 'LUNG_NODULE', avg_mm, NULL)      AS avg_mm,
  IFF(finding_type = 'LUNG_NODULE', solid_mm, NULL)    AS solid_mm,
  IFF(finding_type IN ('LUNG_NODULE','CXR_RECOMMEND_CT'), lobe, NULL) AS location,
  IFF(finding_type = 'AAA', aaa_cm, NULL)              AS aaa_cm,
  IFF(finding_type = 'CXR_RECOMMEND_CT', suspicious, FALSE) AS suspicious,
  hedged AND expected_action <> 'NONE_REQUIRED'        AS hedged,
  expected_action, due_min_months, due_max_months, tier, expected_pathway,
  patient_notified, clinician_acked,
  -- Only events that have already happened by the demo start date are materialised.
  IFF(planned_done_date <= '2026-10-04'::DATE, planned_outcome, 'NONE') AS outcome,
  IFF(planned_done_date <= '2026-10-04'::DATE AND planned_outcome <> 'NONE', planned_done_date, NULL) AS outcome_date
FROM o;
