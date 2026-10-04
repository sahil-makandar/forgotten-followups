# Writes eval/metrics.json from the latest OFFICIAL eval run (taken from the DEMO_RESET(TRUE) state).
# Usage: powershell -NoProfile -File eval/export_metrics.ps1
$root = Split-Path $PSScriptRoot -Parent
$q = "SELECT run_at::STRING AS run_at, label, state_note, n, correct, accuracy, false_green, false_green_upper95, missed_loops, quote_verified_rate " +
     "FROM FFU.EVAL.RUNS WHERE official ORDER BY run_at DESC LIMIT 1"
$rows = snow sql -c hospital --format json -q $q 2>$null | ConvertFrom-Json
if (-not $rows) { Write-Host 'No official run found. Run CALL FFU.CTRL.DEMO_RESET(TRUE); then CALL FFU.EVAL.RUN_EVAL(''official'');'; exit 1 }
$r = $rows[0]
$out = [ordered]@{
  protocol = 'Official runs only from the CTRL.DEMO_RESET(TRUE) state: sim_date 2026-10-04, no demo reports or claims, no live-compiled rules.'
  dataset = 'Set C: synthetic, 700 index reports from 2,000 patients, hidden answer key written before report text'
  run_at = $r.RUN_AT; label = $r.LABEL; state = $r.STATE_NOTE
  loop_status = [ordered]@{ n = $r.N; correct = $r.CORRECT; accuracy = [math]::Round([double]$r.ACCURACY, 4) }
  safety = [ordered]@{ false_green = $r.FALSE_GREEN; false_green_upper95 = [math]::Round([double]$r.FALSE_GREEN_UPPER95, 4) }
  missed_loops = $r.MISSED_LOOPS
  quote_verified_rate = [double]$r.QUOTE_VERIFIED_RATE
}
$out | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'eval/metrics.json') -Encoding utf8
Write-Host "Wrote eval/metrics.json from run $($r.LABEL) at $($r.RUN_AT)"
