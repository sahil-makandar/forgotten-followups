-- Copilot golden set: 15 questions about the worklist, loops, rules and letters, each with an expected answer and
-- the expected tool. Facts are taken from the DEMO_RESET(TRUE) state (sim date 2026-10-04). Used by Snowflake's native
-- agent evaluation (eval/agent/ffu_agent_eval.eval.yaml) on FFU.APP.FFU_AGENT. Count questions accept either the
-- worklist count or the count including the EVAL clinic, because the semantic view reads all loops.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE OR REPLACE TABLE FFU.EVAL.AGENT_GOLDEN (
  q_id STRING, category STRING, input_query STRING, expected_answer STRING, expected_tool STRING,
  expected_output VARIANT, track STRING);

INSERT INTO FFU.EVAL.AGENT_GOLDEN (q_id, category, input_query, expected_answer, expected_tool, expected_output, track)
SELECT q_id, category, q, a, t,
       PARSE_JSON(OBJECT_CONSTRUCT('ground_truth_output', a,
                                   'ground_truth_invocations', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('tool_name', t)))::STRING),
       'tea'
FROM VALUES
 ('G01','worklist','Who is first on the worklist and why?',
  'Loop L-R00334-0 for patient P00334 is rank 1: RED, tier 1, priority 3950 (3000 tier + 900 time + 50 context for age 65+ and current smoker), overdue by 296 days. It comes from a chest X-ray (report R00334) recommending CT, rule R3.',
  'explain_priority'),
 ('G02','worklist','Why is patient P09902 still red?',
  'P09902 (loop L-RSEED902-0) is RED, tier 1, overdue by 62 days. The only later test was a chest X-ray (71046 on 2026-09-10), which is the wrong test and does not close a CT loop. The 10 x 8 mm solid nodule needed a CT in 3 months (rule R1).',
  'explain_priority'),
 ('G03','worklist','What is the priority score breakdown for loop L-RSEED902-0?',
  'Priority 3277.2 = 3000 tier 1 + 252.2 time (168% of the due window elapsed) + 25 context (current smoker). Rule R7.',
  'explain_priority'),
 ('G04','worklist','Has the patient for loop L-R00334-0 been notified, and has the clinician acknowledged it?',
  'The patient was notified (true) but the clinician has not acknowledged it (false).',
  'explain_priority'),
 ('G05','loops','How many loops are red (overdue) right now?',
  '162 red loops on the worklist (208 if the evaluation clinic is included).',
  'loop_analytics'),
 ('G06','loops','How many loops were closed only by outside claims?',
  '49 loops (AMBER: a payer claim shows the right test elsewhere and an outside report was requested); 51 if the evaluation clinic is included.',
  'loop_analytics'),
 ('G07','loops','How many red abdominal aortic aneurysm loops are there?',
  '25 red AAA loops (28 if the evaluation clinic is included).',
  'loop_analytics'),
 ('G08','loops','How many red loops are tier 1?',
  '121 tier-1 red loops (149 if the evaluation clinic is included).',
  'loop_analytics'),
 ('G09','loops','How many red loops have a patient who was never notified?',
  '60 red loops with the patient not notified (106 if the evaluation clinic is included).',
  'loop_analytics'),
 ('G10','rules','Does a chest X-ray close a CT follow-up loop for a lung nodule?',
  'No. A chest X-ray (71045, 71046) is the wrong test and never closes a CT loop; only CT chest (71250, 71260, 71270), PET/CT (78815) or biopsy (32405) that discusses the nodule closes it (rule R2).',
  'search_reports_and_rules'),
 ('G11','rules','What follow-up is recommended for a solid lung nodule of 6 to 8 mm?',
  'CT at 6 to 12 months (Fleischner 2017, rule R1).',
  'search_reports_and_rules'),
 ('G12','rules','When does an abdominal aortic aneurysm need a vascular surgery referral?',
  'At 5.5 cm or more in men or 5.0 cm or more in women: vascular surgery referral within 1 month, tier 1 (SVS 2018, rule R4).',
  'search_reports_and_rules'),
 ('G13','rules','What does AMBER status mean?',
  'A payer claim shows the right test was done at another hospital but there is no report yet, so an outside-report request is created (rule R6).',
  'search_reports_and_rules'),
 ('G14','letters','Draft the patient letter for L-RSEED902-0',
  'A patient recall letter draft for loop L-RSEED902-0, asking the patient to book a follow-up CT chest, citing report RSEED902. It is a draft pending clinician approval and has not been sent.',
  'draft_letter'),
 ('G15','letters','Draft a specialist referral for loop L-R00334-0',
  'A referral draft for loop L-R00334-0 (patient P00334) for the overdue CT after the chest X-ray opacity, citing report R00334. It is a draft pending clinician approval and has not been sent.',
  'draft_letter')
AS v(q_id, category, q, a, t);

SELECT q_id, expected_tool, IS_OBJECT(expected_output) AS ok FROM FFU.EVAL.AGENT_GOLDEN ORDER BY q_id;
