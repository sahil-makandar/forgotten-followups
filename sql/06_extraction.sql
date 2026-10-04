-- 06 AI extraction: one cached JSON row per report, with verbatim evidence quotes.
-- Only reports not yet in AI.EXTRACTIONS are processed (never re-run AI on the same text).
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

CREATE TABLE IF NOT EXISTS AI.EXTRACTIONS (
  report_id STRING PRIMARY KEY, j VARIANT, err STRING, model STRING,
  extracted_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE PROCEDURE AI.EXTRACT_NEW(MODEL STRING, MAX_ROWS NUMBER)
RETURNS NUMBER LANGUAGE SQL AS
$$
BEGIN
  DELETE FROM AI.EXTRACTIONS WHERE err IS NOT NULL OR j IS NULL;
  INSERT INTO AI.EXTRACTIONS (report_id, j, err, model)
  SELECT report_id, r:value, r:error::STRING, :MODEL FROM (
    SELECT report_id, AI_COMPLETE(
      model => :MODEL,
      prompt => 'You extract follow-up information from radiology reports and clinic notes. Return every finding that is described (including findings that are absent, stable or benign). '
        || 'Rules: quote = an exact, word-for-word copy of the single sentence from the report that best supports the finding and recommendation (do not paraphrase, do not join sentences). '
        || 'Nodule sizes in mm (long_mm and short_mm as written); solid_mm = solid component of a part-solid nodule; aorta_cm = aortic diameter in cm. '
        || 'negated = the report says the finding is NOT present. stable = described as stable or unchanged versus a prior study. hedged = the recommendation is conditional, e.g. if clinically indicated. '
        || 'suspicious = words like suspicious, mass or concerning for malignancy. If the report states a follow-up interval, give due_min_months and due_max_months (single value: both equal); else use -1. Use -1 for unknown numbers. '
        || 'If an ADDENDUM changes the recommendation, use the addendum. Also flag patient history mentioned in the report. REPORT: ' || text,
      model_parameters => {'temperature': 0, 'max_tokens': 2000},
      response_format => {'type':'json','schema':{'type':'object','properties':{
        'history':{'type':'object','properties':{'known_cancer':{'type':'boolean'},'immunosuppressed':{'type':'boolean'},'screening_programme':{'type':'boolean'}},'required':['known_cancer','immunosuppressed','screening_programme']},
        'findings':{'type':'array','items':{'type':'object','properties':{
          'finding_type':{'type':'string','enum':['LUNG_NODULE','CXR_OPACITY','AAA','THYROID_NODULE','OTHER']},
          'nodule_type':{'type':'string','enum':['SOLID','PART_SOLID','GROUND_GLASS','NA']},
          'location':{'type':'string'},
          'long_mm':{'type':'number'},'short_mm':{'type':'number'},'solid_mm':{'type':'number'},'aorta_cm':{'type':'number'},
          'recommended_action':{'type':'string','enum':['CT_CHEST','PET_CT','BIOPSY','AAA_ULTRASOUND','VASCULAR_REFERRAL','THYROID_ULTRASOUND','NONE','OTHER']},
          'due_min_months':{'type':'number'},'due_max_months':{'type':'number'},
          'hedged':{'type':'boolean'},'negated':{'type':'boolean'},'stable':{'type':'boolean'},'suspicious':{'type':'boolean'},
          'quote':{'type':'string'}},
          'required':['finding_type','nodule_type','location','long_mm','short_mm','solid_mm','aorta_cm','recommended_action','due_min_months','due_max_months','hedged','negated','stable','suspicious','quote']}}},
        'required':['findings']}},
      return_error_details => TRUE) AS r
    FROM RAW.REPORTS
    WHERE report_id NOT IN (SELECT report_id FROM AI.EXTRACTIONS)
    ORDER BY report_id LIMIT :MAX_ROWS);
  RETURN SQLROWCOUNT;
END;
$$;



