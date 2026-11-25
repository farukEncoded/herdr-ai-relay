# Keeps the panel's usage numbers live when no relay is running (D-030).
# Every 10 minutes (Windows task 'AI relay usage refresh', set up with -Schedule) it writes, like a running relay does:
#   usage/plan.json       Claude and Codex plan use (5-hour and weekly windows)
#   usage/outlook.json    the quota planner's view: reserve, safe-until, Antigravity outages, OpenRouter budget
#   usage/openrouter-models.json (+ the daily price line)   when older than 6 hours
# It uses the relay's own functions (read from ai-relay.ps1 next to it), so both always agree. Quiet and quick:
# no network call unless the OpenRouter data is due, and never more than ~1 minute.
param([switch]$Schedule, [switch]$Unschedule)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$task = 'AI relay usage refresh'

if ($Unschedule) { & schtasks.exe /Delete /F /TN $task 2>$null | Out-Null; Write-Host "Removed the task '$task'."; exit 0 }
if ($Schedule) {
  # conhost --headless: no console window flashing up every 10 minutes.
  $ps = Join-Path $PSHOME 'powershell.exe'
  $tr = "conhost.exe --headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  & schtasks.exe /Create /F /SC MINUTE /MO 10 /TN $task /TR $tr | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'schtasks could not create the task.' }
  $t = Get-ScheduledTask -TaskName $task
  $t.Settings.StartWhenAvailable = $true; $t.Settings.DisallowStartIfOnBatteries = $false; $t.Settings.StopIfGoingOnBatteries = $false
  $t.Settings.ExecutionTimeLimit = 'PT5M'; $t.Settings.MultipleInstances = 'IgnoreNew'
  Set-ScheduledTask -TaskName $task -Settings $t.Settings | Out-Null
  Write-Host "Task '$task' set: every 10 minutes, hidden."
  exit 0
}

$relay = Join-Path $root 'ai-relay.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($relay, [ref]$null, [ref]$null)
$code = ($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($code))

$script:defaults = $null
$dp = Join-Path $root 'relay-defaults.json'
if (Test-Path $dp) { $script:defaults = Get-Content $dp -Raw -Encoding UTF8 | ConvertFrom-Json }
$script:fb = Default-Of 'fallback' $null
$script:oc = Default-Of 'opencode' $null
$script:fbWait = [int](Fb-Of 'waitMinutes' 20); $script:fbMaxWait = [int](Fb-Of 'maxWaitMinutes' 30)
$script:usageDir = Join-Path $root 'usage'
New-Item -ItemType Directory -Path $script:usageDir -Force | Out-Null
$script:quotaFile = Join-Path $script:usageDir 'quota.json'
$script:judgeRole = 'reviewer'
$Folder = $root
$utf8 = New-Object System.Text.UTF8Encoding($false)

$script:usage = Get-PlanUsage; $script:usageAt = Get-Date
[IO.File]::WriteAllText((Join-Path $script:usageDir 'plan.json'), ($script:usage | ConvertTo-Json -Compress -Depth 5), $utf8)
if (OR-Key) { try { [void](Get-ORModels) } catch {} }   # refreshes the cache (and the daily prices) only when due
$o = Get-Outlook
[IO.File]::WriteAllText((Join-Path $script:usageDir 'outlook.json'), ($o | ConvertTo-Json -Compress -Depth 5), $utf8)
