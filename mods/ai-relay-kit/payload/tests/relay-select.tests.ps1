# Tests for the model-selection layer (D-034): relay-select.ps1 plus the selection functions inside ai-relay.ps1.
# Run:  powershell -ExecutionPolicy Bypass -File tests\relay-select.tests.ps1
# No Pester needed. The real functions are loaded from the scripts (ai-relay.ps1's by name, through the parser);
# quota, plan and OpenRouter look-ups are replaced by stubs, so nothing here starts an agent or uses the network.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:pass = 0; $script:fail = 0
function Check([string]$name, $got, $want) {
  if ("$got" -ceq "$want") { $script:pass++; Write-Host "  ok   $name" -ForegroundColor DarkGreen }
  else { $script:fail++; Write-Host "  FAIL $name`n       got:  $got`n       want: $want" -ForegroundColor Red }
}
function Throws([string]$name, [scriptblock]$sb) {
  try { & $sb; $script:fail++; Write-Host "  FAIL $name (no error)" -ForegroundColor Red } catch { $script:pass++; Write-Host "  ok   $name" -ForegroundColor DarkGreen }
}

# ---------- load ----------
. (Join-Path $root 'relay-select.ps1')
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ai-relay.ps1'), [ref]$null, [ref]$null)
$want = @('Quote-Arg', 'Invoke-Native', 'Model-Args', 'Sel-Of', 'Get-ProjectProfile', 'Sel-Budget', 'Find-RunTask', 'Get-SelLayers',
          'Candidate-Fits', 'Get-Demoted', 'Select-StageModel', 'OR-BudgetReason', 'Read-QueueTask', 'Read-SwitchFile', 'Pick-Replacement',
          'Get-Tuning', 'Pool-Headroom', 'Planner-Guide', 'Profile-List', 'Model-ValueText', 'Read-Json', 'Test-SkipPermissions')
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
  if ($f.Name -in $want) { . ([scriptblock]::Create($f.Extent.Text)) }
}
$script:modelNames = @{
  'claude'      = [ordered]@{ fable = 'claude-fable-5-2'; opus = 'claude-opus-5-5'; sonnet = 'claude-sonnet-5-5'; haiku = 'claude-haiku-5-5' }
  'codex'       = [ordered]@{ sol = 'gpt-6.2-sol'; astra = 'gpt-6.2-astra'; terra = 'gpt-6.1-terra'; luna = 'gpt-6-luna' }
  'antigravity' = [ordered]@{ hydrogen = 'gemini-4-hydrogen'; flash = 'gemini-3.8-flash'; opus = 'claude-opus-4-6-thinking'; sonnet = 'claude-sonnet-4-6'; 'gpt-oss' = 'gpt-oss-120b-medium' }
  'opencode'    = [ordered]@{ glm = 'z-ai/glm-5.3'; deepseek = 'deepseek/deepseek-v4.1-flash'; nemotron = 'nvidia/nemotron-3-ultra-550b-a55b:free' }
}
$script:sel = ((Get-Content (Join-Path $root 'relay-defaults.json') -Raw) | ConvertFrom-Json).selection
$script:dominated = @($script:sel.dominated)
$script:teamRoles = @(
  [pscustomobject]@{ role = 'planner';  agent = 'claude'; effort = 'high';   once = $true;  judge = $false }
  [pscustomobject]@{ role = 'executor'; agent = 'claude'; effort = 'high';   once = $false; judge = $false }
  [pscustomobject]@{ role = 'tester';   agent = 'claude'; effort = 'medium'; once = $false; judge = $false }
  [pscustomobject]@{ role = 'reviewer'; agent = 'claude'; effort = 'high';   once = $false; judge = $true })
$script:judgeRole = 'reviewer'
$first = @(); $loopStages = @('executor', 'tester', 'reviewer' | ForEach-Object { [pscustomobject]@{ Role = $_; Agent = 'claude' } })
$script:modelByRole = [ordered]@{}; $script:effortByRole = [ordered]@{ planner = 'high'; executor = 'high'; tester = 'medium'; reviewer = 'high' }
$Effort = 'recommended'; $RunProfile = ''; $HereTerminal = ''; $goalText = 'test goal'
$script:runStagesBound = $false; $script:runLoopBound = $false; $script:runModelBound = $false; $script:runEffortBound = $false; $script:runAgentRoles = @{}
$script:overrides = [ordered]@{}; $script:spend = @{ all = 0.0; openrouter = 0.0; tokens = [int64]0 }
$script:currentTask = ''; $script:relayStart = $null; $script:round = 0; $script:selNoFree = $false
$script:projProfile = $null; $script:projProfileAt = [datetime]::MinValue
function Reset-JobSel { $script:job = @{ testerEscalate = $false; missedModels = @(); roundTesters = @(); roundTesterFree = $false; roundBase = '' } }
Reset-JobSel
$script:gitExe = (Get-Command git | Select-Object -First 1).Source
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("relay-select-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:usageDir = Join-Path $tmp 'usage'; New-Item -ItemType Directory -Path $script:usageDir -Force | Out-Null
$Folder = Join-Path $tmp 'proj'; New-Item -ItemType Directory -Path (Join-Path $Folder '.ai\tasks') -Force | Out-Null
# Stubs: every agent fits unless a test says otherwise; OpenRouter lists two models.
$script:unfit = @{}
function Agent-Fits([string]$a, [string]$r) { return -not $script:unfit[$a] }
function Plan-5h([string]$a) { return @{ used = 99; resets = (Get-Date).AddHours(2) } }
function Agent-Installed([string]$a) { return $true }
function Quota-Out([string]$k) { return $null }
function Quota-Key([string]$a, [string]$s) { return "$a/$s" }
function Model-Short([string]$a, [string]$t) { return '' }
function OR-Key { return 'x' }
function Free-Allowed { return $true }
function OR-Budget { return @{ paidOk = $true; pace = 'weekly' } }
$script:live = @{
  'deepseek/deepseek-v4.1-flash' = [pscustomobject]@{ tools = $true; inPrice = 0.3; outPrice = 1.2; cachePrice = 0.03 }
  'z-ai/glm-5.3' = [pscustomobject]@{ tools = $true; inPrice = 0.6; outPrice = 2.2; cachePrice = 0 }
  'nvidia/nemotron-3-ultra-550b-a55b:free' = [pscustomobject]@{ tools = $true; inPrice = 0; outPrice = 0; cachePrice = 0 } }
function Get-ORModels { return $script:live }
function Pick-OpenCodeModel([string]$r, [string[]]$s = @()) { if ($script:selNoFree) { return 'deepseek/deepseek-v4.1-flash' }; return 'nvidia/nemotron-3-ultra-550b-a55b:free' }
function Pick-Agent([string]$r, [string]$x) { return @{ agent = 'codex'; model = '' } }
$script:used = @{ claude = 10; codex = 10 }
function Plan-UsedPercent([string]$a) { return [double]$script:used[$a] }
function Claude-Cap([string]$r) { return 75.0 }
$script:tuning = $null; $script:tuningAt = [datetime]::MinValue
$script:rows = @()
function Stat-Rows { return $script:rows }
function Git-Run([string[]]$a) { $r = Invoke-Native $script:gitExe (@('-C', $Folder) + $a) 30; if ($r.Code -ne 0) { throw "git $($a -join ' '): $($r.Err)" }; return $r.Out }
function Task([string]$id, [string]$head, [string]$relay, [string]$body = '') {
  $t = "# $id $head`r`n`r`n" + $(if ($relay) { "$relay`r`n" } else { '' }) + "`r`n## Goal`r`nx`r`n$body"
  [IO.File]::WriteAllText((Join-Path $Folder ".ai\tasks\$id.md"), $t)
}
function Pick([string]$role, [string]$agent = 'claude') { $s = Select-StageModel ([pscustomobject]@{ Role = $role; Agent = $agent }); return (Format-Cand $s) }

try {
  Write-Host "`nSpec parsing" -ForegroundColor Cyan
  $s = Parse-Spec 'claude:sonnet@high'; Check 'agent:model@effort' "$($s.agent) $($s.model) $($s.effort)" 'claude sonnet high'
  $s = Parse-Spec 'haiku@low'; Check 'bare model finds its agent' "$($s.agent) $($s.model) $($s.effort)" 'claude haiku low'
  $s = Parse-Spec 'codex'; Check 'agent only' "$($s.agent)|$($s.model)" 'codex|'
  $s = Parse-Spec 'opencode:nvidia/nemotron-3-ultra-550b-a55b:free'; Check 'OpenRouter id with :free' "$($s.agent) $($s.model)" 'opencode nvidia/nemotron-3-ultra-550b-a55b:free'
  $s = Parse-Spec 'z-ai/glm-5.3@medium'; Check 'bare OpenRouter id' "$($s.agent) $($s.model) $($s.effort)" 'opencode z-ai/glm-5.3 medium'
  $s = Parse-Spec 'agy:hydrogen'; Check 'agy alias' "$($s.agent) $($s.model)" 'antigravity hydrogen'
  $s = Parse-Spec '@xhigh'; Check 'effort only' "$($s.agent)|$($s.effort)" '|xhigh'
  $s = Parse-Spec 'sonnet-5.5'; Check 'Claude version name' "$($s.agent) $($s.model)" 'claude sonnet-5.5'
  $s = Parse-Spec 'here'; Check 'here' $s.agent 'here'
  Throws 'bad effort' { Parse-Spec 'claude:opus@extreme' }
  Throws 'unknown model' { Parse-Spec 'gpt-banana' }
  $c = Parse-Chain 'claude:sonnet | codex:sol@high'; Check 'chain' (($c | ForEach-Object { Format-Cand $_ }) -join ',') 'claude:sonnet,codex:sol@high'

  Write-Host "`nRelay: lines" -ForegroundColor Cyan
  $r = Parse-RelayLine 'Relay: executor=claude, tester=claude, reviewer=claude'
  Check 'old line' (($r.roles.Keys | ForEach-Object { "$_=$($r.roles[$_][0].agent)" }) -join ',') 'executor=claude,tester=claude,reviewer=claude'
  $r = Parse-RelayLine '**Relay:** `profile=content, executor=claude:sonnet@high, tester=claude:haiku|codex:luna, tester.recheck=haiku@low`'
  Check 'profile' $r.profile 'content'
  Check 'chain in a line' (($r.roles['tester'] | ForEach-Object { Format-Cand $_ }) -join '|') 'claude:haiku|codex:luna'
  Check 'recheck key' (Format-Cand $r.roles['tester.recheck'][0]) 'claude:haiku@low'

  Write-Host "`nModel names and versions" -ForegroundColor Cyan
  Check 'sonnet = pinned version' ((Model-Args 'claude' 'sonnet') -join ' ') '--model claude-sonnet-5-5'
  Check 'sonnet-5.5' ((Model-Args 'claude' 'sonnet-5.5') -join ' ') '--model claude-sonnet-5-5'
  Check 'opus-4.6 (older, by name)' ((Model-Args 'claude' 'opus-4.6') -join ' ') '--model claude-opus-4-6'
  Throws 'a codex name for claude' { Model-Args 'claude' 'sol' }
  Check 'codex' ((Model-Args 'codex' 'astra') -join ' ') '-m gpt-6.2-astra'

  Write-Host "`nFive levels (stage > task > run > project > global)" -ForegroundColor Cyan
  Check 'global: agentModels + team effort' (Pick 'executor') 'claude:sonnet@high'
  Check 'global: reviewer' (Pick 'reviewer') 'claude:opus@high'
  [IO.File]::WriteAllText((Join-Path $Folder '.ai\relay-profile.json'), '{ "default": "content", "profiles": { "content": { "extends": "content-site", "reviewer": "claude:opus@medium" } } }')
  Check 'project profile (extends content-site)' (Pick 'tester') 'claude:haiku@medium'
  Check 'project profile own change' (Pick 'reviewer') 'claude:opus@medium'
  $script:runModelBound = $true; $script:modelByRole = [ordered]@{ tester = 'sonnet' }
  Check 'run -Model beats project' (Pick 'tester') 'claude:sonnet@medium'
  Task 'T-001' 'Copy - status: planned' 'Relay: executor=claude, tester=codex, reviewer=claude'
  $script:currentTask = 'T-001'
  Check 'task agent beats run; run model not a codex model: ignored' (Pick 'tester') 'codex@medium'
  Task 'T-001' 'Copy - status: planned' 'Relay: tester=claude'
  Check 'task agent + run model (field by field)' (Pick 'tester') 'claude:sonnet@medium'
  $script:runModelBound = $false; $script:modelByRole = [ordered]@{}
  Check 'task agent + project model' (Pick 'tester') 'claude:haiku@medium'
  Task 'T-001' 'Copy - status: planned' 'Relay: profile=hard-debug'
  Check 'task profile' (Pick 'executor') 'claude:fable@high'
  $script:overrides['executor'] = @{ chain = (Parse-Chain 'codex:sol@xhigh'); scope = 'next' }
  Check 'stage switch beats task' (Pick 'executor') 'codex:sol@xhigh'
  $script:overrides.Clear()
  Task 'T-001' 'Copy - status: planned' ''
  $loopStages[1].Agent = 'codex'
  Check '-Loop not given: its agents are the team default, the project wins' (Pick 'tester') 'claude:haiku@medium'
  $script:runLoopBound = $true
  Check '-Loop given: run level beats the project' (Pick 'tester' 'codex') 'codex@medium'
  $loopStages[1].Agent = 'claude'
  Check '-Loop repeating the team agent is no choice' (Pick 'tester') 'claude:haiku@medium'
  $script:runEffortBound = $true; $Effort = 'none'
  Check '-Effort none = agent default effort for the run' (Pick 'tester') 'claude:haiku'
  $script:runEffortBound = $false; $Effort = 'recommended'
  $script:runLoopBound = $false
  Task 'T-001' 'Copy - status: planned' 'Relay: profile=hard-debug'
  $RunProfile = 'bulk-content'
  Check 'task profile beats run profile' (Pick 'executor') 'claude:fable@high'
  Task 'T-001' 'Copy - status: planned' ''
  Check 'run profile beats project' (Pick 'tester') 'claude:haiku@low'
  $RunProfile = ''

  Write-Host "`nChains and what fits" -ForegroundColor Cyan
  Task 'T-001' 'Copy - status: planned' 'Relay: executor=claude:sonnet@high|codex:sol@high'
  $script:unfit['claude'] = $true
  $sx = Select-StageModel ([pscustomobject]@{ Role = 'executor'; Agent = 'claude' })
  Check 'first candidate out of quota: next one' (Format-Cand $sx) 'codex:sol@high'
  Check 'the skip is explained' ([bool]($sx.info -match 'skipped claude:sonnet@high')) 'True'
  $script:unfit['codex'] = $true
  Check 'none fits: the first, fallback rules decide' (Pick 'executor') 'claude:sonnet@high'
  $script:unfit = @{}

  Write-Host "`nStep-down on small re-checks" -ForegroundColor Cyan
  Remove-Item (Join-Path $Folder '.ai\relay-profile.json')
  Task 'T-001' 'Copy - status: planned' ''
  Set-Location $Folder; [void](Git-Run @('init', '-q')); [void](Git-Run @('config', 'user.email', 't@t')); [void](Git-Run @('config', 'user.name', 't'))
  New-Item -ItemType Directory (Join-Path $Folder 'src') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $Folder 'src\a.txt'), "one`n"); [void](Git-Run @('add', '-A')); [void](Git-Run @('commit', '-qm', 'base'))
  $script:job.roundBase = (Git-Run @('rev-parse', 'HEAD')).Trim()
  [IO.File]::WriteAllText((Join-Path $Folder 'src\a.txt'), "one`ntwo`n"); [void](Git-Run @('commit', '-qam', 'small fix'))
  Check 'changed lines' (Changed-Lines $Folder $script:job.roundBase $script:gitExe) 1
  $script:round = 1
  Check 'tester sonnet -> haiku' (Pick 'tester') 'claude:haiku@medium'
  Check 'reviewer opus -> sonnet' (Pick 'reviewer') 'claude:sonnet@high'
  Check 'executor never' (Pick 'executor') 'claude:sonnet@high'
  Task 'T-001' 'Copy - status: planned' 'Relay: tester=claude:sonnet'
  Check 'a model named in the task is kept' (Pick 'tester') 'claude:sonnet@medium'
  Task 'T-001' 'Copy - status: planned' 'Relay: profile=content-site'
  Check 'profile tester.recheck is used' (Pick 'tester') 'claude:haiku@low'
  Task 'T-001' 'Copy - status: planned' ''
  [IO.File]::WriteAllText((Join-Path $Folder 'src\b.txt'), (('x' * 10 + "`n") * 300)); [void](Git-Run @('add', '-A')); [void](Git-Run @('commit', '-qm', 'big fix'))
  Check 'a big fix keeps the model' (Pick 'tester') 'claude:sonnet@medium'
  Check 'Step-Down floor' (Step-Down 'claude' 'sonnet' $script:sel.stepDown.ladders 'sonnet') ''
  Check 'Step-Down from a full id' (Step-Down 'claude' 'claude-opus-5-5' $script:sel.stepDown.ladders 'haiku') 'sonnet'

  Write-Host "`nFree testers are never the only check" -ForegroundColor Cyan
  $script:round = 0
  Task 'T-001' 'Copy - status: planned' 'Relay: tester=opencode:nemotron, reviewer=opencode:nemotron|claude:opus'
  Check 'free tester allowed first' (Pick 'tester') 'opencode:nemotron@medium'
  $script:job.roundTesterFree = $true
  $sx = Select-StageModel ([pscustomobject]@{ Role = 'reviewer'; Agent = 'claude' })
  Check 'judge after a free tester is not free' (Format-Cand $sx) 'claude:opus@high'
  Check 'and the flag is set' $script:selNoFree 'True'
  $script:job.testerEscalate = $true; $script:job.missedModels = @('opencode:nvidia/nemotron-3-ultra-550b-a55b:free')
  Check 'escalated tester' (Pick 'tester') 'claude:sonnet@high'
  Reset-JobSel

  Write-Host "`nOpenRouter cost and budget" -ForegroundColor Cyan
  # 3M tokens x (0.8 x 0.03 cached + 0.2 x 0.30) / 1M + 2 % output x 1.20 / 1M = 0.252 + 0.072
  Check 'estimate from cache price' (Estimate-ORCost 'deepseek/deepseek-v4.1-flash' 'executor' @() $script:live $script:sel.typicalTokens) 0.324
  $script:rows = @(1..3 | ForEach-Object { [pscustomobject]@{ agent = 'opencode'; model = 'z-ai/glm-5.3'; role = 'executor'; cost = 1.8; tokens = 3000000 } })
  Check 'estimate from own history' (Estimate-ORCost 'z-ai/glm-5.3' 'executor' $script:rows $script:live $null) 1.8
  Check 'GLM executor over the stage cap' ([bool](OR-BudgetReason 'z-ai/glm-5.3' 'executor')) 'True'
  Check 'DeepSeek tester fits' (OR-BudgetReason 'deepseek/deepseek-v4.1-flash' 'tester') ''
  $script:spend.openrouter = 3.0
  Check 'run budget spent' ([bool]((OR-BudgetReason 'deepseek/deepseek-v4.1-flash' 'tester') -match 'spent')) 'True'
  $script:spend.openrouter = 0.0; $script:rows = @()

  Write-Host "`nLearned: models that keep missing are left out" -ForegroundColor Cyan
  Task 'T-001' 'Copy - status: planned' ''
  [IO.File]::WriteAllText((Join-Path $Folder '.ai\relay-profile.json'), '{ "default": "p", "profiles": { "p": { "tester": "opencode:nemotron|claude:haiku" } } }')
  1..2 | ForEach-Object { Add-Content (Join-Path $script:usageDir 'tester-misses.jsonl') (([ordered]@{ at = (Get-Date).ToString('o'); project = 'proj'; agent = 'opencode'; model = 'nemotron' }) | ConvertTo-Json -Compress) }
  Check 'demoted after 2 misses' (Pick 'tester') 'claude:haiku@medium'
  Task 'T-001' 'Copy - status: planned' 'Relay: tester=opencode:nemotron'
  Check 'but kept when the task names it' (Pick 'tester') 'opencode:nemotron@medium'
  Remove-Item (Join-Path $Folder '.ai\relay-profile.json')

  Write-Host "`nSkip the executor when the work is done" -ForegroundColor Cyan
  Task 'T-002' 'Thing - status: testing' 'Relay: executor=claude'
  [IO.File]::WriteAllText((Join-Path $Folder 'src\c.txt'), "c`n"); [void](Git-Run @('add', '-A')); [void](Git-Run @('commit', '-qm', 'T-002: build it'))
  Check 'testing + committed work' (Test-ExecutorDone $Folder (Read-TaskInfo $Folder 'T-002') $script:gitExe) 'True'
  Task 'T-002' 'Thing - status: testing' 'Relay: executor=claude' "`r`n## Review`r`n### Review 1 | CHANGES_REQUESTED`r`nfix it"
  Check 'changes requested: run it' (Test-ExecutorDone $Folder (Read-TaskInfo $Folder 'T-002') $script:gitExe) 'False'
  Task 'T-002' 'Thing - status: done' '' "`r`n## Review`r`n### Review 1 | CHANGES_REQUESTED`r`n### Review 2 | APPROVED"
  Check 'approved after changes: skip' (Test-ExecutorDone $Folder (Read-TaskInfo $Folder 'T-002') $script:gitExe) 'True'
  Task 'T-003' 'Other - status: testing' '' 'Acceptance: the word APPROVED appears; no CHANGES_REQUESTED'
  [void](Git-Run @('add', '-A')); [void](Git-Run @('commit', '-qm', 'T-003: plan only'))
  Check 'only .ai/ committed: run it' (Test-ExecutorDone $Folder (Read-TaskInfo $Folder 'T-003') $script:gitExe) 'False'
  Task 'T-004' 'New - status: planned' ''
  Check 'planned: run it' (Test-ExecutorDone $Folder (Read-TaskInfo $Folder 'T-004') $script:gitExe) 'False'

  Write-Host "`nRuntime switch file" -ForegroundColor Cyan
  $sf = Join-Path $tmp 'SWITCH.json'
  [IO.File]::WriteAllText($sf, '{"scope":"run","roles":{"executor":"codex:sol@high|claude:sonnet"}}')
  $sw = Read-SwitchFile $sf; Check 'scope run' $sw.scope 'run'
  Check 'chain' (($sw.roles['executor'] | ForEach-Object { Format-Cand $_ }) -join '|') 'codex:sol@high|claude:sonnet'
  [IO.File]::WriteAllText($sf, '{"clear":true}'); Check 'clear' (Read-SwitchFile $sf).clear 'True'

  Write-Host "`nQueue task reading" -ForegroundColor Cyan
  Task 'T-005' 'Copy - status: planned' 'Relay: executor=claude:sonnet@high|codex:sol, tester=claude:haiku, reviewer=claude:opus'
  $q = Read-QueueTask 'T-005'
  Check 'stages take the first agent' (($q.stages | ForEach-Object { "$($_.Role)=$($_.Agent)" }) -join ',') 'executor=claude,tester=claude,reviewer=claude'
  Check 'shown with models' $q.agents 'executor=claude:sonnet@high|codex:sol@high, tester=claude:haiku@medium, reviewer=claude:opus@high'
  Task 'T-006' 'Bad - status: planned' 'Relay: tester=codex:haiku'
  Throws 'a model of another agent is refused' { Read-QueueTask 'T-006' }

  Write-Host "`nReplacement after a stall" -ForegroundColor Cyan
  $e = @{ agent = 'claude'; model = 'claude-sonnet-5-5'; chain = 'claude:sonnet@high | codex:sol@high' }
  $p = Pick-Replacement ([pscustomobject]@{ Role = 'executor' }) $e $false
  Check 'next agent in the chain' "$($p.agent):$($p.model)" 'codex:sol'

  Write-Host "`nDaytime permissions, opt-in per project (D-036)" -ForegroundColor Cyan
  Check 'not listed: checks stay' (Test-SkipPermissions $Folder @('other-site') $false $false).skip 'False'
  Check 'listed by folder name' (Test-SkipPermissions $Folder @('PROJ') $false $false).skip 'True'
  Check 'listed by full path' (Test-SkipPermissions $Folder @("$Folder\") $false $false).skip 'True'
  Check '"all"' (Test-SkipPermissions $Folder @('all') $false $false).skip 'True'
  Check 'empty list' (Test-SkipPermissions $Folder @() $false $false).skip 'False'
  Check '-SkipPermissions for one run' (Test-SkipPermissions $Folder @() $true $false).skip 'True'
  Check '-KeepPermissions always wins' (Test-SkipPermissions $Folder @('all') $true $true).skip 'False'

  # ===================== v2 (D-035) =====================
  Write-Host "`nTask labels" -ForegroundColor Cyan
  $l = Read-Labels "# T-9 x`r`nLabels: kind=ui, size=m, risk=med`r`n"
  Check 'one Labels line' "$($l.kind) $($l.size) $($l.risk)" 'ui M medium'
  $l = Read-Labels "Kind: assets`r`nSize: S`r`nRisk: low`r`n"
  Check 'separate lines' "$($l.kind) $($l.size) $($l.risk)" 'assets S low'
  Check 'refiner for L' (Needs-Refiner @{ size = 'L'; risk = 'low' } $script:sel) 'True'
  Check 'refiner for high risk' (Needs-Refiner @{ size = 'S'; risk = 'high' } $script:sel) 'True'
  Check 'no refiner for M, medium' (Needs-Refiner @{ size = 'M'; risk = 'medium' } $script:sel) 'False'

  Write-Host "`nKind matrix (kind x risk x size), all agents" -ForegroundColor Cyan
  $kp = Kind-Profile @{ kind = 'ui'; size = 'L'; risk = 'high' } $script:sel $null
  Check 'ui executor, L = xhigh' $kp.executor 'antigravity:hydrogen@xhigh|claude:sonnet@xhigh'
  Check 'high risk reviewer' $kp.reviewer 'claude:opus@xhigh'
  Check 'high risk tester' $kp.tester 'claude:sonnet@high'
  Check 'refiner chain' $kp.refiner 'claude:opus@high|codex:sol@high'
  $tun = [pscustomobject]@{ kinds = [pscustomobject]@{ ui = [pscustomobject]@{ executor = 'claude:sonnet@high|antigravity:hydrogen@high' } } }
  Check 'tuner overlay wins over the base kind' (Kind-Profile @{ kind = 'ui'; size = 'M'; risk = 'medium' } $script:sel $tun).executor 'claude:sonnet@high|antigravity:hydrogen@high'
  $script:round = 0; Reset-JobSel
  Remove-Item (Join-Path $Folder '.ai\relay-profile.json') -ErrorAction SilentlyContinue
  Task 'T-001' 'Logo - status: planned' 'Labels: kind=assets, size=S, risk=medium'
  Check 'assets -> Codex' (Pick 'executor') 'codex:sol@high'
  Task 'T-001' 'Copy - status: planned' 'Labels: kind=content, size=S, risk=low'
  Check 'content low risk reviewer' (Pick 'reviewer') 'claude:sonnet@high'
  Task 'T-001' 'Copy - status: planned' "Labels: kind=content, size=S, risk=medium`r`nRelay: executor=claude:opus@high"
  Check 'a Relay: line still overrides the labels' (Pick 'executor') 'claude:opus@high'
  $script:runModelBound = $true; $script:modelByRole = [ordered]@{ executor = 'haiku' }
  Task 'T-001' 'Copy - status: planned' 'Labels: kind=content, size=S, risk=medium'
  Check 'labels (task level) beat run -Model' (Pick 'executor') 'claude:sonnet@high'
  $script:runModelBound = $false; $script:modelByRole = [ordered]@{}

  Write-Host "`nEqually good candidates start where quota is left" -ForegroundColor Cyan
  Task 'T-001' 'Calc - status: planned' 'Labels: kind=logic, size=M, risk=medium'
  $script:used = @{ claude = 70; codex = 20 }
  Check 'Claude near its reserve: Codex first' (Pick 'executor') 'codex:sol@high'
  $script:used = @{ claude = 10; codex = 60 }
  Check 'Codex busier: Claude first' (Pick 'executor') 'claude:sonnet@high'
  $script:used = @{ claude = 10; codex = 35 }   # Claude 75 % reserve - 10 = 65; Codex 100 - 35 = 65
  Check 'a tie keeps the written order' (Pick 'executor') 'claude:sonnet@high'
  $script:used = @{ claude = 10; codex = 10 }

  Write-Host "`nExploration (1 in 10 low-risk tasks)" -ForegroundColor Cyan
  [IO.File]::WriteAllText((Join-Path $script:usageDir 'explore-counter.json'), '{"lowRisk":9}')
  Task 'T-001' 'Copy - status: planned' 'Labels: kind=content, size=S, risk=low'
  Reset-JobSel
  $sx = Select-StageModel ([pscustomobject]@{ Role = 'executor'; Agent = 'claude' })
  Check 'the 10th low-risk task explores' (Format-Cand $sx) 'claude:haiku@high'
  Check 'marked as exploring' $sx.explore 'True'
  Check 'reviewer never explores' (Pick 'reviewer') 'claude:sonnet@high'
  Reset-JobSel
  Check 'the 11th does not' (Pick 'executor') 'claude:sonnet@high'
  Task 'T-001' 'Copy - status: planned' 'Labels: kind=content, size=S, risk=medium'
  [IO.File]::WriteAllText((Join-Path $script:usageDir 'explore-counter.json'), '{"lowRisk":9}'); Reset-JobSel
  Check 'medium risk never explores' (Pick 'executor') 'claude:sonnet@high'

  Write-Host "`nPlanner: effort, guide, what worked" -ForegroundColor Cyan
  $first = @([pscustomobject]@{ Role = 'planner'; Agent = 'claude' })
  $script:currentTask = ''
  Check 'planner on a new project' (Pick 'planner') 'claude:opus@high'
  [IO.File]::WriteAllText((Join-Path $Folder '.ai\relay-profile.json'), '{ "projectType": "web-app", "complexity": "L", "risk": "high", "default": "full-app" }')
  Check 'planner on a big project: xhigh' (Pick 'planner') 'claude:opus@xhigh'
  $g = Planner-Guide
  Check 'guide knows the project' ([bool]($g -match 'This project is a web-app')) 'True'
  Remove-Item (Join-Path $Folder '.ai\relay-profile.json')
  $g = Planner-Guide
  Check 'guide asks for the project profile first' ([bool]($g -match 'FIRST.*relay-profile\.json.*projectType.*ecommerce')) 'True'
  Check 'guide lists the kinds and the Labels line' ([bool]($g -match "Labels: kind=<kind>, size=<S\|M\|L>, risk=<low\|medium\|high>.*assets = images")) 'True'
  Check 'guide has no double quotes (agy/opencode argv)' ([bool]($g.Contains('"'))) 'False'
  [IO.File]::WriteAllText((Join-Path $script:usageDir 'selection-tuning.json'), '{ "kinds": {}, "whatWorked": ["ui tasks: antigravity:hydrogen approved 7 of 9"] }')
  Check 'guide passes on what worked' ([bool]((Planner-Guide) -match 'What worked in past relays: ui tasks: antigravity:hydrogen approved 7 of 9')) 'True'
  Remove-Item (Join-Path $script:usageDir 'selection-tuning.json')
  $first = @()

  Write-Host "`nDaily tuner" -ForegroundColor Cyan
  . (Join-Path $root 'tools\selection-tuner.ps1') -LibOnly
  Check 'short model names' ((Short-Model 'claude' 'claude-sonnet-5-5'), (Short-Model 'codex' 'gpt-6.2-sol'), (Short-Model 'antigravity' 'gemini-4-hydrogen') -join ',') 'sonnet,sol,hydrogen'
  $rl = 'r1'; $rows = @(); $k = 0
  function Row($kind, $role, $agent, $model, $round, $task, [switch]$stalled) { $script:k++; return [pscustomobject]@{ at = (Get-Date).ToString('o'); relay = 'r1'; project = 'p'; task = $task; round = $round; n = $script:k; kind = $kind; role = $role; agent = $agent; model = $model; state = 'done'; judge = ($role -eq 'reviewer'); verdict = ''; stalled = [bool]$stalled; cost = 0.1; minutes = 5 } }
  function Judge($task, $round, $v) { $script:k++; return [pscustomobject]@{ at = (Get-Date).ToString('o'); relay = 'r1'; project = 'p'; task = $task; round = $round; n = $script:k; kind = 'content'; role = 'reviewer'; agent = 'claude'; model = 'claude-opus-5-5'; state = 'done'; judge = $true; verdict = $v; stalled = $false; cost = 0.5; minutes = 5 } }
  # content executor: sonnet 6 tasks, 5 approved first time; haiku (explored) 6 tasks, all approved.
  for ($q = 1; $q -le 6; $q++) { $rows += Row 'content' 'executor' 'claude' 'claude-sonnet-5-5' 0 "S$q"; $rows += Judge "S$q" 0 $(if ($q -eq 1) { 'CHANGES_REQUESTED' } else { 'APPROVED' }) }
  for ($q = 1; $q -le 6; $q++) { $rows += Row 'content' 'executor' 'claude' 'claude-haiku-5-5' 0 "H$q"; $rows += Judge "H$q" 0 'APPROVED' }
  # content tester haiku: stalls 3 of 6.
  for ($q = 1; $q -le 6; $q++) { $rows += Row 'content' 'tester' 'claude' 'claude-haiku-5-5' 0 "S$q" -stalled:($q -le 3) }
  # ui executor: antigravity 2 of 6 approved, sonnet 6 of 6.
  for ($q = 1; $q -le 6; $q++) { $rows += Row 'ui' 'executor' 'antigravity' 'default' 0 "A$q"; $rows += Judge "A$q" 0 $(if ($q -le 2) { 'APPROVED' } else { 'CHANGES_REQUESTED' }) }
  for ($q = 1; $q -le 6; $q++) { $rows += Row 'ui' 'executor' 'claude' 'claude-sonnet-5-5' 0 "B$q"; $rows += Judge "B$q" 0 'APPROVED' }
  # Fix Judge rows' kind for ui tasks.
  foreach ($r in $rows) { if ($r.role -eq 'reviewer' -and $r.task -match '^[AB]') { $r.kind = 'ui' } }
  $units = Get-Units $rows @()
  Check 'score: sonnet content executor' $units['content|executor|claude:sonnet'].rate 0.833
  Check 'score: stalls counted' $units['content|tester|claude:haiku'].stalls 3
  $kinds = [pscustomobject]@{ content = [pscustomobject]@{ executor = 'claude:sonnet@high'; tester = 'claude:haiku@medium|claude:sonnet@medium'; reviewer = 'claude:sonnet@high' }
                              ui = [pscustomobject]@{ executor = 'antigravity:hydrogen@high|claude:sonnet@high'; tester = 'claude:sonnet@medium'; reviewer = 'claude:opus@high' } }
  $cfgT = [pscustomobject]@{ minSamples = 5; demoteRate = 0.3; margin = 0.15 }
  $dd = Get-Decisions $units $kinds ([pscustomobject]@{}) $cfgT
  $ce = @($dd.changes | Where-Object { $_.kind -eq 'content' -and $_.role -eq 'executor' }) | Select-Object -First 1
  Check 'safe: cheaper Haiku goes first (at least as good)' $ce.to 'claude:haiku@high|claude:sonnet@high'
  $ct = @($dd.changes | Where-Object { $_.kind -eq 'content' -and $_.role -eq 'tester' }) | Select-Object -First 1
  Check 'safe: a stalling tester is demoted' $ct.to 'claude:sonnet@medium|claude:haiku@medium'
  $pu = @($dd.proposals | Where-Object { $_.kind -eq 'ui' -and $_.role -eq 'executor' }) | Select-Object -First 1
  Check 'another agent doing better is only a proposal' $pu.to 'claude:sonnet@high|antigravity:hydrogen@high'
  Check 'and not applied by itself' (@($dd.changes | Where-Object { $_.kind -eq 'ui' }).Count) 0
  $dd2 = Get-Decisions $units $kinds ([pscustomobject]@{}) ([pscustomobject]@{ minSamples = 7; demoteRate = 0.3; margin = 0.15 })
  Check 'too few samples: no change' (@($dd2.changes).Count) 0
  $ww = Get-WhatWorked $units 5
  Check 'what worked' ([bool](($ww -join ';') -match 'ui tasks: claude:sonnet approved 6 of 6')) 'True'

  Write-Host "`nTuner run: apply, accept, dismiss, roll back" -ForegroundColor Cyan
  $tr = Join-Path $tmp 'tuner'; New-Item -ItemType Directory (Join-Path $tr 'usage') -Force | Out-Null
  $defs2 = (Get-Content (Join-Path $root 'relay-defaults.json') -Raw) | ConvertFrom-Json
  $defs2.selection.kinds = $kinds
  [IO.File]::WriteAllText((Join-Path $tr 'relay-defaults.json'), ($defs2 | ConvertTo-Json -Depth 12))
  [IO.File]::WriteAllText((Join-Path $tr 'usage\model-stats.jsonl'), ((@($rows | ForEach-Object { $_ | ConvertTo-Json -Compress })) -join "`n") + "`n")
  $tuner = Join-Path $root 'tools\selection-tuner.ps1'
  $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $tuner -Root $tr -Apply -Quiet
  $tj = (Get-Content (Join-Path $tr 'usage\selection-tuning.json') -Raw) | ConvertFrom-Json
  Check 'applied into the overlay' $tj.kinds.content.executor 'claude:haiku@high|claude:sonnet@high'
  Check 'proposal kept for the user' (@($tj.proposals | Where-Object { $_.kind -eq 'ui' }).Count) 1
  $led = @(Get-Content (Join-Path $tr 'usage\selection-ledger.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  Check 'ledger has the two safe changes' (@($led | Where-Object { $_.auto }).Count) 2
  $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $tuner -Root $tr -Apply -Quiet
  $led2 = @(Get-Content (Join-Path $tr 'usage\selection-ledger.jsonl'))
  Check 'a second run changes nothing more' $led2.Count 2
  $pid1 = @($tj.proposals | Where-Object { $_.kind -eq 'ui' })[0].id
  $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $tuner -Root $tr -Accept $pid1
  $tj = (Get-Content (Join-Path $tr 'usage\selection-tuning.json') -Raw) | ConvertFrom-Json
  Check 'accepted proposal in the overlay' $tj.kinds.ui.executor 'claude:sonnet@high|antigravity:hydrogen@high'
  $cheapId = @($led | Where-Object { $_.action -eq 'cheaper' })[0].id
  $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $tuner -Root $tr -Rollback $cheapId
  $tj = (Get-Content (Join-Path $tr 'usage\selection-tuning.json') -Raw) | ConvertFrom-Json
  Check 'rolled back to the base chain' ([bool]$tj.kinds.PSObject.Properties['content'] -and [bool]$tj.kinds.content.PSObject.Properties['executor']) 'False'

} finally {
  Set-Location $root
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
