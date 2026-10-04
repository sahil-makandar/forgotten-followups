-- 04 Hospital orders, patient notifications and clinician acknowledgements, derived from the answer key.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CREATE OR REPLACE TABLE RAW.ACKS AS
SELECT 'A' || SUBSTR(report_id, 2) AS ack_id, report_id, patient_id,
       'DR' || (1 + ABS(HASH(report_id)) % 12) AS clinician_id,
       DATEADD(day, 1 + ABS(HASH(report_id, 'a')) % 5, report_date) AS ack_date
FROM KEY.ANSWER_KEY WHERE clinician_acked AND expected_action <> 'NONE_REQUIRED';

CREATE OR REPLACE TABLE RAW.NOTIFICATIONS AS
SELECT 'N' || SUBSTR(report_id, 2) AS notification_id, report_id, patient_id,
       IFF(ABS(HASH(report_id)) % 2 = 0, 'LETTER', 'PORTAL') AS channel,
       DATEADD(day, 3 + ABS(HASH(report_id, 'n')) % 10, report_date) AS notified_date
FROM KEY.ANSWER_KEY WHERE patient_notified AND expected_action <> 'NONE_REQUIRED';

CREATE OR REPLACE TABLE RAW.ORDERS AS
SELECT 'O' || SUBSTR(report_id, 2) AS order_id, patient_id, report_id AS source_report_id,
       CASE expected_action WHEN 'CT_CHEST' THEN '71250' WHEN 'AAA_ULTRASOUND' THEN '76775' ELSE '99244' END AS cpt,
       DATEADD(day, 7, report_date) AS order_date,
       IFF(outcome = 'HOSP_DONE', 'COMPLETED', 'PLACED') AS status
FROM KEY.ANSWER_KEY
WHERE expected_action <> 'NONE_REQUIRED' AND (outcome = 'HOSP_DONE' OR ABS(HASH(report_id, 'o')) % 100 < 30);
