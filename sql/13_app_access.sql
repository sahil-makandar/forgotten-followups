-- 13 App and agent access. Run after: agent/create_agent.sql and `snow streamlit deploy ffu_app -c hospital --replace` (from app/).
USE ROLE ACCOUNTADMIN;
USE DATABASE FFU;

-- Agent wrapper used by the Streamlit chat (DATA_AGENT_RUN needs a constant body, so it is built here).
CREATE OR REPLACE PROCEDURE APP.ASK_AGENT(QUESTION STRING)
RETURNS VARIANT LANGUAGE SQL EXECUTE AS CALLER AS
$$
DECLARE body STRING; q STRING; dd STRING DEFAULT CHR(36) || CHR(36); rs RESULTSET; out VARIANT;
BEGIN
  -- Build the body with TO_JSON (safe escaping) and strip the dollar-quote marker so input can't break the literal.
  body := TO_JSON(OBJECT_CONSTRUCT('messages', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('role', 'user', 'content',
            ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('type', 'text', 'text', LEFT(:QUESTION, 2000)))))));
  body := REPLACE(body, :dd, '');
  q := 'SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(''FFU.APP.FFU_AGENT'', ' || :dd || body || :dd || ')) AS j';
  rs := (EXECUTE IMMEDIATE :q);
  FOR r IN rs DO out := r.j; END FOR;
  RETURN OBJECT_CONSTRUCT(
    'answer', (SELECT LISTAGG(c.value:text::STRING, '') FROM TABLE(FLATTEN(input => :out:content)) c WHERE c.value:type::STRING = 'text'),
    'tools', (SELECT ARRAY_AGG(DISTINCT c.value:tool_use:name::STRING) FROM TABLE(FLATTEN(input => :out:content)) c WHERE c.value:type::STRING = 'tool_use'),
    'warnings', :out:warnings);
END;
$$;

-- Coordinators can open the app (it runs with the owner's rights) and use the agent.
GRANT USAGE ON STREAMLIT APP.FFU_APP TO ROLE FFU_COORDINATOR;
GRANT USAGE ON AGENT APP.FFU_AGENT TO ROLE FFU_COORDINATOR;
GRANT USAGE ON CORTEX SEARCH SERVICE APP.REPORT_SEARCH TO ROLE FFU_COORDINATOR;

-- Restricted caller's rights for the "View as analyst" toggle: the app (owned by ACCOUNTADMIN) may act as the viewer
-- ONLY to read the role-aware secure view, using the warehouse. Masking then follows the viewer's own role.
GRANT CALLER USAGE ON DATABASE FFU TO ROLE ACCOUNTADMIN;
GRANT CALLER USAGE ON SCHEMA FFU.SEC TO ROLE ACCOUNTADMIN;
GRANT CALLER SELECT ON VIEW FFU.SEC.LOOPS_V TO ROLE ACCOUNTADMIN;
GRANT CALLER USAGE ON WAREHOUSE COMPUTE_WH TO ROLE ACCOUNTADMIN;
