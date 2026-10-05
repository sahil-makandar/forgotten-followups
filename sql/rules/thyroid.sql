-- Thyroid nodule follow-up rule (ACR 2015 incidental thyroid white paper)
-- Hoang JK et al., J Am Coll Radiol 2015;12:143-150
-- Ultrasound if >= 1.5 cm (age 35+), >= 1.0 cm (under 35), or any size with suspicious features.
-- Tier 1 if suspicious, tier 2 otherwise. Closed by thyroid US CPT 76536 within 3 months.

CREATE OR REPLACE DYNAMIC TABLE FFU.CORE.EXTRA_RULES
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = COMPUTE_WH
  REFRESH_MODE = FULL
AS
SELECT * FROM FFU.CORE.EXTRA_RULES_EMPTY
UNION ALL
SELECT
    'L-' || f.finding_key                          AS loop_id,
    f.finding_key,
    f.report_id,
    f.patient_id,
    p.clinic_id,
    f.report_date,
    f.finding_type,
    f.nodule_type,
    f.location,
    f.long_mm,
    f.short_mm,
    f.avg_mm,
    f.solid_mm,
    f.aorta_cm,
    f.hedged,
    f.stable,
    f.suspicious,
    f.quote,
    f.quote_verified,
    p.age,
    p.sex,
    p.smoking,
    p.tb_history,
    CASE WHEN f.suspicious THEN 1 ELSE 2 END       AS tier,
    'STANDARD'                                      AS pathway,
    NULL                                            AS reroute_reason,
    'Thyroid ultrasound per ACR 2015'               AS guideline_action,
    'THYROID_ULTRASOUND'                            AS action,
    3                                               AS due_min_months,
    3                                               AS due_max_months,
    DATEADD(DAY, ROUND(30.4 * 3), f.report_date)   AS due_start,
    DATEADD(DAY, ROUND(30.4 * 3), f.report_date)   AS due_end,
    NULL                                            AS qa_flag
FROM FFU.CORE.FINDINGS f
JOIN FFU.RAW.PATIENTS   p ON p.patient_id = f.patient_id
WHERE f.finding_type = 'THYROID_NODULE'
  AND NOT f.negated
  AND (
        f.suspicious
     OR (p.age < 35  AND f.long_mm >= 10)
     OR (p.age >= 35 AND f.long_mm >= 15)
  );

-- Closure codes
INSERT INTO FFU.CORE.CLOSURE_CODES (action, cpt, closes, screening_only, note)
SELECT 'THYROID_ULTRASOUND', '76536', TRUE, FALSE, 'Thyroid ultrasound'
WHERE NOT EXISTS (SELECT 1 FROM FFU.CORE.CLOSURE_CODES WHERE action = 'THYROID_ULTRASOUND' AND cpt = '76536');

INSERT INTO FFU.CORE.CLOSURE_CODES (action, cpt, closes, screening_only, note)
SELECT 'THYROID_ULTRASOUND', '70491', FALSE, FALSE, 'Neck CT does not close a thyroid ultrasound loop'
WHERE NOT EXISTS (SELECT 1 FROM FFU.CORE.CLOSURE_CODES WHERE action = 'THYROID_ULTRASOUND' AND cpt = '70491');
