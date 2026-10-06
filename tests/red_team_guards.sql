-- Red-team guard tests: the input checks added after the red team (docs/RED_TEAM.md). No AI calls, nothing inserted.
-- Run: snow sql -c hospital -f tests/red_team_guards.sql   (every row should say PASS)
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CALL CORE.INGEST_REPORT(NULL, 'P09901', '2026-10-04', 'CT_CHEST', '71250', 'HOSPITAL', 'FINDINGS: 9 mm nodule. Follow-up CT in 3 months.');
SET r_null_id = (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
CALL CORE.INGEST_REPORT('RGUARD1', 'P77777', '2026-10-04', 'CT_CHEST', '71250', 'HOSPITAL', 'FINDINGS: 9 mm nodule. Follow-up CT in 3 months.');
SET r_unknown = (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
CALL CORE.INGEST_REPORT('RGUARD2', 'P09901', '2026-10-04', 'CT_CHEST', '71250', 'HOSPITAL', '   ');
SET r_empty = (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
CALL CORE.INGEST_REPORT('RSEED902', 'P09902', '2026-05-04', 'CT_CHEST', '71260', 'HOSPITAL', 'FINDINGS: duplicate of the seeded decoy report.');
SET r_dup = (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
CALL APP.APPROVE_DRAFT('no-such-draft', '   ');
SET a_blank = (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
CALL APP.APPROVE_DRAFT('no-such-draft', 'Dr Test');
SET a_unknown = (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
CALL APP.DRAFT_LETTER('L-RSEED902-0', 'APPROVED');
SET d_kind = (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
CALL APP.DRAFT_LETTER('L-NOPE-0', 'PATIENT');
SET d_loop = (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
CALL APP.ASK_AGENT(REPEAT('x', 2500));
SET q_long = (SELECT $1:answer::STRING FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

SELECT test, IFF(ok, 'PASS', 'FAIL') AS result, got FROM (
  SELECT 'ingest: missing report id refused' AS test, $r_null_id LIKE 'not ingested: missing report id%' AS ok, $r_null_id AS got UNION ALL
  SELECT 'ingest: unknown patient refused', $r_unknown LIKE 'not ingested RGUARD1: unknown patient%', $r_unknown UNION ALL
  SELECT 'ingest: empty report refused', $r_empty LIKE 'not ingested RGUARD2: report text is empty%', $r_empty UNION ALL
  SELECT 'ingest: duplicate id reported as skipped', $r_dup LIKE 'skipped RSEED902%', $r_dup UNION ALL
  SELECT 'ingest: nothing landed', (SELECT COUNT(*) FROM RAW.REPORTS WHERE report_id IN ('RGUARD1', 'RGUARD2')) = 0
         AND (SELECT COUNT(*) FROM RAW.REPORTS WHERE report_id = 'RSEED902') = 1, NULL UNION ALL
  SELECT 'approve: blank clinician refused', $a_blank LIKE 'Not approved%', $a_blank UNION ALL
  SELECT 'approve: unknown draft refused', $a_unknown LIKE 'No pending draft%', $a_unknown UNION ALL
  SELECT 'letter: invalid kind refused', $d_kind LIKE 'Unknown letter kind%', $d_kind UNION ALL
  SELECT 'letter: unknown loop refused', $d_loop LIKE 'Unknown loop%', $d_loop UNION ALL
  SELECT 'copilot: over-long question refused, not truncated', $q_long LIKE '%shorter question%', $q_long
);
