# selection-tuner.ps1 - the relay's daily model tuner (D-035). Learns, per task kind and role, which model does the
# job best for the least, from real relay results, and adjusts the kind matrix (relay-defaults.json selection.kinds)
# through an overlay: usage/selection-tuning.json. relay-defaults.json is never edited.
#
#   powershell -File tools\selection-tuner.ps1            compute: scores, proposals, "what worked" (no changes)
#   powershell -File tools\selection-tuner.ps1 -Apply     also apply the SAFE changes (the daily supervisor does this)
#   powershell -File tools\selection-tuner.ps1 -Accept <id> | -Dismiss <id> | -Rollback <id>
#
# Data: usage/model-stats.jsonl (every stage: kind, role, agent, model, round, verdict, stalled, cost),
#       usage/task-outcomes.jsonl (every task), usage/tester-misses.jsonl (testers that passed what the judge failed).
# Score of a kind/role/model: its stages that were not stalled, not a tester miss, and whose round the judge approved.
# Safe changes (applied with -Apply, only with selection.tuner.minSamples stages on both sides):
#   demote : stall or miss rate >= demoteRate -> to the end of that kind's chain for the role
#   cheaper: a cheaper model of the SAME plan agent (claude haiku < sonnet < opus < fable; codex luna < terra < astra < sol)
#            that scored at least as well -> before the dearer one (exploration supplies these samples)
# Anything else that scores better by 'margin' (another agent, a dearer model, paid OpenRouter) is a proposal for the
# user (panel: Accept/Dismiss). Reviewers are only ever demoted (their quality can't be scored from approvals).
# Every change goes to usage/selection-ledger.jsonl with its reason; -Rollback <id> undoes one.
param([switch]$Apply, [string]$Accept = '', [string]$Dismiss = '', [string]$Rollback = '', [int]$Days = 0,
      [switch]$Quiet, [switch]$LibOnly, [string]$Root = '')
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$utf8 = New-Object System.Text.UTF8Encoding($false)

$script:ladders = @{ claude = @('fable', 'opus', 'sonnet', 'haiku'); codex = @('sol', 'astra', 'terra', 'luna') }
$script:planAgents = @('claude', 'codex', 'antigravity')
# What 'default' means per agent (stages that ran an agent's own default model record 'default').
$script:agentDefaults = @{ claude = 'opus'; codex = 'sol'; antigravity = 'hydrogen' }

function Read-Rows([string]$p) {
  if (-not (Test-Path $p)) { return @() }
  return @([IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
}
# claude-sonnet-5-5 -> sonnet; gpt-6.2-sol -> sol; gemini-4-hydrogen -> hydrogen; OpenRouter ids stay as they are.
function Short-Model([string]$agent, [string]$model) {
  $m = ([string]$model).ToLower()
  if (-not $m -or $m -in @('default', 'its own')) { if ($script:agentDefaults.ContainsKey($agent)) { return $script:agentDefaults[$agent] }; return 'default' }
  switch ($agent) {
    'claude' { foreach ($k in @('fable', 'opus', 'sonnet', 'haiku')) { if ($m.Contains($k)) { return $k } } }
    'codex' { foreach ($k in @('sol', 'astra', 'terra', 'luna')) { if ($m.Contains($k)) { return $k } } }
    'antigravity' { foreach ($p in @(@('hydrogen', 'hydrogen'), @('flash', 'flash'), @('opus', 'opus'), @('sonnet', 'sonnet'), @('gpt', 'gpt-oss'))) { if ($m.Contains($p[0])) { return $p[1] } } }
  }
  return $m
}
# "claude:sonnet@high" -> @{ agent; model; text }; a bare agent keeps model 'default'.
function Chain-Items([string]$chain) {
  $items = @()
  foreach ($part in (([string]$chain) -split '[|~]')) {
    $t = $part.Trim(); if (-not $t) { continue }
    $spec = ($t -replace '@[a-z]+$', '')
    $ag = ($spec -split ':', 2)[0].ToLower(); if ($ag -eq 'agy') { $ag = 'antigravity' }
    $mo = if ($spec.Contains(':')) { ($spec -split ':', 2)[1] } else { 'default' }
    $items += ,@{ agent = $ag; model = (Short-Model $ag $mo); text = $t }
  }
  return ,$items
}
function Item-Key($i) { return "$($i.agent):$($i.model)" }
# Is B a cheaper model than A of the same plan agent?
function Is-Cheaper($b, $a) {
  if ($b.agent -ne $a.agent -or -not $script:ladders.ContainsKey($b.agent)) { return $false }
  $l = $script:ladders[$b.agent]
  $ib = [array]::IndexOf($l, $b.model); $ia = [array]::IndexOf($l, $a.model)
  return ($ib -ge 0 -and $ia -ge 0 -and $ib -gt $ia)
}

# Scores per kind|role|agent:model.
function Get-Units($rows, $misses) {
  $verdictOf = @{}
  foreach ($r in $rows) { if ($r.judge -and $r.verdict) { $verdictOf["$($r.relay)|$($r.task)|$($r.round)"] = [string]$r.verdict } }
  $missed = @{}
  foreach ($m in $misses) { $missed["$(if ($m.relay) { $m.relay } else { $m.project })|$($m.task)|$($m.stage)"] = $true }
  $u = @{}
  foreach ($r in $rows) {
    if (-not $r.kind -or -not $r.role -or $r.state -eq 'not needed' -or -not $r.agent) { continue }
    $key = "$($r.kind)|$($r.role)|$($r.agent):$(Short-Model ([string]$r.agent) ([string]$r.model))"
    if (-not $u.ContainsKey($key)) { $u[$key] = @{ kind = [string]$r.kind; role = [string]$r.role; cand = "$($r.agent):$(Short-Model ([string]$r.agent) ([string]$r.model))"; n = 0; ok = 0; stalls = 0; misses = 0; cost = 0.0; costN = 0; minutes = 0.0 } }
    $x = $u[$key]; $x.n++
    $stalled = [bool]$r.stalled -or $r.state -eq 'skipped'
    $miss = $missed.ContainsKey("$($r.relay)|$($r.task)|$($r.n)") -or $missed.ContainsKey("$($r.project)|$($r.task)|$($r.n)")
    if ($stalled) { $x.stalls++ }
    if ($miss) { $x.misses++ }
    $v = if ($r.judge) { if (-not $stalled) { 'APPROVED' } else { '' } } else { $verdictOf["$($r.relay)|$($r.task)|$($r.round)"] }
    if (-not $stalled -and -not $miss -and $v -eq 'APPROVED') { $x.ok++ }
    if ($null -ne $r.cost) { $x.cost += [double]$r.cost; $x.costN++ }
    $x.minutes += [double]$r.minutes
  }
  foreach ($x in $u.Values) {
    $x.rate = if ($x.n) { [math]::Round($x.ok / $x.n, 3) } else { 0 }
    $x.badRate = if ($x.n) { [math]::Round(($x.stalls + $x.misses) / $x.n, 3) } else { 0 }
    $x.avgCost = if ($x.costN) { [math]::Round($x.cost / $x.costN, 4) } else { $null }
    $x.avgMin = if ($x.n) { [math]::Round($x.minutes / $x.n, 1) } else { 0 }
  }
  # Objects, not hashtables: Sort-Object and Measure-Object read properties by name.
  $o = @{}; foreach ($k in @($u.Keys)) { $o[$k] = [pscustomobject]$u[$k] }
  return $o
}

# Decide changes for every kind/role. Returns @{ changes = @(...safe); proposals = @(...) }.
function Get-Decisions($units, $kinds, $overlay, $cfg) {
  $min = [int]$cfg.minSamples; $bad = [double]$cfg.demoteRate; $margin = [double]$cfg.margin
  $changes = @(); $proposals = @()
  foreach ($kp in @($kinds.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('_') })) {
    $kind = $kp.Name
    foreach ($role in @('executor', 'tester', 'reviewer', 'refiner')) {
      $base = if ($kp.Value.PSObject.Properties[$role]) { [string]$kp.Value.$role } else { '' }
      if (-not $base) { continue }
      $cur = $base
      if ($overlay -and $overlay.PSObject.Properties[$kind] -and $overlay.$kind.PSObject.Properties[$role] -and $overlay.$kind.$role) { $cur = [string]$overlay.$kind.$role }
      $items = Chain-Items $cur
      $stat = { param($i) $units["$kind|$role|$(Item-Key $i)"] }
      $new = [System.Collections.ArrayList]@($items)
      $why = @()
      # demote: stalls or misses
      foreach ($i in @($items)) {
        $s = & $stat $i
        if ($s -and $s.n -ge $min -and $s.badRate -ge $bad -and $new.Count -gt 1 -and $new.IndexOf($i) -lt $new.Count - 1) {
          [void]$new.Remove($i); [void]$new.Add($i)
          $why += "demote $(Item-Key $i): $($s.stalls) stall(s) and $($s.misses) miss(es) in $($s.n) $kind $role stages"
        }
      }
      if ($role -ne 'reviewer') {
        # cheaper: a cheaper model of the same agent (in the chain, or tried by exploration) that scored at least as well
        $seen = @($units.Values | Where-Object { $_.kind -eq $kind -and $_.role -eq $role -and $_.n -ge $min })
        foreach ($s in $seen) {
          $parts = $s.cand -split ':', 2
          $b = @{ agent = $parts[0]; model = $parts[1]; text = '' }
          if ($b.agent -notin $script:planAgents) { continue }
          foreach ($a in @($new)) {
            if (-not (Is-Cheaper $b $a)) { continue }
            $sa = & $stat $a
            if (-not $sa -or $sa.n -lt $min -or $s.rate -lt $sa.rate) { continue }
            $existing = @($new | Where-Object { (Item-Key $_) -eq $s.cand }) | Select-Object -First 1
            $ia = $new.IndexOf($a)
            if ($existing -and $new.IndexOf($existing) -lt $ia) { break }
            $eff = if ($a.text -match '(@[a-z]+)$') { $Matches[1] } else { '' }
            $item = if ($existing) { $existing } else { @{ agent = $b.agent; model = $b.model; text = "$($b.agent):$($b.model)$eff" } }
            if ($existing) { [void]$new.Remove($existing) }
            $new.Insert($new.IndexOf($a), $item)
            $why += ("cheaper {0} before {1}: {2:P0} of {3} stages vs {4:P0} of {5}" -f $s.cand, (Item-Key $a), $s.rate, $s.n, $sa.rate, $sa.n)
            break
          }
        }
        # proposals: another candidate that did clearly better than the first one (costs more or another agent)
        $firstItem = $new[0]; $sf = & $stat $firstItem
        if ($sf -and $sf.n -ge $min) {
          foreach ($s in $seen) {
            if ($s.cand -eq (Item-Key $firstItem)) { continue }
            if ($s.rate - $sf.rate -lt $margin) { continue }
            $parts = $s.cand -split ':', 2
            $eff = if ($firstItem.text -match '(@[a-z]+)$') { $Matches[1] } else { '' }
            $to = (@("$($s.cand)$eff") + @($new | Where-Object { (Item-Key $_) -ne $s.cand } | ForEach-Object { $_.text })) -join '|'
            $id = 'p-' + ([BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("$kind|$role|$to"))) -replace '-', '').Substring(0, 8).ToLower()
            $proposals += [ordered]@{ id = $id; kind = $kind; role = $role; from = (($new | ForEach-Object { $_.text }) -join '|'); to = $to
              reason = ("{0} for {1} {2}: {3:P0} of {4} stages approved vs {5:P0} of {6} for {7}" -f $s.cand, $kind, $role, $s.rate, $s.n, $sf.rate, $sf.n, (Item-Key $firstItem)) }
          }
        }
      }
      $newText = (@($new | ForEach-Object { $_.text })) -join '|'
      if ($why.Count -and $newText -ne (($items | ForEach-Object { $_.text }) -join '|')) {
        $changes += [ordered]@{ kind = $kind; role = $role; from = $cur; to = $newText; base = $base; reason = ($why -join '; ') }
      }
    }
  }
  return @{ changes = $changes; proposals = $proposals }
}

# One line per kind about what built it best, for the planner's prompt.
function Get-WhatWorked($units, [int]$min) {
  $out = @()
  foreach ($g in @($units.Values | Where-Object { $_.role -eq 'executor' -and $_.n -ge [math]::Max(2, [int]($min / 2)) } | Group-Object kind | Sort-Object { -(($_.Group | ForEach-Object { $_.n }) | Measure-Object -Sum).Sum })) {
    $best = @($g.Group | Sort-Object -Property @{ Expression = 'rate'; Descending = $true }, @{ Expression = 'n'; Descending = $true } | Select-Object -First 2)
    $out += "$($g.Name) tasks: " + (($best | ForEach-Object { "$($_.cand) approved $($_.ok) of $($_.n)" }) -join ', ')
  }
  return @($out | Select-Object -First 8)
}

function New-Id { return [guid]::NewGuid().ToString('N').Substring(0, 8) }
function Set-Overlay($t, [string]$kind, [string]$role, [string]$chain, [string]$base) {
  if (-not $t.kinds) { $t.kinds = [pscustomobject]@{} }
  if (-not $t.kinds.PSObject.Properties[$kind]) { $t.kinds | Add-Member -NotePropertyName $kind -NotePropertyValue ([pscustomobject]@{}) }
  $k = $t.kinds.$kind
  if ($chain -eq $base -or -not $chain) { if ($k.PSObject.Properties[$role]) { $k.PSObject.Properties.Remove($role) } }
  elseif ($k.PSObject.Properties[$role]) { $k.$role = $chain } else { $k | Add-Member -NotePropertyName $role -NotePropertyValue $chain }
  if (-not @($k.PSObject.Properties).Count) { $t.kinds.PSObject.Properties.Remove($kind) }
}
function Add-Ledger([string]$path, $entry) { [IO.File]::AppendAllText($path, (($entry | ConvertTo-Json -Compress -Depth 4) + "`n"), $utf8) }

if ($LibOnly) { return }

# ---------- run ----------
$usage = Join-Path $Root 'usage'
New-Item -ItemType Directory -Path $usage -Force | Out-Null
$defs = (Get-Content (Join-Path $Root 'relay-defaults.json') -Raw -Encoding UTF8) | ConvertFrom-Json
$sel = $defs.selection
if (-not $sel -or -not $sel.kinds) { Write-Host 'relay-defaults.json has no selection.kinds: nothing to tune.'; exit 0 }
$cfg = if ($sel.tuner) { $sel.tuner } else { [pscustomobject]@{ days = 45; minSamples = 5; demoteRate = 0.3; margin = 0.15 } }
if (-not $Days) { $Days = [int]$cfg.days }
$tunePath = Join-Path $usage 'selection-tuning.json'
$ledger = Join-Path $usage 'selection-ledger.jsonl'
$t = $null; try { if (Test-Path $tunePath) { $t = (Get-Content $tunePath -Raw -Encoding UTF8) | ConvertFrom-Json } } catch {}
if (-not $t) { $t = [pscustomobject]@{} }
foreach ($p in @('kinds', 'dismissed')) { if (-not $t.PSObject.Properties[$p]) { $t | Add-Member -NotePropertyName $p -NotePropertyValue ([pscustomobject]@{}) } }
foreach ($p in @('proposals', 'whatWorked', 'units', 'applied')) { if (-not $t.PSObject.Properties[$p]) { $t | Add-Member -NotePropertyName $p -NotePropertyValue @() } }
$save = { $t | Add-Member -NotePropertyName at -NotePropertyValue (Get-Date).ToString('o') -Force; [IO.File]::WriteAllText($tunePath, ($t | ConvertTo-Json -Depth 8), $utf8) }
$baseOf = { param($kind, $role) if ($sel.kinds.PSObject.Properties[$kind] -and $sel.kinds.$kind.PSObject.Properties[$role]) { [string]$sel.kinds.$kind.$role } else { '' } }

if ($Accept -or $Dismiss) {
  $id = if ($Accept) { $Accept } else { $Dismiss }
  $p = @($t.proposals | Where-Object { $_.id -eq $id }) | Select-Object -First 1
  if (-not $p) { Write-Host "No proposal $id." -ForegroundColor Red; exit 1 }
  if ($Accept) {
    Set-Overlay $t $p.kind $p.role ([string]$p.to) (& $baseOf $p.kind $p.role)
    Add-Ledger $ledger ([ordered]@{ id = (New-Id); at = (Get-Date).ToString('o'); action = 'accept'; proposal = $id; kind = $p.kind; role = $p.role; from = $p.from; to = $p.to; reason = $p.reason; auto = $false })
    Write-Host "Accepted: $($p.kind) $($p.role) -> $($p.to)"
  } else {
    $t.dismissed | Add-Member -NotePropertyName $id -NotePropertyValue (Get-Date).ToString('o') -Force
    Add-Ledger $ledger ([ordered]@{ id = (New-Id); at = (Get-Date).ToString('o'); action = 'dismiss'; proposal = $id; kind = $p.kind; role = $p.role; reason = $p.reason })
    Write-Host "Dismissed: $($p.kind) $($p.role) ($($p.reason))"
  }
  $t.proposals = @($t.proposals | Where-Object { $_.id -ne $id })
  & $save; exit 0
}
if ($Rollback) {
  $e = @(Read-Rows $ledger | Where-Object { $_.id -eq $Rollback -and $_.action -in @('demote', 'cheaper', 'change', 'accept') }) | Select-Object -First 1
  if (-not $e) { Write-Host "No change $Rollback in the ledger." -ForegroundColor Red; exit 1 }
  Set-Overlay $t $e.kind $e.role ([string]$e.from) (& $baseOf $e.kind $e.role)
  Add-Ledger $ledger ([ordered]@{ id = (New-Id); at = (Get-Date).ToString('o'); action = 'rollback'; of = $Rollback; kind = $e.kind; role = $e.role; from = $e.to; to = $e.from })
  Write-Host "Rolled back $Rollback`: $($e.kind) $($e.role) is $($e.from) again."
  & $save; exit 0
}

$since = (Get-Date).AddDays(-$Days)
$rows = @(Read-Rows (Join-Path $usage 'model-stats.jsonl') | Where-Object { $_.at -and [datetime]$_.at -ge $since })
# Throwaway test and benchmark projects teach nothing about real work (selection.tuner.ignoreProjects, regexes).
$ignore = @($cfg.ignoreProjects | Where-Object { $_ })
if ($ignore.Count) { $rows = @($rows | Where-Object { $p = [string]$_.project; -not @($ignore | Where-Object { $p -match $_ }).Count }) }
$misses = @(Read-Rows (Join-Path $usage 'tester-misses.jsonl') | Where-Object { $_.at -and [datetime]$_.at -ge $since })
$units = Get-Units $rows $misses
$d = Get-Decisions $units $sel.kinds $t.kinds $cfg
$applied = @()
foreach ($c in $d.changes) {
  if ($Apply) {
    Set-Overlay $t $c.kind $c.role ([string]$c.to) ([string]$c.base)
    $id = New-Id
    Add-Ledger $ledger ([ordered]@{ id = $id; at = (Get-Date).ToString('o'); action = $(if ($c.reason -match '^demote') { 'demote' } else { 'cheaper' }); kind = $c.kind; role = $c.role; from = $c.from; to = $c.to; reason = $c.reason; auto = $true })
    $applied += [ordered]@{ id = $id; kind = $c.kind; role = $c.role; to = $c.to; reason = $c.reason }
  }
}
$dismissedIds = @($t.dismissed.PSObject.Properties | Where-Object { [datetime]$_.Value -ge (Get-Date).AddDays(-30) } | ForEach-Object { $_.Name })
$t.proposals = @($d.proposals | Where-Object { $_.id -notin $dismissedIds })
$t.whatWorked = @(Get-WhatWorked $units ([int]$cfg.minSamples))
$t.units = @($units.Values | Sort-Object kind, role, { -$_.n } | ForEach-Object { [ordered]@{ kind = $_.kind; role = $_.role; cand = $_.cand; n = $_.n; ok = $_.ok; rate = $_.rate; stalls = $_.stalls; misses = $_.misses; avgCost = $_.avgCost; avgMin = $_.avgMin } })
$t.applied = @($applied)
$t | Add-Member -NotePropertyName days -NotePropertyValue $Days -Force
$t | Add-Member -NotePropertyName stagesWithKind -NotePropertyValue (@($rows | Where-Object { $_.kind }).Count) -Force
& $save
if (-not $Quiet) {
  Write-Host "Selection tuner: $(@($rows | Where-Object { $_.kind }).Count) labelled stages in $Days days, $($units.Count) kind/role/model scores."
  foreach ($c in $d.changes) { Write-Host "  $(if ($Apply) { 'applied' } else { 'would apply' }): $($c.kind) $($c.role) -> $($c.to)  ($($c.reason))" }
  foreach ($p in $t.proposals) { Write-Host "  proposal $($p.id): $($p.kind) $($p.role) -> $($p.to)  ($($p.reason))" }
  foreach ($w in $t.whatWorked) { Write-Host "  worked: $w" }
}
