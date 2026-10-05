<#
Rebuild Forgotten Follow-ups from scratch: runs the sql/ runbook in order for both connections.

  .\setup.ps1 -DryRun                      # print the steps only
  .\setup.ps1                              # run them (stops at the first failure)
  .\setup.ps1 -Hospital hospital -Payer payer

Before a real run, edit the consumer locator in sql/payer/01_payer.sql (ALTER SHARE) and the provider
org.account in sql/05_mount_share.sql. sql/15 needs the judge user created by hand (no password in files);
sql/16 needs the Marketplace listing mounted. Needs Snowflake CLI 3.14+.
#>
param(
    [switch]$DryRun,
    [string]$Hospital = 'hospital',
    [string]$Payer = 'payer'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$env:PYTHONIOENCODING = 'utf-8'

# Each step: connection, kind (file | query | deploy), target.
$steps = @(
    @($Hospital, 'file',  'sql/01_setup.sql'),
    @($Hospital, 'file',  'sql/02_patients_answer_key.sql'),
    @($Hospital, 'file',  'sql/03_generate_reports.sql'),        # AI generation (about 850 calls)
    @($Hospital, 'file',  'sql/04_hospital_events.sql'),
    @($Payer,    'file',  'sql/payer/01_payer.sql'),
    @($Payer,    'file',  'sql/payer/02_payer_events.sql'),
    @($Hospital, 'file',  'sql/05_mount_share.sql'),
    @($Hospital, 'file',  'sql/06_extraction.sql'),
    @($Hospital, 'file',  'sql/07_rules.sql'),
    @($Hospital, 'file',  'sql/08_automation.sql'),
    @($Hospital, 'file',  'sql/09_skill_procs.sql'),
    @($Hospital, 'file',  'sql/10_demo_seed.sql'),
    @($Hospital, 'file',  'sql/11_access_control.sql'),
    @($Hospital, 'file',  'sql/12_copilot.sql'),
    @($Hospital, 'file',  'agent/create_agent.sql'),
    @($Hospital, 'file',  'sql/14_outside_pdf.sql'),
    @($Hospital, 'deploy', 'app'),
    @($Hospital, 'file',  'sql/13_app_access.sql'),
    @($Hospital, 'file',  'sql/15_judge_access.sql'),
    @($Hospital, 'file',  'sql/16_marketplace_context.sql'),
    @($Hospital, 'file',  'tests/thyroid/01_seed.sql'),
    @($Hospital, 'query', 'CALL FFU.CORE.RUN_PIPELINE()'),
    @($Hospital, 'file',  'eval/01_run_eval.sql'),
    @($Hospital, 'query', 'CALL FFU.CTRL.DEMO_RESET(TRUE)')
)

$i = 0
foreach ($s in $steps) {
    $i++
    $conn, $kind, $target = $s
    $label = switch ($kind) {
        'file'   { "snow sql -c $conn -f $target" }
        'query'  { "snow sql -c $conn -q `"$target`"" }
        'deploy' { "snow streamlit deploy --replace -c $conn  (in $target/)" }
    }
    Write-Host ("[{0,2}/{1}] {2}" -f $i, $steps.Count, $label)
    if ($DryRun) { continue }

    switch ($kind) {
        'file'   { snow sql -c $conn -f $target | Out-Host }
        'query'  { snow sql -c $conn -q $target | Out-Host }
        'deploy' { Push-Location $target; try { snow streamlit deploy --replace -c $conn | Out-Host } finally { Pop-Location } }
    }
    if ($LASTEXITCODE -ne 0) { throw "Step $i failed: $label" }
}

if ($DryRun) { Write-Host "Dry run: nothing was executed." } else { Write-Host "Done. Run the tests listed in README.md." }
