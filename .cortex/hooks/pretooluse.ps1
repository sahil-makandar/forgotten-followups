# PreToolUse guard for CoCo (exit 2 = block). Reads the tool call as JSON on stdin.
# Blocks: (1) PHI-like numbers (SSN, Aadhaar) in commands, SQL or files being written;
#         (2) dropping/altering the access-control secure views or governance policies;
#         (3) destructive DDL on curated tables (RAW, KEY, AI caches, SEC).
# Derived Dynamic Tables in CORE may be rebuilt. For an intentional full rebuild set FFU_ALLOW_DESTRUCTIVE=1.
$ErrorActionPreference = 'Stop'
try { $evt = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }   # unreadable input: do not block
$tool = [string]$evt.tool_name
# Scan the raw string values (not the JSON text: JSON escapes like \u0027 would glue digits onto numbers).
$text = ($evt.tool_input.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join "`n"

# For `snow sql -f <file>.sql`, also scan the SQL file that will run.
$cmd = [string]$evt.tool_input.command
if ($cmd -match '-f\s+"?([^\s"]+\.sql)') {
  $f = $Matches[1]; $root = if ($env:CORTEX_PROJECT_DIR) { $env:CORTEX_PROJECT_DIR } else { $evt.cwd }
  $p = if ([IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $root $f }
  if (Test-Path $p) { $text += "`n" + (Get-Content $p -Raw) }
}

function Block($why) {
  @{ decision = 'block'; reason = "FFU guard: $why" } | ConvertTo-Json -Compress
  [Console]::Error.WriteLine("FFU guard blocked $tool : $why")
  exit 2
}

# (1) PHI-like identifiers anywhere (all tools, including file writes).
if ($text -match '\b\d{3}-\d{2}-\d{4}\b') { Block 'SSN-like number (ddd-dd-dddd). Use synthetic HASH-generated values at runtime.' }
if ($text -match '\b[2-9]\d{3}[ -]?\d{4}[ -]?\d{4}\b') { Block 'Aadhaar-like 12-digit number. Never store national IDs.' }

# Only SQL-capable tools for the DDL checks.
if ($tool -notmatch '^(bash|sql_execute|.*sql.*)$') { exit 0 }
$sql = $text -replace '\s+', ' '

# (2) Access control: never drop the secure views or the payer policies.
if ($sql -match '(?i)\bDROP\s+(SECURE\s+)?VIEW\s+(IF\s+EXISTS\s+)?("?FFU"?\.)?"?SEC"?\.') { Block 'dropping an access-control secure view in FFU.SEC.' }
if ($sql -match '(?i)\b(DROP|ALTER)\s+(MASKING|ROW\s+ACCESS)\s+POLICY') { Block 'dropping or altering a masking / row access policy.' }
if ($sql -match '(?i)\b(UNSET\s+MASKING\s+POLICY|DROP\s+ROW\s+ACCESS\s+POLICY|DROP\s+ALL\s+ROW\s+ACCESS)') { Block 'removing a policy from the shared table.' }

# (3) Destructive DDL on curated data.
if ($env:FFU_ALLOW_DESTRUCTIVE -ne '1') {
  $curated = '("?FFU"?\.)?"?(RAW|KEY|AI|SEC)"?\.'
  if ($sql -match "(?i)\b(DROP|TRUNCATE)\s+(TABLE\s+)?(IF\s+EXISTS\s+)?$curated") { Block 'DROP/TRUNCATE on a curated table (RAW, KEY, AI, SEC). Set FFU_ALLOW_DESTRUCTIVE=1 for an intentional rebuild.' }
  if ($sql -match "(?i)\bCREATE\s+OR\s+REPLACE\s+(TRANSIENT\s+)?TABLE\s+$curated") { Block 'CREATE OR REPLACE TABLE on curated data would wipe it. Set FFU_ALLOW_DESTRUCTIVE=1 for an intentional rebuild.' }
  if ($sql -match '(?i)\bDROP\s+(DATABASE|SCHEMA)\s+(IF\s+EXISTS\s+)?"?FFU\b') { Block 'dropping the FFU database or a schema.' }
}
exit 0

