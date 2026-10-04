-- Demo: what an analyst sees. Run in a Snowsight worksheet or: snow sql -c hospital -f sql/demo/analyst_view.sql
-- Uses the same user, switching the PRIMARY role to FFU_ANALYST with secondary roles OFF, so nothing widens access.
-- Expected: all clinics, patient IDs hashed (P-xxxxxxxx), quotes and reasons '***', ages as bands, and 0 report rows.
USE ROLE FFU_ANALYST;
USE SECONDARY ROLES NONE;
USE WAREHOUSE COMPUTE_WH;

SELECT CURRENT_ROLE() AS primary_role, CURRENT_SECONDARY_ROLES() AS secondary_roles;

-- Masked loop rows (red and amber, most dangerous first).
SELECT loop_id, patient_id, clinic_id, finding_type, tier, status, days_overdue, age, age_band, quote, status_reason
FROM FFU.SEC.LOOPS_V
WHERE status IN ('RED', 'AMBER')
ORDER BY tier, priority_score DESC
LIMIT 10;

-- Aggregates still work for analysts.
SELECT clinic_id, status, COUNT(*) AS loops FROM FFU.SEC.LOOPS_V GROUP BY 1, 2 ORDER BY 1, 2;

-- Report text is never visible to analysts.
SELECT COUNT(*) AS report_rows_visible FROM FFU.SEC.REPORTS_V;

-- Back to the admin role for everything else.
USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES ALL;
