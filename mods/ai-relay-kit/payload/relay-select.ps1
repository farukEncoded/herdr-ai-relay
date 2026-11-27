# relay-select.ps1 - the relay's model-selection layer (D-034). Dot-sourced by ai-relay.ps1; also by tests/.
#
# For every stage it decides agent, model and effort from five levels, most specific first:
#   stage   : a switch for the running relay (relay switch ... / .ai/relay/SWITCH.json)
#   task    : the task file's "Relay:" line, e.g. "Relay: profile=content, executor=claude:sonnet@high, tester=claude:haiku"
#   run     : -Profile, -Stages/-Loop agents, -Model, -Effort given when the relay started
#   project : .ai/relay-profile.json (its "default" profile)
#   global  : relay-defaults.json "selection" (profile, per-agent models) and the team's agents and efforts
# Fields merge one by one: the agent comes from the most specific level that names one; the model from the most
# specific level that names one valid for that agent; the effort likewise. A value may be a chain, best first
# ("claude:sonnet|codex:sol"): the relay takes the first candidate that fits right now (quota, budget, listing).
#
# Spec grammar:  agent[:model][@effort]  |  model[@effort]  |  @effort  |  auto
#   agent  : claude | codex | antigravity (agy) | opencode (oc)
#   model  : a short name (claude: fable opus sonnet haiku; codex: sol astra terra luna; antigravity: hydrogen flash
#            opus sonnet gpt-oss; opencode: glm deepseek kimi ...), a version (sonnet-5.5), or a full id
#            (claude-sonnet-5-5, z-ai/glm-5.3, nvidia/...:free)
#   effort : low | medium | high | xhigh | max | default
# Keep this file ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI).

$script:selAgents = @('claude', 'codex', 'antigravity', 'opencode')
$script:selLevels = @('low', 'medium', 'high', 'xhigh', 'max', 'default')
# Short names per agent when the relay's own table isn't loaded yet ('relay switch' checks names before it is).
$script:selDefaultNames = @{
  claude = @{ fable = 1; opus = 1; sonnet = 1; haiku = 1 }; codex = @{ sol = 1; astra = 1; terra = 1; luna = 1 }
  antigravity = @{ hydrogen = 1; flash = 1; opus = 1; sonnet = 1; 'gpt-oss' = 1 }
  opencode = @{ glm = 1; 'glm-flash' = 1; deepseek = 1; nemotron = 1; kimi = 1; mimo = 1 }
}

function Sel-AgentName([string]$a) {
  $a = ([string]$a).Trim().ToLower()
  switch ($a) { 'agy' { return 'antigravity' } 'oc' { return 'opencode' } 'gemini' { return 'antigravity' } default { return $a } }
}

# Which agent owns a bare model name (first match in claude, codex, antigravity, opencode), or ''.
function Sel-AgentOfModel([string]$m, $names) {
  $m = ([string]$m).ToLower()
  if ($m -match '^claude-' -or $m -match '^(opus|sonnet|haiku|fable)-\d') { return 'claude' }
  if ($m -match '^gpt-\d') { return 'codex' }
  if ($m -match '^gemini-') { return 'antigravity' }
  if ($m.Contains('/')) { return 'opencode' }
  if (-not $names) { $names = $script:selDefaultNames }
  foreach ($a in $script:selAgents) { if ($names -and $names[$a] -and $names[$a].Contains($m)) { return $a } }
  return ''
}

# One spec -> @{ agent; model; effort; raw }. Empty fields mean "no opinion". Throws on a bad spec.
function Parse-Spec([string]$text, $names = $script:modelNames) {
  $raw = ([string]$text).Trim()
  $t = $raw.ToLower()
  $s = @{ agent = ''; model = ''; effort = ''; raw = $raw }
  if (-not $t -or $t -eq 'auto') { return $s }
  if ($t -eq 'here') { $s.agent = 'here'; return $s }   # the agent session that started the relay
  $at = $t.LastIndexOf('@')
  if ($at -ge 0) {
    $e = $t.Substring($at + 1).Trim(); $t = $t.Substring(0, $at).Trim()
    if ($e -notin $script:selLevels) { throw "Bad effort '$e' in '$raw' (use $($script:selLevels -join ', '))." }
    $s.effort = $e
  }
  if (-not $t -or $t -eq 'auto') { return $s }
  $colon = $t.IndexOf(':')
  $head = if ($colon -ge 0) { $t.Substring(0, $colon) } else { $t }
  if ($colon -ge 0 -and -not $head.Contains('/') -and (Sel-AgentName $head) -in $script:selAgents) {
    $s.agent = Sel-AgentName $head
    $s.model = $t.Substring($colon + 1).Trim()
  } elseif ((Sel-AgentName $t) -in $script:selAgents) {
    $s.agent = Sel-AgentName $t
  } else {
    $owner = Sel-AgentOfModel $t $names
    if (-not $owner) { throw "Unknown agent or model '$raw'. Use agent[:model][@effort], e.g. claude:sonnet@high or codex:sol." }
    $s.agent = $owner; $s.model = $t
  }
  if ($s.model -and $s.model -notmatch '^[a-z0-9][a-z0-9.\-/:_]*$') { throw "Bad model name in '$raw'." }
  if ($s.model -eq 'auto') { $s.model = '' }
  return $s
}

# "a|b~c" -> array of specs (a chain, best first). "~" joins equally good candidates into one group (spec.group):
# within a group the relay starts the one whose plan has the most quota left (D-035).
function Parse-Chain([string]$text, $names = $script:modelNames) {
  $list = @(); $g = 0
  foreach ($p in (([string]$text) -split '\|')) {
    if (-not $p.Trim()) { continue }
    foreach ($q in ($p -split '~')) { if ($q.Trim()) { $s = Parse-Spec $q $names; $s.group = $g; $list += ,$s } }
    $g++
  }
  return ,$list
}

# A task's labels (D-035): "Labels: kind=ui, size=M, risk=low" (or separate "Kind:", "Size:", "Risk:" lines).
function Read-Labels([string]$text) {
  $l = @{ kind = ''; size = ''; risk = '' }
  $m = [regex]::Match($text, '(?im)^\W*Labels\W*:\s*([^\r\n]+)')
  if ($m.Success) {
    foreach ($kv in [regex]::Matches($m.Groups[1].Value, '(kind|size|risk)\s*=\s*([A-Za-z\-]+)')) { $l[$kv.Groups[1].Value.ToLower()] = $kv.Groups[2].Value.ToLower() }
  }
  foreach ($k in @('kind', 'size', 'risk')) {
    if (-not $l[$k]) { $x = [regex]::Match($text, "(?im)^\W*$k\W*:\s*([A-Za-z\-]+)"); if ($x.Success) { $l[$k] = $x.Groups[1].Value.ToLower() } }
  }
  if ($l.size) { $l.size = $l.size.ToUpper() }
  if ($l.risk -eq 'med') { $l.risk = 'medium' }
  return $l
}

# The role set a task's labels give (D-035): the kind's chains (as the tuner reordered them), then the risk and size
# rules. $null when the task has no known kind. Returns a pscustomobject like a profile (role -> chain text).
function Kind-Profile($labels, $sel, $tuning) {
  if (-not $labels -or -not $labels.kind -or -not $sel -or -not $sel.kinds -or -not $sel.kinds.PSObject.Properties[$labels.kind]) { return $null }
  $m = [ordered]@{}
  foreach ($p in $sel.kinds.($labels.kind).PSObject.Properties) { if ($p.Name -notin @('use', '_help')) { $m[$p.Name] = [string]$p.Value } }
  if ($tuning -and $tuning.kinds -and $tuning.kinds.PSObject.Properties[$labels.kind]) {
    foreach ($p in $tuning.kinds.($labels.kind).PSObject.Properties) { if ($p.Value) { $m[$p.Name] = [string]$p.Value } }
  }
  if ($labels.risk -and $sel.risk -and $sel.risk.PSObject.Properties[$labels.risk]) {
    foreach ($p in $sel.risk.($labels.risk).PSObject.Properties) { if (-not $p.Name.StartsWith('_')) { $m[$p.Name] = [string]$p.Value } }
  }
  if ($labels.size -and $sel.size -and $sel.size.PSObject.Properties[$labels.size]) {
    $sz = $sel.size.($labels.size)
    if ($sz.executorEffort -and $m.Contains('executor')) {
      $m['executor'] = (([string]$m['executor']) -split '\|' | ForEach-Object { (($_ -split '~') | ForEach-Object { ($_ -replace '@[a-z]+$', '') + "@$($sz.executorEffort)" }) -join '~' }) -join '|'
    }
  }
  if ($sel.refiner -and $sel.refiner.use -and -not $m.Contains('refiner')) { $m['refiner'] = [string]$sel.refiner.use }
  return [pscustomobject]$m
}

# Does this task get a refiner stage? (Size or risk listed in selection.refiner.when.)
function Needs-Refiner($labels, $sel) {
  if (-not $labels -or -not $sel -or -not $sel.refiner -or -not $sel.refiner.when) { return $false }
  return (($labels.size -and $labels.size -in @($sel.refiner.when.sizes)) -or ($labels.risk -and $labels.risk -in @($sel.refiner.when.risks)))
}

# Order candidates inside each "~" group by quota headroom (higher first), keeping the groups in order.
function Sort-ByHeadroom($cands, [scriptblock]$headroom) {
  # (Sort-Object has no -Stable in Windows PowerShell 5.1, so the position breaks ties.)
  $out = @(); $i = 0
  $rows = @(foreach ($c in $cands) { [pscustomobject]@{ c = $c; g = $(if ($null -ne $c.group) { [int]$c.group } else { 1000 + $i }); i = $i; h = 0.0 }; $i++ })
  foreach ($grp in @($rows | Group-Object g | Sort-Object { ($_.Group | Measure-Object i -Minimum).Minimum })) {
    if ($grp.Count -gt 1) { foreach ($r in $grp.Group) { $r.h = [double](& $headroom $r.c) } }
    $out += @($grp.Group | Sort-Object -Property @{ Expression = 'h'; Descending = $true }, @{ Expression = 'i'; Descending = $false } | ForEach-Object { $_.c })
  }
  return ,$out
}

# A task file's Relay: line (or any "role=spec, ..." text) -> @{ profile; roles = ordered role -> chain }.
# Old lines ("Relay: executor=codex, tester=claude") read the same way. Keys may be role or role.recheck.
function Parse-RelayLine([string]$line, $names = $script:modelNames) {
  $r = @{ profile = ''; roles = [ordered]@{} }
  $t = ([string]$line) -replace '^\W*Relay\W*:', ''
  foreach ($part in ($t -split '[,;]')) {
    $kv = $part.Trim() -split '=', 2
    if ($kv.Count -ne 2) { continue }
    # Markdown around the line (**Relay:** `...`) leaves * and ` on the edges.
    $k = ($kv[0] -replace '^[^A-Za-z]+', '').Trim().ToLower(); $v = $kv[1].Trim().Trim('`', '"', "'", '*', ' ')
    if (-not $k -or -not $v) { continue }
    if ($k -eq 'profile') { $r.profile = $v.ToLower(); continue }
    if ($k -notmatch '^[a-z][a-z0-9-]*(\.recheck)?$') { continue }
    $r.roles[$k] = Parse-Chain $v $names
  }
  return $r
}

# A profile object (from JSON: role -> "spec|spec" or [spec, spec]) -> ordered role -> chain.
function Convert-Profile($p, $names = $script:modelNames) {
  $m = [ordered]@{}
  if (-not $p) { return $m }
  foreach ($prop in $p.PSObject.Properties) {
    $k = $prop.Name.ToLower()
    if ($k.StartsWith('_') -or $k -eq 'extends' -or $k -notmatch '^[a-z][a-z0-9-]*(\.recheck)?$') { continue }
    $v = $prop.Value
    $text = if ($v -is [array]) { ($v | ForEach-Object { [string]$_ }) -join '|' } else { [string]$v }
    if ($text.Trim()) { $m[$k] = Parse-Chain $text $names }
  }
  return $m
}

# A named profile: the project's own (.ai/relay-profile.json "profiles") wins over relay-defaults.json "selection.profiles".
# "extends": "content-site" starts from that profile (looked up the same way) and changes only the roles it names.
function Find-Profile([string]$name, $project, $global, [int]$depth = 0) {
  $name = ([string]$name).Trim().ToLower()
  if (-not $name -or $depth -gt 4) { return $null }
  $own = $null
  foreach ($src in @($project, $global)) {
    if ($src -and $src.PSObject.Properties['profiles'] -and $src.profiles.PSObject.Properties[$name]) { $own = $src.profiles.$name; break }
  }
  if (-not $own) { return $null }
  if (-not $own.PSObject.Properties['extends'] -or -not $own.extends) { return $own }
  $base = $null
  $bn = ([string]$own.extends).Trim().ToLower()
  # A project profile may extend the global profile of the same name ("content" extends "content").
  if ($bn -eq $name -and $global -and $global.PSObject.Properties['profiles'] -and $global.profiles.PSObject.Properties[$bn]) { $base = $global.profiles.$bn }
  else { $base = Find-Profile $bn $project $global ($depth + 1) }
  if (-not $base) { return $own }
  $m = [ordered]@{}
  foreach ($p in $base.PSObject.Properties) { $m[$p.Name] = $p.Value }
  foreach ($p in $own.PSObject.Properties) { if ($p.Name -ne 'extends') { $m[$p.Name] = $p.Value } }
  return [pscustomobject]$m
}

# Is this model name usable for this agent? (Model-Args throws if not.)
function Sel-ModelFits([string]$agent, [string]$model) {
  if (-not $model -or $model -eq 'default') { return $true }
  try { [void](Model-Args $agent $model); return $true } catch { return $false }
}

# The merge. $layers: ordered list of @{ source; roles = role -> chain } (most specific first).
# $base: @{ agent; effort } of the team role. $agentModels: relay-defaults selection.agentModels (agent -> role -> model).
# Returns @{ candidates = @(@{ agent; model; effort; agentFrom; modelFrom; effortFrom; explicitModel }); notes }.
function Resolve-Role([string]$role, $layers, $base, $agentModels) {
  $notes = @()
  $explicit = @('stage', 'task', 'run')
  $chain = $null; $agentFrom = 'team'; $ai = $layers.Count
  for ($k = 0; $k -lt $layers.Count; $k++) {
    $c = $layers[$k].roles[$role]
    if ($c -and @($c | Where-Object { $_.agent }).Count) { $chain = @($c | Where-Object { $_.agent }); $agentFrom = $layers[$k].source; $ai = $k; break }
  }
  if (-not $chain) { $chain = @(@{ agent = [string]$base.agent; model = ''; effort = ''; raw = '' }) }
  # A model (or effort) named at a MORE specific level than the one that chose the agent wins over the chain's own:
  # run -Model tester=sonnet beats a project profile's "tester=claude:haiku", as long as it is a model of that agent.
  $find = {
    param([string]$field, [string]$agent, [int]$from, [int]$to)
    for ($k = $from; $k -lt $to; $k++) {
      foreach ($s in @($layers[$k].roles[$role])) {
        if (-not $s -or -not $s.$field) { continue }
        if ($s.agent -and $s.agent -ne $agent) { continue }
        if ($field -eq 'model' -and -not (Sel-ModelFits $agent $s.model)) { continue }
        return @{ value = [string]$s.$field; source = $layers[$k].source }
      }
    }
    return $null
  }
  $cands = @()
  foreach ($c in $chain) {
    $x = @{ agent = $c.agent; model = $c.model; effort = $c.effort; agentFrom = $agentFrom; group = $c.group
            modelFrom = $(if ($c.model) { $agentFrom } else { '' }); effortFrom = $(if ($c.effort) { $agentFrom } else { '' }) }
    if ($x.model -and -not (Sel-ModelFits $x.agent $x.model)) { $notes += "$($x.model) is not a $($x.agent) model: ignored"; $x.model = ''; $x.modelFrom = '' }
    $hit = & $find 'model' $x.agent 0 $ai
    if ($hit) { $x.model = $hit.value; $x.modelFrom = $hit.source }
    if (-not $x.model) {
      $hit = & $find 'model' $x.agent ($ai + 1) $layers.Count
      if ($hit) { $x.model = $hit.value; $x.modelFrom = $hit.source }
    }
    foreach ($L in $layers) {
      foreach ($s in @($L.roles[$role])) {
        if ($s -and $s.model -and (-not $s.agent -or $s.agent -eq $x.agent) -and -not (Sel-ModelFits $x.agent $s.model)) { $notes += "$($L.source) model $($s.model) doesn't fit $($x.agent): skipped" }
      }
    }
    if (-not $x.model -and $agentModels -and $agentModels.PSObject.Properties[$x.agent]) {
      $am = $agentModels.($x.agent)
      $m = if ($am.PSObject.Properties[$role]) { [string]$am.$role } elseif ($am.PSObject.Properties['*']) { [string]$am.'*' } else { '' }
      if ($m -and (Sel-ModelFits $x.agent $m)) { $x.model = $m; $x.modelFrom = 'auto' }
    }
    $hit = & $find 'effort' $x.agent 0 $ai
    if ($hit) { $x.effort = $hit.value; $x.effortFrom = $hit.source }
    if (-not $x.effort) {
      $hit = & $find 'effort' $x.agent ($ai + 1) $layers.Count
      if ($hit) { $x.effort = $hit.value; $x.effortFrom = $hit.source }
    }
    if (-not $x.effort -and $base.effort) { $x.effort = [string]$base.effort; $x.effortFrom = 'team' }
    $x.explicitModel = ($x.modelFrom -in $explicit)
    $cands += ,$x
  }
  return @{ candidates = $cands; notes = $notes }
}

# Step one model down the agent's ladder (best first), not below the floor. '' when no step is possible.
function Step-Down([string]$agent, [string]$model, $ladders, [string]$floor) {
  if (-not $ladders -or -not $ladders.PSObject.Properties[$agent]) { return '' }
  $lad = @($ladders.$agent | ForEach-Object { ([string]$_).ToLower() })
  $cur = ([string]$model).ToLower()
  foreach ($k in $lad) { if ($cur -and $cur.Contains($k)) { $cur = $k; break } }
  $ix = [array]::IndexOf($lad, $cur)
  if ($ix -lt 0 -or $ix -ge $lad.Count - 1) { return '' }
  $fx = if ($floor) { [array]::IndexOf($lad, $floor.ToLower()) } else { $lad.Count - 1 }
  if ($fx -lt 0) { $fx = $lad.Count - 1 }
  if ($ix + 1 -gt $fx) { return '' }
  return $lad[$ix + 1]
}

# A model the relay should treat as free (OpenRouter ':free', its free router, or zero price in the live list).
function Sel-IsFree([string]$agent, [string]$model, $live) {
  if ($agent -ne 'opencode' -or -not $model) { return $false }
  if ($script:modelNames -and $script:modelNames['opencode'] -and $script:modelNames['opencode'].Contains($model)) { $model = $script:modelNames['opencode'][$model] }
  if ($model -like '*:free' -or $model -eq 'openrouter/free') { return $true }
  if ($live -and $live.ContainsKey($model)) { return ([double]$live[$model].inPrice -eq 0 -and [double]$live[$model].outPrice -eq 0) }
  return $false
}

# Read the task file's header, status, latest review verdict and Relay: line. $null when there is no such file.
function Read-TaskInfo([string]$folder, [string]$id) {
  if (-not $id) { return $null }
  $dir = Join-Path $folder '.ai\tasks'
  $file = Get-ChildItem $dir -Filter "$id*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
  if (-not $file) { return $null }
  $text = [IO.File]::ReadAllText($file.FullName)
  $lines = $text -split "`r?`n"
  $head = ($lines | Where-Object { $_ -match '^\s*#' } | Select-Object -First 1)
  $status = ''
  if ($head -match '(?i)status\s*:\s*([a-z\-]+)') { $status = $Matches[1].ToLower() }
  $rl = $lines | Where-Object { $_ -match '^\W*Relay\W*:' } | Select-Object -First 1
  # The latest verdict: only text under the last "Review" heading counts (a criterion may mention the words).
  $rv = [regex]::Matches($text, '(?im)^#{2,6}[^\r\n]*\bReview\b[^\r\n]*\r?$')
  $last = ''
  if ($rv.Count) {
    $tail = $text.Substring($rv[$rv.Count - 1].Index)
    $v = [regex]::Matches($tail, '\b(APPROVED|CHANGES_REQUESTED)\b')
    if ($v.Count) { $last = $v[$v.Count - 1].Groups[1].Value.ToUpper() }
  }
  return @{ id = $id; file = $file.Name; path = $file.FullName; head = [string]$head; status = $status
            relayLine = [string]$rl; lastVerdict = $last; written = $file.LastWriteTime; labels = (Read-Labels $text) }
}

# Skip the executor? Only when the task says its build is finished (status testing or done), the latest verdict in the
# file isn't CHANGES_REQUESTED, and git has a commit naming the task that changed files outside .ai/.
function Test-ExecutorDone([string]$folder, $info, [string]$gitExe) {
  if (-not $info -or $info.status -notin @('testing', 'done')) { return $false }
  if ($info.lastVerdict -eq 'CHANGES_REQUESTED') { return $false }
  if (-not $gitExe) { return $false }
  $r = Invoke-Native $gitExe @('-C', $folder, 'log', '--format=%H', "--grep=$($info.id)", '-n', '20') 30
  if ($r.Code -ne 0) { return $false }
  foreach ($h in @($r.Out -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{7,}$' })) {
    $f = Invoke-Native $gitExe @('-C', $folder, 'show', '--name-only', '--format=', $h) 30
    if (@($f.Out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\.ai/' }).Count) { return $true }
  }
  return $false
}

# Lines changed outside .ai/ between two commits (-1 when unknown).
function Changed-Lines([string]$folder, [string]$from, [string]$gitExe) {
  if (-not $from -or -not $gitExe) { return -1 }
  $r = Invoke-Native $gitExe @('-C', $folder, 'diff', '--numstat', $from, 'HEAD', '--', '.', ':(exclude).ai') 30
  if ($r.Code -ne 0) { return -1 }
  $n = 0
  foreach ($l in @($r.Out -split "`r?`n")) { if ($l -match '^(\d+)\s+(\d+)\s') { $n += [int]$Matches[1] + [int]$Matches[2] } }
  return $n
}

# Median of numbers (0 when none).
function Sel-Median($xs) {
  $a = @($xs | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
  if (-not $a.Count) { return 0.0 }
  return $a[[math]::Floor($a.Count / 2)]
}

# Expected cost in USD of one OpenCode stage on this OpenRouter model: this model's own median for the role if we have
# 2+ recorded stages, else typical tokens for the role (recorded medians, else defaults) times its input price
# (cache-read price when OpenRouter lists one: coding agents resend their context every step, so most input is cached).
function Estimate-ORCost([string]$model, [string]$role, $rows, $live, $defaultsTokens) {
  $own = @($rows | Where-Object { $_.agent -eq 'opencode' -and $_.model -eq $model -and $_.role -eq $role -and $null -ne $_.cost })
  if ($own.Count -ge 2) { return [math]::Round((Sel-Median ($own | ForEach-Object { $_.cost })), 4) }
  $tok = Sel-Median (@($rows | Where-Object { $_.role -eq $role -and $_.tokens } | Select-Object -Last 20 | ForEach-Object { $_.tokens }))
  if ($tok -le 0) { $tok = if ($defaultsTokens -and $defaultsTokens.PSObject.Properties[$role]) { [double]$defaultsTokens.$role } else { 2000000 } }
  if (-not $live -or -not $live.ContainsKey($model)) { return -1 }
  $m = $live[$model]
  $inP = [double]$m.inPrice
  $cache = if ($m.PSObject.Properties['cachePrice'] -and [double]$m.cachePrice -gt 0) { [double]$m.cachePrice } else { 0 }
  $per = if ($cache -gt 0) { 0.8 * $cache + 0.2 * $inP } else { $inP }
  return [math]::Round($tok * $per / 1e6 + ($tok * 0.02) * [double]$m.outPrice / 1e6, 4)
}

# Runtime switch file (.ai/relay/SWITCH.json, written by 'relay switch'): { at, scope: next|run, roles: { role: chain } }
# or { clear: true }. Returns @{ clear; scope; roles = role -> chain } or $null.
function Read-SwitchFile([string]$path, $names = $script:modelNames) {
  if (-not (Test-Path $path)) { return $null }
  $o = $null
  try { $o = ([IO.File]::ReadAllText($path)) | ConvertFrom-Json } catch { return @{ error = "can't read $path" } }
  $r = @{ clear = [bool]$o.clear; scope = $(if ([string]$o.scope -eq 'run') { 'run' } else { 'next' }); roles = [ordered]@{} }
  if ($o.roles) { foreach ($p in $o.roles.PSObject.Properties) { $r.roles[$p.Name.ToLower()] = Parse-Chain ([string]$p.Value) $names } }
  return $r
}

# Short text for one candidate: claude:sonnet@high.
function Format-Cand($c) {
  $t = [string]$c.agent
  if ($c.model) { $t += ":$($c.model)" }
  if ($c.effort -and $c.effort -ne 'default') { $t += "@$($c.effort)" }
  return $t
}
