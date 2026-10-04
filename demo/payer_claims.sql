-- Demo payer claims. Run on the payer account: snow sql -c payer -f demo/payer_claims.sql
-- EDEMO001: correct test (CT chest) at another hospital for the hero patient -> AMBER.
-- EDEMO002: wrong test (chest X-ray) for the decoy patient -> stays RED with the reason shown.
INSERT INTO PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS (event_id, patient_id, service_date, cpt, cpt_desc, facility, partner_account)
SELECT * FROM VALUES
  ('EDEMO001', 'P09901', '2027-01-20'::DATE, '71250', 'CT chest without contrast', 'City General Hospital', 'AZ66410'),
  ('EDEMO002', 'P09902', '2026-09-10'::DATE, '71046', 'Chest X-ray 2 views', 'Lakeside Medical Centre', 'AZ66410') v
WHERE v.$1 NOT IN (SELECT event_id FROM PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS);
UPDATE PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS SET member_ssn_last4 = LPAD(ABS(HASH(patient_id, 'ssn')) % 10000, 4, '0')
WHERE event_id LIKE 'EDEMO%';
