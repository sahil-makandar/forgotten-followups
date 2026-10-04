-- Set B payer claims (from the CLAIM:<cpt>:<date> evidence in EVAL.SETB_LABELS). Run: snow sql -c payer -f eval/setB/03_payer_claims.sql
INSERT INTO PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS (event_id, patient_id, service_date, cpt, cpt_desc, facility, partner_account)
SELECT * FROM VALUES
  ('EB14', 'PB14', '2026-06-15'::DATE, '71046', 'Chest X-ray 2 views', 'Lakeside Medical Centre', 'AZ66410'),
  ('EB15', 'PB15', '2026-06-10'::DATE, '71250', 'CT chest without contrast', 'Lakeside Medical Centre', 'AZ66410'),
  ('EB18', 'PB18', '2026-06-12'::DATE, '71271', 'Low-dose CT lung screening', 'Lakeside Medical Centre', 'AZ66410'),
  ('EB34', 'PB34', '2026-05-20'::DATE, '78815', 'PET/CT skull base to mid-thigh', 'Lakeside Medical Centre', 'AZ66410') v
WHERE v.$1 NOT IN (SELECT event_id FROM PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS);
