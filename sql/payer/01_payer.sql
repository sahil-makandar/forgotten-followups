-- PAYER 01: claims-derived follow-up events, governance policies and the Secure Data Share.
-- Run on the payer account:  snow sql -c payer -f sql/payer/01_payer.sql
-- Plain SQL only (no AI functions on this account).
-- Events are seeded by sql/payer/02_payer_events.sql (generated from the hospital answer key, no report text).
CREATE DATABASE IF NOT EXISTS PAYER_DB;
CREATE SCHEMA IF NOT EXISTS PAYER_DB.SHARED;
CREATE SCHEMA IF NOT EXISTS PAYER_DB.GOV;

CREATE TABLE IF NOT EXISTS PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS (
  event_id STRING PRIMARY KEY,
  patient_id STRING,           -- matched member id (shared hospital MPI key)
  service_date DATE,
  cpt STRING,
  cpt_desc STRING,
  facility STRING,             -- performing facility (outside hospital)
  partner_account STRING,      -- consumer account allowed to see the row
  member_ssn_last4 STRING,     -- synthetic sensitive column, always masked for consumers
  loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

-- Row access: a consumer account only sees rows tagged with its own locator.
CREATE ROW ACCESS POLICY IF NOT EXISTS PAYER_DB.GOV.PARTNER_ROWS AS (partner_account STRING) RETURNS BOOLEAN ->
  CURRENT_ROLE() = 'ACCOUNTADMIN' AND INVOKER_SHARE() IS NULL
  OR partner_account = CURRENT_ACCOUNT();

-- Masking: nobody outside the payer sees member identifiers.
CREATE MASKING POLICY IF NOT EXISTS PAYER_DB.GOV.MASK_SSN AS (v STRING) RETURNS STRING ->
  IFF(INVOKER_SHARE() IS NULL AND CURRENT_ROLE() = 'ACCOUNTADMIN', v, '****');

ALTER TABLE PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS ADD ROW ACCESS POLICY PAYER_DB.GOV.PARTNER_ROWS ON (partner_account);
ALTER TABLE PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS MODIFY COLUMN member_ssn_last4 SET MASKING POLICY PAYER_DB.GOV.MASK_SSN;

CREATE SHARE IF NOT EXISTS FFU_SHARE COMMENT = 'Follow-up events derived from claims, for partner hospitals';
GRANT USAGE ON DATABASE PAYER_DB TO SHARE FFU_SHARE;
GRANT USAGE ON SCHEMA PAYER_DB.SHARED TO SHARE FFU_SHARE;
GRANT SELECT ON TABLE PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS TO SHARE FFU_SHARE;
ALTER SHARE FFU_SHARE ADD ACCOUNTS = AZ66410;
