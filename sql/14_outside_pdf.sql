-- 14 Outside-hospital report PDFs: AI_PARSE_DOCUMENT reads the PDF, the text lands as a normal report,
-- and the usual pipeline (AI_FILTER check) can turn an AMBER loop GREEN.
-- Upload: snow stage copy demo/inbox_outside/<file>.pdf @FFU.APP.OUTSIDE_DOCS -c hospital --overwrite
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

-- AI_PARSE_DOCUMENT needs server-side encryption and a directory table on the stage.
CREATE STAGE IF NOT EXISTS APP.OUTSIDE_DOCS ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE);

-- Cache of parsed documents (never parse the same file twice).
CREATE TABLE IF NOT EXISTS AI.PARSED_DOCS (file_name STRING, report_id STRING, parsed VARIANT, parsed_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE PROCEDURE CORE.INGEST_OUTSIDE_PDF(FILE_NAME STRING, REPORT_ID STRING, PATIENT_ID STRING,
  REPORT_DATE DATE, MODALITY STRING, CPT STRING, FACILITY STRING)
RETURNS STRING LANGUAGE SQL AS
$$
DECLARE txt STRING;
BEGIN
  ALTER STAGE APP.OUTSIDE_DOCS REFRESH;
  INSERT INTO AI.PARSED_DOCS (file_name, report_id, parsed)
  SELECT :FILE_NAME, :REPORT_ID, AI_PARSE_DOCUMENT(TO_FILE('@FFU.APP.OUTSIDE_DOCS', :FILE_NAME), {'mode': 'LAYOUT'})
  WHERE NOT EXISTS (SELECT 1 FROM AI.PARSED_DOCS WHERE file_name = :FILE_NAME);
  txt := (SELECT parsed:content::STRING FROM AI.PARSED_DOCS WHERE file_name = :FILE_NAME ORDER BY parsed_at DESC LIMIT 1);
  IF (txt IS NULL OR LENGTH(txt) < 50) THEN
    RETURN 'Could not read ' || :FILE_NAME || ' - review by hand';
  END IF;
  CALL CORE.INGEST_REPORT(:REPORT_ID, :PATIENT_ID, :REPORT_DATE, :MODALITY, :CPT, :FACILITY, :txt);
  RETURN 'parsed ' || :FILE_NAME || ' (' || LENGTH(txt) || ' chars) and ingested as ' || :REPORT_ID;
END;
$$;
