-- Eval procedure. Lives in eval/ because EVAL is the only layer allowed to read KEY.ANSWER_KEY.
USE WAREHOUSE COMPUTE_WH;
USE DATABASE FFU;

-- Eval: loop status vs the hidden answer key (Set C). Results are appended to EVAL.RUNS.
CREATE TABLE IF NOT EXISTS EVAL.RUNS (run_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), label STRING, n NUMBER,
  correct NUMBER, accuracy FLOAT, false_green NUMBER, false_green_upper95 FLOAT, missed_loops NUMBER, quote_verified_rate FLOAT);
CREATE OR REPLACE PROCEDURE EVAL.RUN_EVAL(LABEL STRING)
RETURNS TABLE (label STRING, n NUMBER, correct NUMBER, accuracy FLOAT, false_green NUMBER, false_green_upper95 FLOAT,
               missed_loops NUMBER, quote_verified_rate FLOAT)
LANGUAGE SQL AS
$$
DECLARE res RESULTSET;
BEGIN
  INSERT INTO EVAL.RUNS (label, n, correct, accuracy, false_green, false_green_upper95, missed_loops, quote_verified_rate)
  WITH d AS (SELECT MAX(sim_date) sim_date FROM CTRL.SIM_DATE),
  k AS (SELECT k.report_id,
          CASE WHEN expected_action = 'NONE_REQUIRED' THEN 'NO_LOOP' WHEN expected_pathway <> 'STANDARD' THEN 'REROUTED'
               WHEN outcome = 'HOSP_DONE' AND outcome_date <= d.sim_date THEN 'GREEN'
               WHEN outcome = 'OUTSIDE_CLAIM' AND outcome_date <= d.sim_date THEN 'AMBER'
               WHEN DATEADD(day, ROUND(30.4 * due_max_months), report_date) < d.sim_date THEN 'RED' ELSE 'OPEN' END AS exp
        FROM KEY.ANSWER_KEY k CROSS JOIN d),
  s AS (SELECT report_id, MAX_BY(status, -tier) AS got FROM CORE.LOOP_STATUS GROUP BY 1),
  j AS (SELECT k.exp, COALESCE(s.got, 'NO_LOOP') got FROM k LEFT JOIN s USING (report_id)),
  q AS (SELECT AVG(IFF(quote_verified, 1, 0)) r FROM CORE.FINDINGS)
  SELECT :LABEL, COUNT(*), COUNT_IF(exp = got), COUNT_IF(exp = got) / COUNT(*),
         COUNT_IF(got = 'GREEN' AND exp <> 'GREEN'),
         -- rule of three when zero, else a simple Wilson-style upper bound
         IFF(COUNT_IF(got = 'GREEN' AND exp <> 'GREEN') = 0, 3 / NULLIF(COUNT_IF(got = 'GREEN'), 0),
             (COUNT_IF(got = 'GREEN' AND exp <> 'GREEN') + 1.96 * SQRT(COUNT_IF(got = 'GREEN' AND exp <> 'GREEN'))) / NULLIF(COUNT_IF(got = 'GREEN'), 0)),
         COUNT_IF(got = 'NO_LOOP' AND exp <> 'NO_LOOP'), ANY_VALUE(q.r)
  FROM j CROSS JOIN q;
  res := (SELECT label, n, correct, accuracy, false_green, false_green_upper95, missed_loops, quote_verified_rate
          FROM EVAL.RUNS ORDER BY run_at DESC LIMIT 1);
  RETURN TABLE(res);
END;
$$;

