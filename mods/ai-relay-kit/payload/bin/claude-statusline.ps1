# claude-statusline.ps1 - status line for Claude sessions started by ai-relay.ps1 (claude --settings).
# Claude Code pipes its status JSON to stdin; we save the usage numbers for the Herdr AI Project panel
# and print one short line: model | effort | plan use | context.
#   usage/claude.json              latest plan limits (5-hour / weekly), from any relay Claude session
#   usage/sessions/<session>.json  this session's tokens, cost and context use
$ErrorActionPreference = 'SilentlyContinue'
$raw = [Console]::In.ReadToEnd()
try { $s = $raw | ConvertFrom-Json } catch { 'Claude'; exit 0 }
$dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'usage'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$now = (Get-Date).ToString('o')
if ($s.rate_limits) {
  $o = [ordered]@{ at = $now; rate_limits = $s.rate_limits; model = $s.model.display_name }
  [IO.File]::WriteAllText((Join-Path $dir 'claude.json'), ($o | ConvertTo-Json -Compress -Depth 5), $utf8)
}
if ($s.session_id) {
  $cw = $s.context_window
  $o = [ordered]@{
    at = $now; model = $s.model.display_name; effort = $s.effort.level
    tokens = [int64]$cw.total_input_tokens + [int64]$cw.total_output_tokens
    cost = $s.cost.total_cost_usd; context = $cw.used_percentage
  }
  New-Item -ItemType Directory -Path (Join-Path $dir 'sessions') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $dir "sessions\$($s.session_id).json"), ($o | ConvertTo-Json -Compress), $utf8)
}
$parts = @($s.model.display_name)
if ($s.effort.level) { $parts += $s.effort.level }
if ($s.rate_limits.five_hour) { $parts += "5h $([math]::Round($s.rate_limits.five_hour.used_percentage))%" }
if ($s.rate_limits.seven_day) { $parts += "week $([math]::Round($s.rate_limits.seven_day.used_percentage))%" }
if ($null -ne $s.context_window.used_percentage) { $parts += "context $($s.context_window.used_percentage)%" }
$parts -join ' | '
