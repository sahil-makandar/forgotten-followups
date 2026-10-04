-- Priority scale test: tier bands must never overlap.
-- Worst-case tier-2 (elapsed capped at 2.0, every context point) must score below the best-case-low tier-1 (zero elapsed, no context).
-- Same for tier 3 vs tier 2. Every row must say PASS.
WITH s AS (
  SELECT
    FFU.CORE.PRIORITY(1, 0.0, 40, 'NEVER', 'F', 'SOLID', FALSE):score::FLOAT AS t1_min,
    FFU.CORE.PRIORITY(2, 99.0, 90, 'CURRENT', 'M', 'SOLID', TRUE):score::FLOAT AS t2_max,
    FFU.CORE.PRIORITY(2, 0.0, 40, 'NEVER', 'F', 'SOLID', FALSE):score::FLOAT AS t2_min,
    FFU.CORE.PRIORITY(3, 99.0, 90, 'CURRENT', 'M', 'GROUND_GLASS', TRUE):score::FLOAT AS t3_max,
    FFU.CORE.PRIORITY(2, 1.0, 40, 'NEVER', 'F', 'SOLID', TRUE):score::FLOAT AS t2_tb,
    FFU.CORE.PRIORITY(2, 1.0, 40, 'NEVER', 'F', 'SOLID', FALSE):score::FLOAT AS t2_no_tb,
    FFU.CORE.PRIORITY(2, 1.0, 50, 'NEVER', 'F', 'PART_SOLID', FALSE):score::FLOAT AS t2_ns_woman,
    FFU.CORE.PRIORITY(2, 1.0, 50, 'NEVER', 'M', 'PART_SOLID', FALSE):score::FLOAT AS t2_ns_man
)
SELECT 'tier2 max < tier1 min' AS test, t2_max || ' < ' || t1_min AS detail, IFF(t2_max < t1_min, 'PASS', 'FAIL') AS result FROM s
UNION ALL SELECT 'tier3 max < tier2 min', t3_max || ' < ' || t2_min, IFF(t3_max < t2_min, 'PASS', 'FAIL') FROM s
UNION ALL SELECT 'TB history never raises priority', t2_tb || ' = ' || t2_no_tb, IFF(t2_tb = t2_no_tb, 'PASS', 'FAIL') FROM s
UNION ALL SELECT 'never-smoker woman not downgraded', t2_ns_woman || ' >= ' || t2_ns_man, IFF(t2_ns_woman >= t2_ns_man, 'PASS', 'FAIL') FROM s;
