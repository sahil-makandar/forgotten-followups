-- Read-only payer-side context from the Snowflake Marketplace listing
-- "Synthetic Healthcare Data - Clinical and Claims" (mounted as SYNTHETIC_HEALTHCARE_DATA_CLINICAL_AND_CLAIMS).
-- Shown on the Results page only. Not used by the pipeline, the rules or the demo.
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE SECURE VIEW FFU.APP.MKT_IMAGING_VOLUME
  COMMENT = 'Marketplace context: imaging study volume by modality (synthetic population). Read-only.'
AS
SELECT modality_code,
       modality_description,
       COUNT(DISTINCT id)         AS studies,
       COUNT(DISTINCT patient_id) AS patients,
       COUNT(*)                   AS image_instances
FROM SYNTHETIC_HEALTHCARE_DATA_CLINICAL_AND_CLAIMS.SILVER.IMAGING_STUDIES
WHERE modality_code IS NOT NULL
GROUP BY 1, 2;

GRANT SELECT ON VIEW FFU.APP.MKT_IMAGING_VOLUME TO ROLE FFU_ANALYST;
GRANT SELECT ON VIEW FFU.APP.MKT_IMAGING_VOLUME TO ROLE FFU_JUDGE;
