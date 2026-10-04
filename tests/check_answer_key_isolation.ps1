# Guard: only the data generators and the EVAL layer may read KEY.ANSWER_KEY.
# Run: powershell -File tests/check_answer_key_isolation.ps1   (exit 1 on violation)
$allowed = @('sql\02_patients_answer_key.sql', 'sql\03_generate_reports.sql', 'sql\04_hospital_events.sql')
$root = Split-Path $PSScriptRoot -Parent
$bad = Get-ChildItem $root -Recurse -File -Include *.sql, *.py, *.yaml, *.yml |
  Where-Object { $_.FullName -notmatch '\\(eval|tests)\\' } |
  Where-Object { $rel = $_.FullName.Substring($root.Length + 1); $allowed -notcontains $rel } |
  Select-String -Pattern 'ANSWER_KEY'
# Database side: no view outside EVAL may reference it.
$db = snow sql -c hospital --format json -q "SELECT table_schema||'.'||table_name AS v FROM FFU.INFORMATION_SCHEMA.VIEWS WHERE view_definition ILIKE '%ANSWER_KEY%' AND table_schema <> 'EVAL'" 2>$null | ConvertFrom-Json
if ($bad -or $db) { $bad; $db; Write-Host 'FAIL: answer key referenced outside EVAL'; exit 1 }
Write-Host 'PASS: answer key isolated'
