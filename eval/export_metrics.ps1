# Writes eval/metrics.json from Snowflake (official Set C run, Set B, baselines, cost, latency, failure cases).
# Official numbers come only from the CTRL.DEMO_RESET(TRUE) state. Usage: powershell -NoProfile -File eval/export_metrics.ps1
$env:PYTHONIOENCODING = 'utf-8'
$root = Split-Path $PSScriptRoot -Parent
function Q($sql) { snow sql -c hospital --format json -q $sql 2>$null | ConvertFrom-Json }

$run = Q "SELECT run_at::STRING AS run_at, label, state_note, n, correct, accuracy, false_green, false_green_upper95, missed_loops, quote_verified_rate FROM FFU.EVAL.RUNS WHERE official ORDER BY run_at DESC LIMIT 1"
if (-not $run) { Write-Host 'No official run. Run CALL FFU.CTRL.DEMO_RESET(TRUE); then CALL FFU.EVAL.RUN_EVAL(''official'');'; exit 1 }
$r = $run[0]
$base = Q "SELECT method, set_name, n, correct, accuracy, acc_ci_low, acc_ci_high, false_greens, should_not_be_green, false_green_rate, false_green_upper95_rule_of_3 FROM FFU.EVAL.BASELINE_SUMMARY ORDER BY set_name, method"
$setb = Q "SELECT COUNT(*) AS findings, COUNT_IF(status_ok) AS status_correct, COUNT_IF(false_green) AS false_greens, COUNT_IF(size_ok) AS size_ok, COUNT(size_ok) AS size_n, COUNT_IF(tier_ok) AS tier_ok, COUNT(tier_ok) AS tier_n, COUNT_IF(pathway_ok) AS pathway_ok, COUNT(pathway_ok) AS pathway_n, COUNT_IF(quote_verified) AS quotes_ok, COUNT(quote_verified) AS quotes_n FROM FFU.EVAL.SETB_RESULTS"
$traps = Q "SELECT trap, BOOLAND_AGG(status_ok) AS passed FROM FFU.EVAL.SETB_RESULTS GROUP BY trap ORDER BY trap"
$cost = Q "SELECT ROUND(SUM(IFF(service_type = 'AI_FUNCTIONS', credits_used, 0)), 3) AS ai_credits, ROUND(SUM(IFF(service_type = 'WAREHOUSE_METERING', credits_used, 0)), 3) AS wh_credits, ROUND(SUM(IFF(service_type = 'CORTEX_AGENTS', credits_used, 0)), 3) AS agent_credits, ROUND(SUM(IFF(service_type = 'SNOWPARK_CONTAINER_SERVICES', credits_used, 0)), 3) AS app_credits, (SELECT COUNT(*) FROM FFU.AI.EXTRACTIONS) AS extractions, (SELECT COUNT(*) FROM FFU.RAW.REPORTS WHERE gen_model LIKE 'claude%') AS generated FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY WHERE start_time >= '2026-10-03'"
$c = $cost[0]
$sim = (Q "SELECT * FROM FFU.EVAL.SIMULATED_IMPACT")[0]
$setaBlind = Q "SELECT * FROM FFU.EVAL.SETA_SUMMARY_BLIND ORDER BY method"
$setaNow = Q "SELECT * FROM FFU.EVAL.SETA_SUMMARY ORDER BY method"
$setaF = (Q "SELECT COUNT_IF(exp_loop AND sys_loop) AS tp, COUNT_IF(exp_loop AND sys_loop AND sys_type = exp_type) AS type_ok, COUNT_IF(exp_loop AND sys_loop AND sys_hedged = exp_hedged) AS hedged_ok, COUNT_IF(extraction_error) AS extraction_errors FROM FFU.EVAL.SETA_RESULTS")[0]
$procReports = [int]$c.EXTRACTIONS + [int]$c.GENERATED

$out = [ordered]@{
  protocol = 'Official Set C run only from the CTRL.DEMO_RESET(TRUE) state. All data synthetic except Set A (real, de-identified, hand-labelled). Impact numbers elsewhere are simulated.'
  set_c = [ordered]@{
    dataset = '700 synthetic index reports (2,000 patients); hidden answer key written before report text'
    run_at = $r.RUN_AT; label = $r.LABEL; state = $r.STATE_NOTE
    loop_status_accuracy = [ordered]@{ n = $r.N; correct = $r.CORRECT; accuracy = [math]::Round([double]$r.ACCURACY, 4) }
    false_green = $r.FALSE_GREEN; missed_loops = $r.MISSED_LOOPS; quote_verified_rate = [double]$r.QUOTE_VERIFIED_RATE }
  set_b = [ordered]@{
    dataset = '36 trap reports (38 findings); labels written first from docs/RULE_SHEET.md, text by claude-sonnet-4-5, extraction by claude-haiku-4-5; held out from tuning; labels drafted by the build agent, then reviewed against the rule sheet by team member Rojina Mallick (clinical laboratory experience as a phlebotomist and lab technician; 38 of 38 agreed, no changes; eval/setB/setB_review.csv); not a radiologist, rule sheet still needs radiologist sign-off'
    findings = $setb[0].FINDINGS; status_correct = $setb[0].STATUS_CORRECT; false_greens = $setb[0].FALSE_GREENS
    size = "$($setb[0].SIZE_OK)/$($setb[0].SIZE_N)"; tier = "$($setb[0].TIER_OK)/$($setb[0].TIER_N)"; pathway = "$($setb[0].PATHWAY_OK)/$($setb[0].PATHWAY_N)"
    quotes_verified = "$($setb[0].QUOTES_OK)/$($setb[0].QUOTES_N)"
    traps = @($traps | % { [ordered]@{ trap = $_.TRAP; passed = $_.PASSED } }) }
  set_a = [ordered]@{
    dataset = '120 real Indiana University chest X-ray reports (Open-i, CC BY-NC-ND 4.0), seed 2026 from 340 candidates; text never committed; labels hand-made by the builder (eval/setA/setA_labels.csv), 24 expect a loop'
    task = 'Loop detection (does the report open a follow-up loop); no follow-up events exist for real reports'
    blind = @($setaBlind | % { [ordered]@{ method = $_.METHOD; n = $_.N; tp = $_.TP; fp = $_.FP; fn = $_.FN; accuracy = $_.ACCURACY; ci95 = @($_.ACC_CI_LOW, $_.ACC_CI_HIGH); precision = $_.PRECISION; recall = $_.RECALL } })
    after_cxr_rule_fix = @($setaNow | % { [ordered]@{ method = $_.METHOD; n = $_.N; tp = $_.TP; fp = $_.FP; fn = $_.FN; accuracy = $_.ACCURACY; ci95 = @($_.ACC_CI_LOW, $_.ACC_CI_HIGH); precision = $_.PRECISION; recall = $_.RECALL } })
    system_fields_on_true_positives = [ordered]@{ tp = $setaF.TP; finding_type_ok = $setaF.TYPE_OK; hedged_ok = $setaF.HEDGED_OK; extraction_errors = $setaF.EXTRACTION_ERRORS }
    note = 'Blind run missed 7 of 24: real X-rays describe mediastinal contours and masses that extraction typed as OTHER with a CT recommendation. Rule fix: on an X-ray, any non-negated finding with a CT/PET/biopsy recommendation opens a loop. The fix was informed by Set A, so after_cxr_rule_fix is no longer blind; Sets B and C were re-run unchanged.' }
  baselines = @($base | % { [ordered]@{ method = $_.METHOD; set = $_.SET_NAME; n = $_.N; correct = $_.CORRECT; accuracy = $_.ACCURACY; ci95 = @($_.ACC_CI_LOW, $_.ACC_CI_HIGH); false_greens = $_.FALSE_GREENS; false_green_rate = $_.FALSE_GREEN_RATE; false_green_upper95 = $_.FALSE_GREEN_UPPER95_RULE_OF_3 } })
  baseline_notes = 'KEYWORD: recommend/follow-up opens a loop, any later event closes it. AI_ONLY: claude-haiku-4-5 picks the status from report text plus events (Set B all, Set C 96-report sample). False-green rate = wrong greens / loops that should not be green.'
  cost = [ordered]@{
    window = 'whole build day so far (generation + extraction + AI_FILTER + baselines + agent tests), METERING_HISTORY'
    ai_function_credits = $c.AI_CREDITS; warehouse_credits = $c.WH_CREDITS; agent_credits = $c.AGENT_CREDITS; app_container_credits = $c.APP_CREDITS
    ai_reports_processed = $procReports
    ai_credits_per_1000_reports_upper_bound = [math]::Round([double]$c.AI_CREDITS / $procReports * 1000, 2)
    note = 'Upper bound: includes report generation, baselines and tests, not only production extraction.' }
  latency = [ordered]@{ batch_822_reports_seconds = 17.2; per_report_in_batch_ms = 21; single_report_seconds = 3.5; source = 'INFORMATION_SCHEMA.QUERY_HISTORY for INSERT INTO AI.EXTRACTIONS' }
  simulated_impact = [ordered]@{
    label = 'SIMULATED - synthetic Set C hospital, not a clinical result (eval/03_simulated_impact.sql)'
    loops_due = $sim.LOOPS_DUE
    completion_hospital_only_view = [double]$sim.HOSPITAL_ONLY_COMPLETION
    completion_with_payer_share = [double]$sim.WITH_PAYER_SHARE_COMPLETION
    completion_with_worklist_recall_simulated = [double]$sim.WITH_RECALL_COMPLETION_SIMULATED
    published_baseline = 0.37; published_after_tracking = 0.74
    median_days_to_close_observed = [double]$sim.MEDIAN_DAYS_TO_CLOSE_OBSERVED
    median_days_to_close_with_recall_simulated = [double]$sim.MEDIAN_DAYS_TO_CLOSE_WITH_RECALL_SIMULATED
    assumption = 'Recall recovers 59% of not-done loops, derived from Nodule Net (37% to 74%); recalled loops close 30 days after the due date.' }
  failure_cases = @(
    [ordered]@{ id = 'R00519 (Set C), RA9 (Set A)'; what = 'Extraction JSON failed schema validation on every retry, so no loop opened (the 1 missed Set C loop).'; why = 'Model output did not match the required schema for one finding.'; mitigation = 'CORE.EXTRACTION_ERRORS review queue shown in the app; never silently dropped.' },
    [ordered]@{ id = 'R00001 (Set C)'; what = 'Index chest X-ray says mass-like opacity; follow-up CT says 8 mm nodule stable. AI_FILTER did not link them, so the loop stayed RED (needs review) instead of GREEN.'; why = 'Different wording for the same finding across modalities.'; mitigation = 'Safe direction (never a false green); shown as needs review. 5 of 700 Set C loops.' },
    [ordered]@{ id = 'Priority saturation'; what = 'Elapsed share is capped at 200% of the window, so long-overdue tier-1 loops all score 3110.'; why = 'Design cap to keep tier bands from overlapping.'; mitigation = 'Worklist breaks ties by days overdue; documented in the rule sheet.' })
}
$out | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'eval/metrics.json') -Encoding utf8
Write-Host "Wrote eval/metrics.json (official run $($r.LABEL), cost per 1,000 <= $($out.cost.ai_credits_per_1000_reports_upper_bound) AI credits)"
