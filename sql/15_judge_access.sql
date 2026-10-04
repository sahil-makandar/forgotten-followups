-- 15 Read-only judge access for the deployed app. The password is NEVER stored here; it is set once by hand.
-- Creates: warehouse FFU_APP_WH (app + judge, capped at 5 credits/day), role FFU_JUDGE, user JUDGE_RUZEN, user-level auth policy.
USE ROLE ACCOUNTADMIN;

-- Credit guard: a dedicated XS warehouse for the app and the judge, suspended once 5 credits are used in a day.
CREATE RESOURCE MONITOR IF NOT EXISTS FFU_APP_RM WITH CREDIT_QUOTA = 5 FREQUENCY = DAILY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND_IMMEDIATE;
CREATE WAREHOUSE IF NOT EXISTS FFU_APP_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  RESOURCE_MONITOR = FFU_APP_RM COMMENT = 'Deployed app and judge login; capped by FFU_APP_RM at 5 credits/day';
ALTER WAREHOUSE FFU_APP_WH SET RESOURCE_MONITOR = FFU_APP_RM;
ALTER STREAMLIT FFU.APP.FFU_APP SET QUERY_WAREHOUSE = FFU_APP_WH;

-- Role with only what the app needs. The app runs with owner's rights, so the judge needs USAGE on the app itself;
-- SELECT on the secure view is for the caller's-rights "View as analyst" toggle (judges see the MASKED view).
CREATE ROLE IF NOT EXISTS FFU_JUDGE COMMENT = 'Read-only hackathon judge: opens the deployed app';
GRANT USAGE ON WAREHOUSE FFU_APP_WH TO ROLE FFU_JUDGE;
GRANT USAGE ON DATABASE FFU TO ROLE FFU_JUDGE;
GRANT USAGE ON SCHEMA FFU.APP TO ROLE FFU_JUDGE;
GRANT USAGE ON SCHEMA FFU.SEC TO ROLE FFU_JUDGE;
GRANT USAGE ON STREAMLIT FFU.APP.FFU_APP TO ROLE FFU_JUDGE;
GRANT SELECT ON VIEW FFU.SEC.LOOPS_V TO ROLE FFU_JUDGE;
GRANT USAGE ON AGENT FFU.APP.FFU_AGENT TO ROLE FFU_JUDGE;
GRANT ROLE FFU_JUDGE TO ROLE SYSADMIN;

-- User (password set separately, never in a file):
--   CREATE USER IF NOT EXISTS JUDGE_RUZEN TYPE = PERSON PASSWORD = '<set by hand>' MUST_CHANGE_PASSWORD = FALSE
--     DEFAULT_ROLE = FFU_JUDGE DEFAULT_WAREHOUSE = FFU_APP_WH DEFAULT_NAMESPACE = FFU.APP DEFAULT_SECONDARY_ROLES = ();
--   GRANT ROLE FFU_JUDGE TO USER JUDGE_RUZEN;

-- MFA enrolment optional for this user only (user-level policy beats any account-level policy).
CREATE AUTHENTICATION POLICY IF NOT EXISTS FFU.SEC.JUDGE_AUTH_POLICY
  MFA_ENROLLMENT = OPTIONAL
  COMMENT = 'Hackathon judge login: password allowed, MFA enrolment not forced';
-- ALTER USER JUDGE_RUZEN SET AUTHENTICATION POLICY FFU.SEC.JUDGE_AUTH_POLICY;   (run after the user exists)

-- The caller's-rights toggle runs on the viewer's default warehouse (FFU_APP_WH for judges).
GRANT CALLER USAGE ON WAREHOUSE FFU_APP_WH TO ROLE ACCOUNTADMIN;

