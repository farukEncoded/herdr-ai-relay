# Model report for the AI relay (D-028).
# Reads usage/model-stats.jsonl (one line per finished relay stage, every agent), usage/openrouter-prices.jsonl
# (daily OpenRouter prices) and usage/openrouter-models.json (the live model list), and writes:
#   usage/model-report.html   charts and tables: pass rate, minutes, tokens and cost per agent/model/role,
#                             quota trouble, OpenRouter price history, suggestions
#   usage/model-report.json   the numbers and suggestions (the relay prints a one-line note from it at start)
# -Apply makes only the safe changes to relay-defaults.json "opencode.models" (backup kept next to it):
#   models OpenRouter no longer lists or that lost tool calling are removed; a model clearly worse than the others
#   in its role (8+ runs, pass rate 20+ points below the role's) moves to the end of that chain.
# A weekly Windows task 'AI relay model report' runs it without -Apply (tools/model-report.ps1 -Schedule sets it up).
param([int]$Days = 30, [switch]$Apply, [switch]$Schedule, [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$usage = Join-Path $root 'usage'
$defaultsPath = Join-Path $root 'relay-defaults.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)

if ($Schedule) {
  $ps = Join-Path $PSHOME 'powershell.exe'
  $tr = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Quiet"
  & schtasks.exe /Create /F /SC WEEKLY /D MON /ST 09:00 /TN 'AI relay model report' /TR $tr | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'schtasks could not create the weekly task.' }
  # Catch up after the PC was off at that time, and run on battery too.
  $t = Get-ScheduledTask -TaskName 'AI relay model report'
  $t.Settings.StartWhenAvailable = $true; $t.Settings.DisallowStartIfOnBatteries = $false; $t.Settings.StopIfGoingOnBatteries = $false
  Set-ScheduledTask -TaskName 'AI relay model report' -Settings $t.Settings | Out-Null
  Write-Host "Weekly task 'AI relay model report' set: Mondays 09:00 (or at the next start if the PC was off)."
  exit 0
}

# The model scout (D-032) first, when Node and an OpenRouter key are there: fresh grades and proposals for this report
# (it changes only the tester list, only on measured evidence; other roles stay proposals).
$scoutJs = Join-Path $PSScriptRoot 'model-scout.mjs'
if ((Test-Path $scoutJs) -and (Get-Command node -ErrorAction SilentlyContinue) -and
    ($env:OPENROUTER_API_KEY -or [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User'))) {
  try { & node $scoutJs --apply 2>&1 | Out-Null } catch {}
}

function Read-Lines([string]$p) {
  if (-not (Test-Path $p)) { return @() }
  return @([IO.File]::ReadAllLines($p, $utf8) | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
}
$since = (Get-Date).AddDays(-$Days)
$rows = @(Read-Lines (Join-Path $usage 'model-stats.jsonl') | Where-Object { $_.at -and [datetime]$_.at -ge $since })
$prices = @(Read-Lines (Join-Path $usage 'openrouter-prices.jsonl'))
$liveFile = Join-Path $usage 'openrouter-models.json'
$live = @{}
if (Test-Path $liveFile) { foreach ($m in @((Get-Content $liveFile -Raw -Encoding UTF8 | ConvertFrom-Json).models)) { $live[[string]$m.id] = $m } }
$defs = Get-Content $defaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$chains = $defs.opencode.models

# ---------- outcomes: a stage "passed" when the judge of its relay round approved ----------
$verdictOf = @{}
foreach ($r in $rows) { if ($r.judge -and $r.verdict) { $verdictOf["$($r.relay)|$($r.task)|$($r.round)"] = [string]$r.verdict } }
function Model-Label($r) { if ($r.model -and $r.model -ne 'default') { [string]$r.model } else { "$($r.agent) default" } }
$groups = $rows | Group-Object { "$($_.role)|$($_.agent)|$(Model-Label $_)" }
$table = foreach ($g in $groups) {
  $p = $g.Name -split '\|', 3
  $judged = @($g.Group | Where-Object { -not $_.judge -and $verdictOf.ContainsKey("$($_.relay)|$($_.task)|$($_.round)") })
  $passed = @($judged | Where-Object { $verdictOf["$($_.relay)|$($_.task)|$($_.round)"] -eq 'APPROVED' })
  $own = @($g.Group | Where-Object { $_.judge -and $_.verdict })
  $costs = @($g.Group | Where-Object { $null -ne $_.cost } | ForEach-Object { [double]$_.cost })
  $toks = @($g.Group | Where-Object { $_.tokens } | ForEach-Object { [double]$_.tokens })
  [pscustomobject]@{
    role = $p[0]; agent = $p[1]; model = $p[2]; runs = $g.Count
    done = [math]::Round(100 * @($g.Group | Where-Object { $_.state -eq 'done' }).Count / $g.Count)
    judged = $(if ($own.Count) { $own.Count } else { $judged.Count })
    pass = $(if ($own.Count) { [math]::Round(100 * @($own | Where-Object { $_.verdict -eq 'APPROVED' }).Count / $own.Count) }
             elseif ($judged.Count) { [math]::Round(100 * $passed.Count / $judged.Count) } else { $null })
    passKind = $(if ($own.Count) { 'approves' } else { 'round approved' })
    minutes = [math]::Round((@($g.Group | ForEach-Object { [double]$_.minutes }) | Measure-Object -Average).Average, 1)
    tokens = $(if ($toks.Count) { [math]::Round(($toks | Measure-Object -Average).Average) } else { $null })
    cost = $(if ($costs.Count) { [math]::Round(($costs | Measure-Object -Average).Average, 4) } else { $null })
    costTotal = $(if ($costs.Count) { [math]::Round(($costs | Measure-Object -Sum).Sum, 4) } else { $null })
    switches = (@($g.Group | ForEach-Object { [int]$_.switches }) | Measure-Object -Sum).Sum
    # Protocol kept (D-030): a LOG line, a proper signature and its own commit (stages recorded with these fields).
    protocol = $(
      $q = @($g.Group | Where-Object { $null -ne $_.compliant })
      if ($q.Count) { [math]::Round(100 * @($q | Where-Object { $_.compliant }).Count / $q.Count) } else { $null })
    # Rounds this agent's work needed before approval (executor-like roles): fix rounds per approved relay/task.
    rounds = $(
      $done = @($g.Group | Where-Object { -not $_.judge } | Group-Object { "$($_.relay)|$($_.task)" } |
                Where-Object { $k = $_.Name; @($rows | Where-Object { $_.judge -and $_.verdict -eq 'APPROVED' -and "$($_.relay)|$($_.task)" -eq $k }).Count })
      if ($done.Count) { [math]::Round((@($done | ForEach-Object { ($_.Group | Measure-Object round -Maximum).Maximum }) | Measure-Object -Average).Average, 1) } else { $null })
  }
}
$table = @($table | Sort-Object role, @{ e = { if ($null -eq $_.pass) { -1 } else { $_.pass } }; Descending = $true }, cost)

# ---------- suggestions ----------
$sugg = New-Object System.Collections.ArrayList
$applyOps = New-Object System.Collections.ArrayList
if ($chains) {
  foreach ($prop in $chains.PSObject.Properties) {
    foreach ($id in @($prop.Value)) {
      if ($live.Count -and -not $live.ContainsKey($id)) {
        [void]$sugg.Add("Remove $id from the OpenCode $($prop.Name) list: OpenRouter doesn't list it any more.")
        [void]$applyOps.Add(@{ op = 'remove'; role = $prop.Name; id = $id })
      } elseif ($live.Count -and -not $live[$id].tools) {
        [void]$sugg.Add("Remove $id from the OpenCode $($prop.Name) list: it lost tool calling.")
        [void]$applyOps.Add(@{ op = 'remove'; role = $prop.Name; id = $id })
      } elseif ($live.Count -and $id -notlike '*:free' -and $live.ContainsKey("$id`:free")) {
        [void]$sugg.Add("Good news: $id has a free variant now; the relay already uses it where free models are allowed.")
      }
    }
  }
}
foreach ($role in @($table | Select-Object -ExpandProperty role -Unique)) {
  $rr = @($table | Where-Object { $_.role -eq $role -and $null -ne $_.pass -and $_.judged -ge 5 })
  if ($rr.Count -lt 2) { continue }
  $avg = ($rr | Measure-Object pass -Average).Average
  foreach ($x in $rr) {
    if ($x.pass -le $avg - 20) {
      # Suggested from 5 judged runs; -Apply moves it only from 8 (fewer runs can be bad luck).
      $auto = ($x.judged -ge 8 -and $x.agent -eq 'opencode')
      [void]$sugg.Add("$($x.model) does clearly worse as $role ($($x.pass) % vs $([math]::Round($avg)) % average, $($x.judged) runs): move it down" +
        $(if ($auto) { '.' } elseif ($x.agent -eq 'opencode') { ' (-Apply does this from 8 runs).' } else { " (it's $($x.agent)'s model: change it in the role's agent or model)." }))
      if ($auto) { [void]$applyOps.Add(@{ op = 'demote'; role = $role; id = $x.model }) }
    }
  }
  $best = $rr | Sort-Object pass -Descending | Select-Object -First 1
  $cheaper = $rr | Where-Object { $_ -ne $best -and $null -ne $_.cost -and $null -ne $best.cost -and $_.cost -lt $best.cost * 0.5 -and $_.pass -ge $best.pass - 5 } | Select-Object -First 1
  if ($cheaper) { [void]$sugg.Add("$($cheaper.model) does about as well as $($best.model) as $role ($($cheaper.pass) % vs $($best.pass) %) for less than half the cost: consider putting it first.") }
}
foreach ($x in @($table | Where-Object { $_.runs -ge 5 -and $null -ne $_.protocol -and $_.protocol -lt 60 })) {
  [void]$sugg.Add("$($x.model) often skips protocol steps as $($x.role) (LOG line, signature or commit kept in only $($x.protocol) % of $($x.runs) runs): the next agent may miss its handoff.")
}
foreach ($x in @($table | Where-Object { $_.runs -ge 4 -and $_.switches -ge [math]::Ceiling($_.runs / 2) })) {
  [void]$sugg.Add("$(if ($x.model -like "$($x.agent)*") { $x.model } else { "$($x.agent) $($x.model)" }) ran out of quota in many $($x.role) stages ($($x.switches) switches in $($x.runs) runs): give that role another first choice.")
}
# Price moves of the chain models over the last 7 days.
$byId = $prices | Group-Object id
foreach ($g in $byId) {
  $s = @($g.Group | Sort-Object day)
  if ($s.Count -lt 2) { continue }
  $old = $s | Where-Object { [datetime]$_.day -le (Get-Date).AddDays(-7) } | Select-Object -Last 1
  if (-not $old) { $old = $s[0] }
  $new = $s[-1]
  if ([double]$old.outPrice -gt 0 -and [math]::Abs([double]$new.outPrice - [double]$old.outPrice) / [double]$old.outPrice -ge 0.25) {
    [void]$sugg.Add("$($g.Name) output price moved from `$$($old.outPrice) to `$$($new.outPrice) per 1M tokens since $($old.day).")
  }
}
# Free tool-calling models nobody uses yet (largest context first): candidates to try as tester.
$inChains = @{}; if ($chains) { foreach ($p in $chains.PSObject.Properties) { foreach ($id in @($p.Value)) { $inChains[$id] = $true; $inChains["$id`:free"] = $true } } }
$cands = @($live.Values | Where-Object { $_.id -like '*:free' -and $_.tools -and -not $inChains.ContainsKey($_.id) -and [int64]$_.ctx -ge 200000 } | Sort-Object { -[int64]$_.ctx } | Select-Object -First 5)
if ($cands) { [void]$sugg.Add("Free models with tool calling to try as tester: " + (($cands | ForEach-Object { $_.id }) -join ', ') + '.') }
# Budget.
$keyInfo = $null
$k = if ($env:OPENROUTER_API_KEY) { $env:OPENROUTER_API_KEY } else { [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User') }
if ($k) {
  try { $keyInfo = (Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/key' -Headers @{ Authorization = "Bearer $k" } -TimeoutSec 30).data } catch {}
}
$k = $null
if ($keyInfo -and $keyInfo.limit -and [double]$keyInfo.usage -ge 0.75 * [double]$keyInfo.limit) {
  [void]$sugg.Add("OpenRouter key used `$$([math]::Round([double]$keyInfo.usage, 2)) of its `$$($keyInfo.limit) $($keyInfo.limit_reset) limit: paid models stop at $($defs.opencode.budgetStopPercent) %.")
}
if (-not $rows.Count) { [void]$sugg.Add("No relay stages recorded in the last $Days days yet: the report fills up as relays run.") }

# ---------- -Apply: the safe changes only ----------
$applied = @()
if ($Apply -and $applyOps.Count -and $chains) {
  Copy-Item $defaultsPath "$defaultsPath.bak" -Force
  $raw = Get-Content $defaultsPath -Raw -Encoding UTF8
  $j = $raw | ConvertFrom-Json
  foreach ($o in $applyOps) {
    $list = [System.Collections.ArrayList]@($j.opencode.models.($o.role))
    if ($list -notcontains $o.id) { continue }
    $list.Remove($o.id)
    if ($o.op -eq 'demote') { [void]$list.Add($o.id) }
    if ($list.Count -eq 0) { continue }   # never empty a role's list
    $j.opencode.models.($o.role) = @($list)
    $applied += "$($o.op) $($o.id) ($($o.role))"
  }
  if ($applied) {
    # Rewrite only the "models" object, so the rest of the file keeps its layout and comments.
    $newModels = ($j.opencode.models | ConvertTo-Json -Depth 3)
    $raw = [regex]::Replace($raw, '(?s)("opencode"\s*:\s*\{.*?"models"\s*:\s*)\{.*?\}(\s*,)', { param($m) $m.Groups[1].Value + $newModels + $m.Groups[2].Value }, 1)
    [IO.File]::WriteAllText($defaultsPath, $raw, $utf8)
  }
}

# ---------- per task and per stage (D-034): what each task cost, and the latest stages one by one ----------
$taskSpend = @($rows | Where-Object { $_.task } | Group-Object { "$($_.project)|$($_.task)" } | ForEach-Object {
  $p = $_.Name -split '\|', 2
  $c = @($_.Group | Where-Object { $null -ne $_.cost } | ForEach-Object { [double]$_.cost })
  $orc = @($_.Group | Where-Object { $_.agent -eq 'opencode' -and -not $_.free -and $null -ne $_.cost } | ForEach-Object { [double]$_.cost })
  [pscustomobject]@{ project = $p[0]; task = $p[1]; stages = $_.Count
    tokens = [int64](@($_.Group | Where-Object { $_.tokens } | ForEach-Object { [double]$_.tokens }) | Measure-Object -Sum).Sum
    cost = [math]::Round(($c | Measure-Object -Sum).Sum, 3); openrouter = [math]::Round(($orc | Measure-Object -Sum).Sum, 3)
    minutes = [math]::Round((@($_.Group | ForEach-Object { [double]$_.minutes }) | Measure-Object -Sum).Sum, 0)
    last = ($_.Group | ForEach-Object { [datetime]$_.at } | Sort-Object | Select-Object -Last 1) } } | Sort-Object last -Descending | Select-Object -First 25)
$recent = @($rows | Sort-Object { [datetime]$_.at } | Select-Object -Last 40)
[array]::Reverse($recent)
$misses = @(Read-Lines (Join-Path $usage 'tester-misses.jsonl') | Where-Object { $_.at -and [datetime]$_.at -ge $since })
# ---------- D-035: per kind (the tuner's scores), day by day, the tuner's changes, savings ----------
$outcomes = @(Read-Lines (Join-Path $usage 'task-outcomes.jsonl') | Where-Object { $_.at -and [datetime]$_.at -ge $since })
$tuning = $null; try { $tuning = Get-Content (Join-Path $usage 'selection-tuning.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
$tLedger = @(Read-Lines (Join-Path $usage 'selection-ledger.jsonl') | Where-Object { $_.at -and [datetime]$_.at -ge $since })
$byDay = @($rows | Group-Object { ([datetime]$_.at).ToString('yyyy-MM-dd') } | Sort-Object Name | ForEach-Object {
  $d = $_.Name
  $o = @($outcomes | Where-Object { ([datetime]$_.at).ToString('yyyy-MM-dd') -eq $d })
  [pscustomobject]@{ day = $d; stages = $_.Count
    cost = [math]::Round((@($_.Group | Where-Object { $null -ne $_.cost } | ForEach-Object { [double]$_.cost }) | Measure-Object -Sum).Sum, 2)
    tasks = $o.Count; first = $(if ($o.Count) { [math]::Round(100 * @($o | Where-Object { $_.approvedFirst }).Count / $o.Count) } else { $null })
    stalls = @($_.Group | Where-Object { $_.stalled -or $_.state -eq 'skipped' }).Count } })
# Claude's API-equivalent saved by not running every Claude stage on Opus (catalog input prices; plan quota, not money).
$cat = $defs.selection.catalog.claude
$saved = 0.0
if ($cat) {
  foreach ($r in @($rows | Where-Object { $_.agent -eq 'claude' -and $null -ne $_.cost -and $_.model })) {
    foreach ($k in @('haiku', 'sonnet')) { if (([string]$r.model).ToLower().Contains($k) -and $cat.$k.in -gt 0) { $saved += [double]$r.cost * ([double]$cat.opus.in / [double]$cat.$k.in - 1) } }
  }
}
$saved = [math]::Round($saved, 2)

# ---------- outputs ----------
$summary = [ordered]@{ at = (Get-Date).ToString('o'); days = $Days; stages = $rows.Count
  savedVsOpusUsd = $saved; byDay = $byDay
  tasks = $taskSpend; testerMisses =@($misses | Group-Object { "$($_.agent):$($_.model)" } | ForEach-Object { [ordered]@{ model = $_.Name; misses = $_.Count } })
  cost = [math]::Round((@($rows | Where-Object { $null -ne $_.cost } | ForEach-Object { [double]$_.cost }) | Measure-Object -Sum).Sum, 4)
  openrouter = $(if ($keyInfo) { [ordered]@{ limit = $keyInfo.limit; used = [math]::Round([double]$keyInfo.usage, 4); reset = $keyInfo.limit_reset } } else { $null })
  suggestions = @($sugg); applied = $applied; table = $table }
[IO.File]::WriteAllText((Join-Path $usage 'model-report.json'), ($summary | ConvertTo-Json -Depth 5), $utf8)

function Html-Text([string]$s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Bars($items, [string]$unit, [double]$max, [string]$prefix = '') {
  # A horizontal bar chart as inline SVG: items = @(@{ label; value }). Labels get the left 330 px (long model ids
  # are shortened, the full one is in the tooltip); bars the rest.
  if (-not $items.Count) { return '<p class="dim">No data yet.</p>' }
  if ($max -le 0) { $max = ($items | ForEach-Object { [double]$_.value } | Measure-Object -Maximum).Maximum; if ($max -le 0) { $max = 1 } }
  $h = 26 * $items.Count + 8
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("<svg viewBox='0 0 760 $h' width='100%' role='img'>")
  $y = 4
  foreach ($it in $items) {
    $w = [math]::Max(2, [math]::Round(340 * [double]$it.value / $max))
    $lab = [string]$it.label; $short = if ($lab.Length -gt 46) { $lab.Substring(0, 44) + '..' } else { $lab }
    [void]$sb.Append("<text x='0' y='$($y + 14)' class='lbl'><title>$(Html-Text $lab)</title>$(Html-Text $short)</text><rect x='336' y='$y' width='$w' height='18' rx='4' class='bar'/>")
    [void]$sb.Append("<text x='$(342 + $w)' y='$($y + 14)' class='val'>$(Html-Text ("{0}{1}{2}" -f $prefix, $it.value, $unit))</text>")
    $y += 26
  }
  [void]$sb.Append('</svg>')
  return $sb.ToString()
}
function Lines($series) {
  # Output price history per model as inline SVG lines: series = @{ id = @(@{ day; v }) }
  $all = @($series.Values | ForEach-Object { $_ } )
  if ($all.Count -lt 2) { return '<p class="dim">Price history starts with the first relay run; one point a day.</p>' }
  $days = @($all | ForEach-Object { $_.day } | Sort-Object -Unique)
  $max = ($all | ForEach-Object { [double]$_.v } | Measure-Object -Maximum).Maximum; if ($max -le 0) { $max = 1 }
  # Chart area y 20..220, legend below it (never on top of the lines).
  $legendH = 18 * $series.Count
  $sb = New-Object Text.StringBuilder; [void]$sb.Append("<svg viewBox='0 0 720 $(262 + $legendH)' width='100%' role='img'><line x1='40' y1='220' x2='700' y2='220' class='axis'/><line x1='40' y1='20' x2='700' y2='20' class='axis'/>")
  $colors = @('c1', 'c2', 'c3', 'c4', 'c5', 'c6'); $ci = 0; $ly = 262
  foreach ($id in $series.Keys) {
    # Points are objects (Sort-Object can't sort hashtables by a key in Windows PowerShell 5.1).
    $pts = foreach ($p in ($series[$id] | Sort-Object day)) {
      $x = 40 + [math]::Round(660 * [array]::IndexOf($days, $p.day) / [math]::Max(1, $days.Count - 1)); $y = 220 - [math]::Round(200 * [double]$p.v / $max); "$x,$y"
    }
    $c = $colors[$ci % $colors.Count]; $ci++
    $last = @($series[$id] | Sort-Object day)[-1].v
    [void]$sb.Append("<polyline points='$($pts -join ' ')' class='ln $c'/><rect x='40' y='$($ly - 9)' width='14' height='4' class='$c'/><text x='62' y='$ly' class='lbl'>$(Html-Text $id) (now `$$last)</text>"); $ly += 18
  }
  [void]$sb.Append("<text x='40' y='238' class='val'>$(Html-Text $days[0])</text><text x='700' y='238' class='val' text-anchor='end'>$(Html-Text $days[-1])</text><text x='0' y='24' class='val'>`$$max</text><text x='0' y='222' class='val'>`$0</text></svg>")
  return $sb.ToString()
}
$passItems = @($table | Where-Object { $null -ne $_.pass } | ForEach-Object { @{ label = "$($_.role) / $($_.model)"; value = $_.pass } })
$costItems = @($table | Where-Object { $_.costTotal } | Sort-Object costTotal -Descending | ForEach-Object { @{ label = "$($_.role) / $($_.model)"; value = $_.costTotal } })
$minItems = @($table | ForEach-Object { @{ label = "$($_.role) / $($_.model)"; value = $_.minutes } })
$series = [ordered]@{}
$want = @{}; if ($chains) { foreach ($p in $chains.PSObject.Properties) { foreach ($id in @($p.Value)) { if ($id -notlike '*:free') { $want[$id] = $true } } } }
foreach ($g in ($prices | Where-Object { $want.ContainsKey([string]$_.id) } | Group-Object id)) { $series[$g.Name] = @($g.Group | ForEach-Object { [pscustomobject]@{ day = [string]$_.day; v = [double]$_.outPrice } }) }
$rowsHtml = ($table | ForEach-Object {
  "<tr><td>$(Html-Text $_.role)</td><td>$(Html-Text $_.agent)</td><td>$(Html-Text $_.model)</td><td>$($_.runs)</td><td>$($_.done) %</td>" +
  "<td>$(if ($null -ne $_.pass) { "$($_.pass) % <span class='dim'>($($_.passKind), $($_.judged))</span>" } else { '<span class=''dim''>-</span>' })</td>" +
  "<td>$($_.minutes)</td><td>$(if ($_.tokens) { '{0:N0}' -f $_.tokens } else { '-' })</td><td>$(if ($null -ne $_.cost) { '$' + $_.cost } else { '-' })</td><td>$($_.switches)</td>" +
  "<td>$(if ($null -ne $_.protocol) { "$($_.protocol) %" } else { '-' })</td><td>$(if ($null -ne $_.rounds) { $_.rounds } else { '-' })</td></tr>" }) -join "`n"
$money = { param($v) if ($null -ne $v -and "$v" -ne '') { '$' + ('{0:N2}' -f [double]$v) } else { '-' } }
$taskHtml = ($taskSpend | ForEach-Object {
  "<tr><td>$(Html-Text $_.project)</td><td>$(Html-Text $_.task)</td><td>$($_.stages)</td><td>$($_.minutes)</td><td>$('{0:N0}' -f $_.tokens)</td><td>$(& $money $_.cost)</td><td>$(& $money $_.openrouter)</td></tr>" }) -join "`n"
$recentHtml = ($recent | ForEach-Object {
  "<tr><td>$(([datetime]$_.at).ToString('dd MMM HH:mm'))</td><td>$(Html-Text $_.project)</td><td>$(Html-Text $_.task)</td><td>$(Html-Text $_.role)$(if ($_.recheck) { ' <span class=''dim''>re-check</span>' })</td>" +
  "<td>$(Html-Text $_.agent) $(Html-Text (Model-Label $_))</td><td>$(Html-Text $_.effort)</td><td class='dim'>$(Html-Text $_.source)</td><td>$($_.minutes)</td>" +
  "<td>$(if ($_.tokens) { '{0:N0}' -f [double]$_.tokens } else { '-' })</td><td>$(& $money $_.cost)</td><td>$(Html-Text $_.state)$(if ($_.testResult) { " / $($_.testResult)" })$(if ($_.verdict) { " / $($_.verdict)" })</td></tr>" }) -join "`n"
$kindHtml = if ($tuning -and @($tuning.units).Count) { ($tuning.units | ForEach-Object {
  "<tr><td>$(Html-Text $_.kind)</td><td>$(Html-Text $_.role)</td><td>$(Html-Text $_.cand)</td><td>$($_.n)</td><td>$([math]::Round(100 * [double]$_.rate)) %</td><td>$($_.stalls)</td><td>$($_.misses)</td><td>$(& $money $_.avgCost)</td><td>$($_.avgMin)</td></tr>" }) -join "`n" } else { '' }
$dayHtml = ($byDay | ForEach-Object { "<tr><td>$($_.day)</td><td>$($_.stages)</td><td>$($_.tasks)</td><td>$(if ($null -ne $_.first) { "$($_.first) %" } else { '-' })</td><td>$($_.stalls)</td><td>$(& $money $_.cost)</td></tr>" }) -join "`n"
$tuneHtml = ''
if ($tuning) {
  $tuneHtml += if (@($tuning.proposals).Count) { '<p><b>Waiting for you</b> (Accept or Dismiss in the panel):</p><ul>' + (($tuning.proposals | ForEach-Object { "<li>$(Html-Text $_.kind) $(Html-Text $_.role): $(Html-Text $_.to) <span class='dim'>($(Html-Text $_.reason))</span></li>" }) -join '') + '</ul>' } else { '<p class="dim">No proposals waiting.</p>' }
  if (@($tuning.whatWorked).Count) { $tuneHtml += '<p><b>What worked</b> (the planner sees this):</p><ul>' + (($tuning.whatWorked | ForEach-Object { "<li>$(Html-Text $_)</li>" }) -join '') + '</ul>' }
}
$tuneHtml += if ($tLedger.Count) { '<p><b>Changes</b> (undo one: <code>tools\selection-tuner.ps1 -Rollback &lt;id&gt;</code>):</p><ul>' + (($tLedger | Select-Object -Last 15 | ForEach-Object { "<li>$(([datetime]$_.at).ToString('dd MMM')) <code>$(Html-Text $_.id)</code> $(Html-Text $_.action) $(Html-Text $_.kind) $(Html-Text $_.role)$(if ($_.to) { ': ' + (Html-Text $_.to) }) <span class='dim'>$(Html-Text $_.reason)</span></li>" }) -join '') + '</ul>' } else { '<p class="dim">The tuner has changed nothing yet.</p>' }
$missHtml = if ($misses.Count) { '<p>Testers that said PASS in a round the judge then failed: ' + (Html-Text ((@($misses | Group-Object { "$($_.agent) $($_.model)" } | ForEach-Object { "$($_.Name) x$($_.Count)" })) -join ', ')) + '. Two in 30 days in one project leave a model out of automatic picks there.</p>' } else { '<p class="dim">No tester missed a failing criterion in this period.</p>' }
$suggHtml = if ($sugg.Count) { '<ul>' + (($sugg | ForEach-Object { "<li>$(Html-Text $_)</li>" }) -join '') + '</ul>' } else { '<p class="dim">Nothing to change.</p>' }
$appliedHtml = if ($applied) { '<p><b>Applied:</b> ' + (Html-Text ($applied -join '; ')) + ' (backup: relay-defaults.json.bak)</p>' } else { '' }
$orHtml = if ($keyInfo) { "OpenRouter key: `$$([math]::Round([double]$keyInfo.usage, 3)) used of `$$($keyInfo.limit) ($($keyInfo.limit_reset))." } else { 'OpenRouter key: not readable.' }
$html = @"
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Relay Model Report</title>
<style>
:root{--bg:#f7f7f5;--fg:#1d1d1f;--dim:#6b6b70;--card:#fff;--line:#e3e3e0;--bar:#3b82f6;--c1:#2563eb;--c2:#16a34a;--c3:#d97706;--c4:#dc2626;--c5:#7c3aed;--c6:#0891b2}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#141416;--fg:#ececee;--dim:#9a9aa2;--card:#1d1d21;--line:#2c2c32;--bar:#60a5fa;--c1:#60a5fa;--c2:#4ade80;--c3:#fbbf24;--c4:#f87171;--c5:#a78bfa;--c6:#22d3ee}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:980px;margin:0 auto;padding:24px 16px}h1{margin:0 0 4px;font-size:24px}h2{font-size:16px;margin:28px 0 8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:10px 0;overflow-x:auto}
.dim{color:var(--dim)}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--dim);font-weight:600}.lbl{fill:var(--fg);font-size:12px}.val{fill:var(--dim);font-size:11px}.bar{fill:var(--bar)}.axis{stroke:var(--line)}
.ln{fill:none;stroke-width:2}.c1{stroke:var(--c1);fill:var(--c1)}.c2{stroke:var(--c2);fill:var(--c2)}.c3{stroke:var(--c3);fill:var(--c3)}.c4{stroke:var(--c4);fill:var(--c4)}.c5{stroke:var(--c5);fill:var(--c5)}.c6{stroke:var(--c6);fill:var(--c6)}
polyline.ln{fill:none}
</style></head><body><main>
<h1>Relay model report</h1>
<p class="dim">Last $Days days &middot; $($rows.Count) stages &middot; recorded cost `$$($summary.cost) &middot; made $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; $(Html-Text $orHtml)</p>
<h2>Suggestions</h2><div class="card">$suggHtml$appliedHtml<p class="dim">Run <code>tools\model-report.ps1 -Apply</code> to make the safe ones (remove unlisted models, move clearly worse ones down). Other suggestions are yours to decide in relay-defaults.json.</p></div>
<h2>Pass rate by role and model</h2><div class="card">$(Bars $passItems ' %' 100)<p class="dim">Judge: how often it approved. Other roles: how often the round they worked in was approved.</p></div>
<h2>Cost (total, recorded)</h2><div class="card">$(Bars $costItems '' 0 '$')<p class="dim">OpenCode: exact cost from its sessions. Claude: from its status line. Codex and Antigravity run on your plans and report no cost.</p></div>
<h2>Average minutes per stage</h2><div class="card">$(Bars $minItems ' min' 0)</div>
<h2>OpenRouter output price history (per 1M tokens)</h2><div class="card">$(Lines $series)</div>
<h2>All numbers</h2><div class="card"><table><tr><th>Role</th><th>Agent</th><th>Model</th><th>Runs</th><th>Done</th><th>Pass</th><th>Avg min</th><th>Avg tokens</th><th>Avg cost</th><th>Quota switches</th><th>Protocol kept</th><th>Rounds to approval</th></tr>
$rowsHtml</table></div>
<h2>Spend per task</h2><div class="card"><table><tr><th>Project</th><th>Task</th><th>Stages</th><th>Minutes</th><th>Tokens</th><th>Cost</th><th>OpenRouter (real money)</th></tr>
$taskHtml</table><p class="dim">Cost: OpenCode exact, Claude the API-equivalent from its status line (your plan pays it, not money); Codex and Antigravity report none.</p></div>
<h2>Latest stages</h2><div class="card"><table><tr><th>When</th><th>Project</th><th>Task</th><th>Role</th><th>Model</th><th>Effort</th><th>Chosen by</th><th>Min</th><th>Tokens</th><th>Cost</th><th>Result</th></tr>
$recentHtml</table><p class="dim">Chosen by: the level that picked the agent / the model (stage, task, run, project, global, auto, step-down, escalate).</p></div>
<h2>Testers that missed</h2><div class="card">$missHtml</div>
<h2>Day by day</h2><div class="card"><table><tr><th>Day</th><th>Stages</th><th>Tasks done</th><th>Approved first time</th><th>Stalls</th><th>Cost</th></tr>
$dayHtml</table><p class="dim">Claude API-equivalent saved by using Sonnet and Haiku instead of Opus for every Claude stage: about `$$saved (your plan's quota, not money).</p></div>
<h2>By task kind (what the tuner learns from)</h2><div class="card">$(if ($kindHtml) { "<table><tr><th>Kind</th><th>Role</th><th>Model</th><th>Stages</th><th>Approved</th><th>Stalls</th><th>Misses</th><th>Avg cost</th><th>Avg min</th></tr>$kindHtml</table>" } else { '<p class="dim">No labelled tasks yet: they start with the next planner run (D-035).</p>' })</div>
<h2>Selection tuner</h2><div class="card">$tuneHtml</div>
</main></body></html>
"@
[IO.File]::WriteAllText((Join-Path $usage 'model-report.html'), $html, $utf8)
if (-not $Quiet) {
  Write-Host "Model report: $($rows.Count) stages in the last $Days days, recorded cost `$$($summary.cost)."
  foreach ($s in $sugg) { Write-Host "  - $s" }
  if ($applied) { Write-Host "  applied: $($applied -join '; ')" -ForegroundColor Green }
  Write-Host "  $(Join-Path $usage 'model-report.html')"
}
