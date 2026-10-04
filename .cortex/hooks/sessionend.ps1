# SessionEnd: append a one-line session summary to docs/coco-log.md (never blocks).
try { $evt = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { $evt = $null }
$root = if ($env:CORTEX_PROJECT_DIR) { $env:CORTEX_PROJECT_DIR } elseif ($evt) { $evt.cwd } else { (Get-Location).Path }
$log = Join-Path $root 'docs/coco-log.md'
if (-not (Test-Path $log)) { Set-Content $log "# CoCo session log`n`nOne line per CoCo session (appended by the SessionEnd hook).`n" -Encoding utf8 }
$last = (git -C $root log -1 --format='%h %s' 2>$null)
$changed = ((git -C $root status --short 2>$null) | Measure-Object).Count
Add-Content $log ("- {0:yyyy-MM-dd HH:mm} session {1}: last commit '{2}', {3} uncommitted file(s)." -f (Get-Date), $evt.session_id, $last, $changed) -Encoding utf8
exit 0
