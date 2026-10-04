-- Thyroid extension check: compares loops produced by the compiled rule with EVAL.THYROID_EXPECTED.
-- Every row must say PASS. Also confirms the rule is closed by thyroid ultrasound (CPT 76536) only.
SELECT e.report_id, e.why, e.expect_loop, l.loop_id IS NOT NULL AS got_loop, e.expect_tier, l.tier AS got_tier,
  IFF(e.expect_loop = (l.loop_id IS NOT NULL) AND (NOT e.expect_loop OR e.expect_tier = l.tier), 'PASS', 'FAIL') AS result
FROM FFU.EVAL.THYROID_EXPECTED e
LEFT JOIN FFU.CORE.LOOPS l ON l.report_id = e.report_id AND l.finding_type = 'THYROID_NODULE'
UNION ALL
SELECT 'closure_codes', 'thyroid loops close only with 76536', TRUE,
  COUNT_IF(action = 'THYROID_ULTRASOUND' AND cpt = '76536' AND closes) = 1, NULL, NULL,
  IFF(COUNT_IF(action = 'THYROID_ULTRASOUND' AND cpt = '76536' AND closes) = 1
      AND COUNT_IF(action = 'THYROID_ULTRASOUND' AND cpt <> '76536' AND closes) = 0, 'PASS', 'FAIL')
FROM FFU.CORE.CLOSURE_CODES
ORDER BY 1;
