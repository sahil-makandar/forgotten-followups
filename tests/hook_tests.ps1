# Tests for .cortex/hooks/pretooluse.ps1. Run: powershell -NoProfile -File tests/hook_tests.ps1   (prints PASS/FAIL per case)
$hook = Join-Path (Split-Path $PSScriptRoot -Parent) '.cortex/hooks/pretooluse.ps1'
$d = [char]45   # hyphen, so this file itself never contains a PHI-like literal
$ssn = '123' + $d + '45' + $d + '6789'
$aadhaar = '2345' + ' ' + '6789' + ' ' + '0123'
$cases = @(
  @{ name = 'block SSN in SQL';                 tool = 'sql_execute'; input = @{ sql = "INSERT INTO t VALUES ('$ssn')" }; expect = 2 },
  @{ name = 'block Aadhaar in file write';      tool = 'write';       input = @{ file_path = 'x.csv'; content = "id,$aadhaar" }; expect = 2 },
  @{ name = 'block DROP secure view';           tool = 'sql_execute'; input = @{ sql = 'DROP VIEW FFU.SEC.LOOPS_V' }; expect = 2 },
  @{ name = 'block unset masking policy';       tool = 'bash';        input = @{ command = 'snow sql -c payer -q "ALTER TABLE t MODIFY COLUMN c UNSET MASKING POLICY"' }; expect = 2 },
  @{ name = 'block drop row access policy';     tool = 'sql_execute'; input = @{ sql = 'DROP ROW ACCESS POLICY PAYER_DB.GOV.PARTNER_ROWS' }; expect = 2 },
  @{ name = 'block TRUNCATE curated';           tool = 'sql_execute'; input = @{ sql = 'TRUNCATE TABLE FFU.RAW.REPORTS' }; expect = 2 },
  @{ name = 'block CREATE OR REPLACE curated';  tool = 'sql_execute'; input = @{ sql = 'CREATE OR REPLACE TABLE KEY.ANSWER_KEY AS SELECT 1' }; expect = 2 },
  @{ name = 'block drop database';              tool = 'bash';        input = @{ command = 'snow sql -q "DROP DATABASE FFU"' }; expect = 2 },
  @{ name = 'allow normal select';              tool = 'sql_execute'; input = @{ sql = 'SELECT * FROM FFU.CORE.WORKLIST LIMIT 5' }; expect = 0 },
  @{ name = 'allow derived DT rebuild';         tool = 'sql_execute'; input = @{ sql = 'CREATE OR REPLACE DYNAMIC TABLE CORE.LOOPS TARGET_LAG = DOWNSTREAM AS SELECT 1' }; expect = 0 },
  @{ name = 'allow dates and query ids';        tool = 'bash';        input = @{ command = 'echo 2026-10-04 01c77f54-0002-26f8-000f-c78e0005b36e 1791091358351' }; expect = 0 },
  @{ name = 'allow procedure call';             tool = 'sql_execute'; input = @{ sql = "CALL FFU.CORE.AUDIT_LOOP('P09901')" }; expect = 0 }
)
$fail = 0
foreach ($c in $cases) {
  $json = @{ session_id = 't'; cwd = (Get-Location).Path; hook_event_name = 'PreToolUse'; tool_name = $c.tool; tool_input = $c.input } | ConvertTo-Json -Depth 5 -Compress
  $json | powershell -NoProfile -ExecutionPolicy Bypass -File $hook *> $null
  $ok = ($LASTEXITCODE -eq $c.expect); if (-not $ok) { $fail++ }
  '{0}  {1} (exit {2}, expected {3})' -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $c.name, $LASTEXITCODE, $c.expect
}
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
