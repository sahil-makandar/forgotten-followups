# Red-team role checks: the judge and analyst roles must see masked data only and must not approve letters,
# change loops or read raw tables. Runs each statement as the role (secondary roles off) and checks the outcome.
# Run: powershell -NoProfile -File tests/red_team_roles.ps1   (needs a connection that can USE ROLE FFU_JUDGE / FFU_ANALYST)
$env:PYTHONIOENCODING = 'utf-8'
$fail = 0

function Run-As($role, $sql) {
    $wh = if ($role -eq 'FFU_JUDGE') { 'FFU_APP_WH' } else { 'COMPUTE_WH' }
    # --role is not reliable with a named connection, so switch inside the session and fail fast if it did not take.
    $out = snow sql -c hospital --format json -q "USE ROLE $role; USE SECONDARY ROLES NONE; USE WAREHOUSE $wh; SELECT IFF(CURRENT_ROLE() = '$role' AND NOT IS_ROLE_IN_SESSION('ACCOUNTADMIN'), 'ROLE_OK', 'ROLE_WRONG') AS guard; $sql" 2>&1 | Out-String
    if ($out -notmatch 'ROLE_OK') { throw "Could not switch to $role; refusing to run checks as another role." }
    return $out
}

# expect: DENY (an error), MASKED (rows come back but ids/quotes are masked)
$cases = @(
    @{ name = 'read raw reports';            sql = 'SELECT COUNT(*) FROM FFU.RAW.REPORTS';                                expect = 'DENY' },
    @{ name = 'read unmasked loops (core)';  sql = 'SELECT patient_id FROM FFU.CORE.LOOP_STATUS LIMIT 1';                 expect = 'DENY' },
    @{ name = 'read answer key';             sql = 'SELECT COUNT(*) FROM FFU.KEY.ANSWER_KEY';                             expect = 'DENY' },
    @{ name = 'read payer claims / SSN';     sql = 'SELECT member_ssn_last4 FROM PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS LIMIT 1'; expect = 'DENY' },
    @{ name = 'approve a letter';            sql = "CALL FFU.APP.APPROVE_DRAFT('x', 'Judge')";                           expect = 'DENY' },
    @{ name = 'insert into approvals';       sql = "INSERT INTO FFU.APP.APPROVALS (loop_id, kind) VALUES ('L-X', 'PATIENT')"; expect = 'DENY' },
    @{ name = 'change a loop (update)';      sql = "UPDATE FFU.CORE.LOOP_STATUS SET status = 'GREEN' WHERE loop_id = 'L-RSEED902-0'"; expect = 'DENY' },
    @{ name = 'move the demo clock';         sql = "CALL FFU.CTRL.SET_SIM_DATE('2030-01-01')";                           expect = 'DENY' },
    @{ name = 'reset the demo';              sql = 'CALL FFU.CTRL.DEMO_RESET(TRUE)';                                      expect = 'DENY' },
    @{ name = 'ingest a report';             sql = "CALL FFU.CORE.INGEST_REPORT('RX','P09901','2026-10-04','CT','71250','X','x')"; expect = 'DENY' },
    @{ name = 'secure view is masked';       sql = "SELECT patient_id, quote FROM FFU.SEC.LOOPS_V WHERE status = 'RED' LIMIT 3"; expect = 'MASKED' },
    @{ name = 'copilot view is masked';      sql = "SELECT patient_id, quote FROM FFU.SEC.LOOPS_COPILOT_V WHERE status = 'RED' LIMIT 3"; expect = 'MASKED' }
)

foreach ($role in 'FFU_JUDGE', 'FFU_ANALYST') {
    foreach ($c in $cases) {
        $out = Run-As $role $c.sql
        $denied = $out -match 'does not exist or not authorized|Insufficient privileges|not authorized|SQL access control error|Unknown user-defined function|does not exist'
        if ($c.expect -eq 'DENY') { $ok = $denied }
        else {
            # Masked: no real patient id (P + 5 digits) and no readable quote text.
            $ok = (-not $denied) -and ($out -notmatch '"PATIENT_ID"\s*:\s*"P\d{5}"') -and ($out -match '"QUOTE"\s*:\s*"\*\*\*"')
        }
        if (-not $ok) { $fail++ }
        Write-Host ("{0}  {1,-12} {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $role, $c.name)
    }
}
if ($fail) { Write-Host "$fail role check(s) FAILED"; exit 1 } else { Write-Host 'ALL PASS' }
