-- Copies the per-question scores of a native agent evaluation run (EXECUTE_AI_EVALUATION, see eval/agent/cortex_project)
-- into EVAL.AGENT_EVAL_RESULTS, which the app reads. A question counts as correct when answer_correctness >= 0.5.
-- Set the run name below; each run is kept (only rows for that run are replaced). Runs: ffu_agent_eval_20261005
-- (before the clinic-filter fix), ffu_agent_eval_20261006_clinicfix (after).
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE TABLE IF NOT EXISTS FFU.EVAL.AGENT_EVAL_RESULTS (
  run_name STRING, q_id STRING, category STRING, input_query STRING, expected_tool STRING,
  answer_correctness FLOAT, tool_selection_accuracy FLOAT, correct BOOLEAN, agent_answer STRING,
  judge_model STRING, agent_version STRING, stored_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

SET run = 'ffu_agent_eval_20261006_clinicfix';
DELETE FROM FFU.EVAL.AGENT_EVAL_RESULTS WHERE run_name = $run;

INSERT INTO FFU.EVAL.AGENT_EVAL_RESULTS (run_name, q_id, category, input_query, expected_tool, answer_correctness,
       tool_selection_accuracy, correct, agent_answer, judge_model, agent_version)
WITH ev AS (
  SELECT * FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS('FFU', 'APP', 'FFU_AGENT', 'CORTEX AGENT'))
  WHERE record_attributes:"snow.ai.observability.run.name"::STRING = $run),
s AS (
  SELECT record_attributes:"ai.observability.eval.target_record_id"::STRING AS rid,
         record_attributes:"ai.observability.eval.metric_name"::STRING AS metric,
         record_attributes:"ai.observability.eval_root.score"::FLOAT AS score,
         record_attributes:"ai.observability.eval.llm_judge_name"::STRING AS judge,
         record_attributes:"snow.ai.observability.object.version.name"::STRING AS ver
  FROM ev WHERE record_attributes:"ai.observability.span_type"::STRING = 'eval_root'),
r AS (
  SELECT record_attributes:"ai.observability.record_id"::STRING AS rid,
         record_attributes:"ai.observability.record_root.input"::STRING AS q,
         record_attributes:"ai.observability.record_root.output"::STRING AS a
  FROM ev WHERE record_attributes:"ai.observability.span_type"::STRING = 'record_root')
SELECT $run, g.q_id, g.category, g.input_query, g.expected_tool,
       MAX(IFF(s.metric = 'answer_correctness', s.score, NULL)),
       MAX(IFF(s.metric = 'tool_selection_accuracy', s.score, NULL)),
       MAX(IFF(s.metric = 'answer_correctness', s.score, NULL)) >= 0.5,
       ANY_VALUE(r.a), ANY_VALUE(s.judge), ANY_VALUE(s.ver)
FROM s JOIN r ON r.rid = s.rid JOIN FFU.EVAL.AGENT_GOLDEN g ON g.input_query = r.q
GROUP BY g.q_id, g.category, g.input_query, g.expected_tool;

GRANT SELECT ON TABLE FFU.EVAL.AGENT_EVAL_RESULTS TO ROLE FFU_ANALYST;

SELECT COUNT(*) AS questions, COUNT_IF(correct) AS correct, COUNT_IF(answer_correctness = 1) AS fully_correct,
       ROUND(AVG(answer_correctness), 3) AS avg_answer_correctness, COUNT_IF(tool_selection_accuracy = 1) AS right_tool
FROM FFU.EVAL.AGENT_EVAL_RESULTS WHERE run_name = $run;
