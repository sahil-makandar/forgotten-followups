-- Red-team intake cases. Lands odd reports for a throwaway patient (P0RT01, clinic EVAL so it never reaches the
-- worklist or alerts), runs the normal pipeline, prints what happened per case, then deletes everything it created.
-- Run: snow sql -c hospital -f tests/red_team_intake.sql   (about 10 AI calls)
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

INSERT INTO RAW.PATIENTS (patient_id, age, sex, smoking, known_cancer, immunosuppressed, screening_enrolled, tb_history, clinic_id)
SELECT 'P0RT01', 60, 'M', 'FORMER', FALSE, FALSE, FALSE, FALSE, 'EVAL'
WHERE NOT EXISTS (SELECT 1 FROM RAW.PATIENTS WHERE patient_id = 'P0RT01');

-- I1 empty report
CALL CORE.INGEST_REPORT('RRT01', 'P0RT01', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL', '');
-- I2 report in Spanish (8 mm solid nodule, CT in 6 to 12 months)
CALL CORE.INGEST_REPORT('RRT02', 'P0RT01', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL',
  'TC DE TORAX. HALLAZGOS: Nodulo pulmonar solido de 8 x 8 mm en el lobulo superior derecho. IMPRESION: Nodulo solido de 8 mm. Se recomienda TC de control en 6 a 12 meses.');
-- I3 two addenda: the second says the "nodule" is a vessel, so no follow-up
CALL CORE.INGEST_REPORT('RRT03', 'P0RT01', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL',
  'FINDINGS: 7 x 6 mm solid nodule in the left lower lobe. IMPRESSION: 7 mm nodule. Follow-up CT chest in 6 to 12 months.
ADDENDUM 1: On review the nodule measures 9 x 8 mm. Follow-up CT chest in 3 months.
ADDENDUM 2: On further review with the thin-section images, the left lower lobe opacity is a vessel seen end-on, not a nodule. No follow-up imaging is needed.');
-- I4 0 mm nodule
CALL CORE.INGEST_REPORT('RRT04', 'P0RT01', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL',
  'FINDINGS: 0 mm solid nodule in the right upper lobe. IMPRESSION: 0 mm nodule. Follow-up CT chest in 12 months.');
-- I5 999 mm nodule (impossible size)
CALL CORE.INGEST_REPORT('RRT05', 'P0RT01', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL',
  'FINDINGS: 999 x 999 mm solid nodule in the right upper lobe. IMPRESSION: 999 mm nodule. Follow-up CT chest in 3 months.');
-- I6 duplicate report id (second call must not add a row)
CALL CORE.INGEST_REPORT('RRT06', 'P0RT01', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL',
  'FINDINGS: 6 x 6 mm solid nodule in the right middle lobe. IMPRESSION: 6 mm nodule. Follow-up CT chest in 6 to 12 months.');
CALL CORE.INGEST_REPORT('RRT06', 'P0RT01', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL',
  'FINDINGS: 6 x 6 mm solid nodule in the right middle lobe. IMPRESSION: 6 mm nodule. Follow-up CT chest in 6 to 12 months.');
-- I8 patient that does not exist
CALL CORE.INGEST_REPORT('RRT08', 'P77777', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL',
  'FINDINGS: 9 x 9 mm solid nodule. IMPRESSION: 9 mm nodule. Follow-up CT chest in 3 months.');

CALL CORE.PROCESS_NEW_REPORTS();

-- Results per case (one row per landed report).
SELECT r.report_id,
       (SELECT COUNT(*) FROM RAW.REPORTS x WHERE x.report_id = r.report_id) AS rows_landed,
       e.report_id IS NOT NULL AS extracted, er.error IS NOT NULL AS in_error_queue,
       LISTAGG(DISTINCT l.finding_type || ' ' || COALESCE(l.avg_mm::STRING, '-') || 'mm tier ' || COALESCE(l.tier::STRING, '-')
               || ' ' || s.status || ' qa=' || COALESCE(l.qa_flag, '-'), '; ') AS loops
FROM RAW.REPORTS r
LEFT JOIN AI.EXTRACTIONS e ON e.report_id = r.report_id
LEFT JOIN CORE.EXTRACTION_ERRORS er ON er.report_id = r.report_id
LEFT JOIN CORE.LOOPS l ON l.report_id = r.report_id
LEFT JOIN CORE.LOOP_STATUS s ON s.loop_id = l.loop_id
WHERE r.report_id LIKE 'RRT%' OR r.report_id IS NULL AND r.patient_id = 'P0RT01'
GROUP BY r.report_id, e.report_id, er.error ORDER BY r.report_id;

-- Clean up everything this file created.
DELETE FROM AI.FOLLOWUP_CHECKS WHERE loop_id IN (SELECT loop_id FROM CORE.LOOPS WHERE patient_id IN ('P0RT01', 'P77777'));
DELETE FROM AI.EXTRACTIONS WHERE report_id IN (SELECT report_id FROM RAW.REPORTS WHERE patient_id IN ('P0RT01', 'P77777'));
DELETE FROM RAW.REPORTS WHERE patient_id IN ('P0RT01', 'P77777');
DELETE FROM RAW.PATIENTS WHERE patient_id = 'P0RT01';
ALTER DYNAMIC TABLE CORE.FINDINGS REFRESH;
ALTER DYNAMIC TABLE CORE.LOOPS REFRESH;
ALTER DYNAMIC TABLE CORE.LOOP_STATUS REFRESH;
SELECT COUNT(*) AS leftover_rows FROM RAW.REPORTS WHERE patient_id IN ('P0RT01', 'P77777');

-- I9 missing report id: must be rejected (NOT NULL). Last on purpose, because the error ends the script.
CALL CORE.INGEST_REPORT(NULL, 'P0RT01', '2026-09-01', 'CT_CHEST', '71250', 'HOSPITAL', 'FINDINGS: none.');
