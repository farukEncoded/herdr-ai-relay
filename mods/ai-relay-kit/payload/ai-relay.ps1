# ai-relay.ps1 - run a project through several AI agents in Herdr, one after another,
# then repeat the fix loop (executor -> tester -> reviewer) until the reviewer approves.
# Roles come from a team (-Team; "coding" built in, more in relay-defaults.json); its judge decides.
#
# Each stage opens a new Herdr tab in the project's space, starts that stage's agent with its
# role and the goal as the first message, waits until the agent has finished its protocol
# end-of-session steps, then starts the next stage.
#
# EASIEST: in a Herdr PowerShell tab inside your project's space, type  relay  and answer the questions
# (or pick "AI Relay" from Herdr's + menu). With no -Folder/-Goal it asks you everything.
# Or with options:
#   powershell -ExecutionPolicy Bypass -File "$HOME\.agents\protocol\ai-relay.ps1" -Folder "C:\Projects\todo-app" -Goal "a small Python to-do CLI app"
# Options:
#   -Stages "planner=claude,executor=antigravity,tester=codex,reviewer=claude"   first pass (role=agent, in order)
#           -Stages ""  skips the first pass (e.g. to only run fix rounds on an existing project)
#   -Loop   "executor=antigravity,tester=codex,reviewer=claude"   repeated while the reviewer requests changes
#   -MaxRounds 3            fix rounds at most (0 = no loop)
#   -AskEachRound           ask you before starting each fix round
#   -TimeoutMin 60          minutes per stage before asking you what to do
#   -NoRulesCheck           skip the "which rules / which signature" check question
#   -Queue                  big plans: the team's planning role splits the goal into task files, each with a line
#           "Relay: executor=codex, tester=claude, reviewer=claude" (agents picked from "strengths" in
#           relay-defaults.json) and writes their order to .ai/relay/queue.txt. You approve the queue; then each task
#           gets its own mini-relay (the non-planning roles, with fix rounds) with its own agents, one task at a time.
#   -Tasks "T-010,T-011"    queue these existing task files instead of planning (their Relay: lines still apply).
#   -Team coding            which team: its roles, order, each role's job, agents, effort and its judge.
#           "coding" (planner, executor, tester, reviewer) is built in; add your own under "teams" in
#           relay-defaults.json. Stages/Loop then default to the team's roles (once-roles only in the first pass).
#   -Effort "recommended"   reasoning effort per role, for whichever agent has that role
#           (Claude/Antigravity: --effort, Codex: -c model_reasoning_effort=). Levels: low, medium,
#           high, xhigh, max, or default (the agent's own setting). "recommended" =
#           planner=high,executor=high,tester=medium,reviewer=high. "none" = every agent's own default.
#           Roles not listed use the agent's default. e.g. -Effort "planner=xhigh,tester=low"
#           The executor always runs at high or above (xhigh/max are kept), whatever is asked.
#   -Model "default"        model per role (default = each agent's own). Names per agent:
#           claude: fable, opus, sonnet, haiku   codex: sol, astra, terra, luna
#           antigravity: flash, sonnet, opus, gpt-oss   (or a full model id). e.g. -Model "planner=fable,tester=astra"
#           Antigravity's Claude/GPT models take no effort level (they think at a fixed level).
#
# CONTROL WHILE IT RUNS:
#   STOP  : create the file  <project>\.ai\relay\STOP   -> stops after the current stage finishes
#   PAUSE : create the file  <project>\.ai\relay\PAUSE  -> waits before the next stage until you delete it
#   Ctrl+C in the relay's tab -> stops the relay at once (agents already running keep running in their tabs)
#   Esc in an agent's tab     -> interrupts that agent's current turn (you can then talk to it yourself)

param(
  [string]$Folder = '',
  [string]$Goal = '',
  [string]$Stages = 'planner=claude,executor=antigravity,tester=codex,reviewer=claude',
  [string]$Loop = 'executor=antigravity,tester=codex,reviewer=claude',
  [int]$MaxRounds = 3,
  [switch]$AskEachRound,
  [int]$TimeoutMin = 60,
  [switch]$NoRulesCheck,
  [Alias('ClaudeEffort')][string]$Effort = 'recommended',
  [string]$Model = 'default',
  [string]$HereTerminal = '',   # an agent's own Herdr terminal (its HC_TERMINAL_ID) that takes the stages marked 'here'
  [string]$HereAgent = '',      # which agent that is: claude, codex or antigravity
  [string]$Team = '',           # which team's roles, order and jobs (relay-defaults.json "teams"); default "coding"
  [switch]$Queue,               # plan first, then one mini-relay per task, each with the agents its task file names
  [switch]$PauseOnUnapproved,   # hold the queue if a task still lacks approval after its fix rounds
  [switch]$KeepPermissions,     # keep normal agent permissions even in overnight mode
  [string]$Tasks = '',          # queue these task ids (e.g. "T-010,T-011") instead of planning them
  [switch]$Overnight,           # unattended: no questions, all permissions skipped, own git branch, watchdog, cycles
  [string]$Until = '',          # overnight: no new task after this time ("08:00"), or "done" = no time limit
  [int]$MaxCycles = -1,         # overnight: plan-and-run cycles at most (queue mode); 0 = no limit; -1 = defaults
  [switch]$MakeOvernight,       # don't run a relay: switch the relay running in this project (or -Folder) to overnight
  [switch]$InHerdrTab   # internal: set when the relay relaunched itself into its own Herdr tab
)
$ErrorActionPreference = 'Stop'

# ---------- 'relay overnight': switch the running relay of this project to overnight mode ----------
# Same as the AI Project panel's "Make overnight" button: drop .ai/relay/OVERNIGHT; the relay picks it up at its next
# check (within seconds, also while it waits for an answer).
if ($MakeOvernight) {
  $dir = if ($Folder) { (Resolve-Path $Folder).Path } else { (Get-Location).Path }
  while ($dir -and -not (Test-Path (Join-Path $dir '.ai\relay\status.json'))) { $up = Split-Path $dir -Parent; if ($up -eq $dir) { $dir = $null } else { $dir = $up } }
  if (-not $dir) { Write-Host 'No relay found here (no .ai/relay/status.json in this folder or above).' -ForegroundColor Red; exit 1 }
  $s = (Get-Content (Join-Path $dir '.ai\relay\status.json') -Raw) | ConvertFrom-Json
  if ($s.state -notin @('running', 'waiting', 'paused')) { Write-Host "The relay in $dir isn't running (state: $($s.state))." -ForegroundColor Red; exit 1 }
  $req = [ordered]@{ at = (Get-Date).ToString('o') }
  if ($Until) { $req.until = $Until }
  if ($PSBoundParameters.ContainsKey('MaxCycles')) { $req.maxCycles = $MaxCycles }
  Set-Content -Path (Join-Path $dir '.ai\relay\OVERNIGHT') -Value ($req | ConvertTo-Json -Compress) -Encoding ASCII
  $lim = @(); if ($Until) { $lim += $(if ($Until -eq 'done') { 'until all tasks are done' } else { "until $Until" }) }
  if ($PSBoundParameters.ContainsKey('MaxCycles')) { $lim += $(if ($MaxCycles -eq 0) { 'no cycle limit' } else { "at most $MaxCycles cycle(s)" }) }
  $limText = if ($lim) { $lim -join ', ' } else { 'with your overnight defaults' }
  if ($s.overnight) { Write-Host "Done: that relay is already overnight; it takes the new limits ($limText) at its next check."; exit 0 }
  Write-Host "Done: the relay in $dir switches to overnight mode at its next check ($limText): no more questions,"
  Write-Host 'permissions skipped for the next stages, a new git branch from the next stage on.'
  exit 0
}

# ---------- your defaults: relay-defaults.json next to this script ----------
# Values you don't pass come from there (then from the param defaults above). The Herdr launcher and
# the agents' 'relay' guide read the same file, so one edit changes the defaults everywhere.
$script:defaults = $null
$defaultsPath = Join-Path $PSScriptRoot 'relay-defaults.json'
try { if (Test-Path $defaultsPath) { $script:defaults = (Get-Content $defaultsPath -Raw) | ConvertFrom-Json } }
catch { Write-Warning "relay-defaults.json can't be read ($($_.Exception.Message)); using built-in defaults." }
function Default-Of([string]$key, $fallback) {
  if ($script:defaults -and $script:defaults.PSObject.Properties[$key] -and $null -ne $script:defaults.$key) { return $script:defaults.$key }
  return $fallback
}
# ---------- teams: which roles, in what order, each one's job ----------
# A team is a list of roles. once = first pass only (like the planner). judge = says APPROVED or
# CHANGES_REQUESTED; while it asks for changes, the non-once roles run again (fix rounds).
# agent / effort = that role's defaults. "coding" is built in; relay-defaults.json "teams" adds or overrides.
$script:builtinCoding = @(
  [pscustomobject]@{ role = 'planner';  agent = 'claude';      effort = 'high';   once = $true;  judge = $false
    job = 'Write or update the task file .ai/tasks/T-xxx.md (goal, approach, files, acceptance criteria). No production code.' }
  [pscustomobject]@{ role = 'executor'; agent = 'antigravity'; effort = 'high';   once = $false; judge = $false
    job = 'Implement the task file. Do not change its acceptance criteria; note any deviation in its Notes.' }
  [pscustomobject]@{ role = 'tester';   agent = 'codex';       effort = 'medium'; once = $false; judge = $false
    job = 'Test against the acceptance criteria in the task file, write tests, fill in its Test report. Report bugs instead of fixing production code.' }
  [pscustomobject]@{ role = 'reviewer'; agent = 'claude';      effort = 'high';   once = $false; judge = $true
    job = 'Review the changes against the task file and .ai/DECISIONS.md and write your findings in its Review.' }
)
function Get-Team([string]$name) {
  $raw = $null
  $teams = Default-Of 'teams' $null
  if ($teams -and $teams.PSObject.Properties[$name]) { $raw = @($teams.$name) }
  elseif ($name -eq 'coding') { $raw = $script:builtinCoding }
  else {
    $known = @('coding') + $(if ($teams) { @($teams.PSObject.Properties.Name) } else { @() }) | Select-Object -Unique
    throw "No team '$name'. Teams: $($known -join ', '). Add one under ""teams"" in relay-defaults.json."
  }
  $list = @()
  foreach ($r in $raw) {
    $role = ([string]$r.role).Trim().ToLower()
    if ($role -notmatch '^[a-z][a-z0-9-]*$') { throw "Team '$name': bad role name '$($r.role)' (use letters, digits, -)." }
    $list += [pscustomobject]@{
      role = $role; job = [string]$r.job; once = [bool]$r.once; judge = [bool]$r.judge
      agent = $(if ($r.agent) { ([string]$r.agent).ToLower() } else { 'claude' })
      effort = $(if ($r.effort) { ([string]$r.effort).ToLower() } else { 'default' })
    }
  }
  if (-not $list) { throw "Team '$name' has no roles." }
  if (-not ($list | Where-Object judge)) { $list[-1].judge = $true }   # no judge named: the last role judges
  if (@($list | Where-Object judge).Count -gt 1) { throw "Team '$name' has more than one judge role." }
  return ,$list
}
if (-not $Team) { $Team = [string](Default-Of 'team' 'coding') }
$Team = $Team.Trim().ToLower()
$script:teamRoles = Get-Team $Team
$script:judgeRole = ($script:teamRoles | Where-Object judge | Select-Object -First 1).role
$script:jobOf = @{}; foreach ($r in $script:teamRoles) { if ($r.job) { $script:jobOf[$r.role] = $r.job } }
# Old relay-defaults.json "roles" map (coding team only): still overrides those roles' agents.
$defRoles = Default-Of 'roles' $null
if ($Team -eq 'coding' -and $defRoles) { foreach ($r in $script:teamRoles) { if ($defRoles.PSObject.Properties[$r.role]) { $r.agent = [string]$defRoles.($r.role) } } }
if (-not $PSBoundParameters.ContainsKey('Stages')) { $Stages = ($script:teamRoles | ForEach-Object { "$($_.role)=$($_.agent)" }) -join ',' }
if (-not $PSBoundParameters.ContainsKey('Loop')) { $Loop = ($script:teamRoles | Where-Object { -not $_.once } | ForEach-Object { "$($_.role)=$($_.agent)" }) -join ',' }
if (-not $PSBoundParameters.ContainsKey('MaxRounds'))  { $MaxRounds  = [int](Default-Of 'maxRounds' $MaxRounds) }
if (-not $PSBoundParameters.ContainsKey('TimeoutMin')) { $TimeoutMin = [int](Default-Of 'timeoutMin' $TimeoutMin) }
if (-not $PSBoundParameters.ContainsKey('Effort'))     { $Effort     = [string](Default-Of 'effort' $Effort) }
if (-not $PSBoundParameters.ContainsKey('Model'))      { $Model      = [string](Default-Of 'model' $Model) }

# ---------- overnight mode settings (relay-defaults.json "overnight") ----------
$script:ovn = Default-Of 'overnight' $null
function Ovn-Of([string]$k, $fb) { if ($script:ovn -and $script:ovn.PSObject.Properties[$k] -and $null -ne $script:ovn.$k) { return $script:ovn.$k }; return $fb }
# When the night ends (whichever comes first): -Until "08:00" (no new task after that time) or "done" (no time
# limit), and -MaxCycles N (plan-and-run cycles; 0 = no limit; -1 = take relay-defaults.json). "done" with no cycle
# limit runs until the planner finds nothing worthwhile left.
function Set-NightLimits {
  $u = ([string]$script:Until).Trim().ToLower()
  if ($u -in @('done', 'none', 'all', 'finished', 'until done')) { $script:Until = 'done'; $script:untilAt = [datetime]::MaxValue; return }
  if ($u -match '^\d{1,2}$') { $u = "$($u):00" }   # "7" = 07:00
  $t = [datetime]::MinValue
  if ([datetime]::TryParse($u, [ref]$t)) {
    $at = (Get-Date).Date.Add($t.TimeOfDay); if ($at -le (Get-Date)) { $at = $at.AddDays(1) }; $script:untilAt = $at
  } else { throw "Overnight: can't read -Until '$($script:Until)' (use a time like 08:00, or 'done')." }
}
function Night-LimitText {
  $parts = @()
  if ($script:untilAt -ne [datetime]::MaxValue) { $parts += "until $($script:untilAt.ToString('ddd HH:mm'))" }
  if ($script:MaxCycles -gt 0) { $parts += "at most $($script:MaxCycles) cycle(s)" }
  if (-not $parts) { return 'until all tasks are done (no time or cycle limit)' }
  return ($parts -join ', ') + ', or earlier when nothing worthwhile is left'
}
function Apply-Overnight {
  if (-not $script:Until) { $script:Until = [string](Ovn-Of 'until' '07:00') }
  if ($script:MaxCycles -lt 0) { $script:MaxCycles = [int](Ovn-Of 'maxCycles' 3) }
  if (-not $script:boundTimeout) { $script:TimeoutMin = [int](Ovn-Of 'maxStageMinutes' 180) }
  $script:skipPerms = -not $KeepPermissions -and [bool](Ovn-Of 'skipPermissions' $true)
  $script:stallMin = [int](Ovn-Of 'stallMinutes' 30)
  $script:AskEachRound = $false
  Set-NightLimits
}
$script:boundTimeout = $PSBoundParameters.ContainsKey('TimeoutMin')
$script:skipPerms = $false; $script:stallMin = 30; $script:untilAt = [datetime]::MaxValue
if ($Overnight) { Apply-Overnight }

function Find-Exe([string]$name, [string[]]$dirs) {
  $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  foreach ($d in $dirs) { $p = Join-Path $d "$name.exe"; if (Test-Path $p) { return $p } }
  return $null
}

# Effort per role. "recommended" thinks hard where mistakes are expensive (plan, build, review)
# and saves time on the tester, which mostly runs commands against written acceptance criteria.
$script:effortLevels = @('low', 'medium', 'high', 'xhigh', 'max', 'default')
# "recommended" = each team role's own effort (coding: planner high, executor high, tester medium, reviewer high).
$script:effortRecommended = (($script:teamRoles | Where-Object { $_.effort -ne 'default' } | ForEach-Object { "$($_.role)=$($_.effort)" }) -join ',')
function Parse-Effort([string]$text) {
  $map = [ordered]@{}
  $t = $text.Trim()
  if ($t -eq 'recommended') { $t = $script:effortRecommended }
  if (-not $t -or $t -eq 'none') { return $map }
  foreach ($part in ($t -split ',')) {
    $kv = $part.Trim() -split '=', 2
    $role = $kv[0].Trim().ToLower(); $lvl = $(if ($kv.Count -gt 1) { $kv[1].Trim().ToLower() } else { '' })
    if ($role -notmatch '^[a-z][a-z0-9-]*$' -or $lvl -notin $script:effortLevels) {
      throw "Bad -Effort part '$part'. Use role=level, e.g. planner=high (levels: $($script:effortLevels -join ', '))."
    }
    $map[$role] = $lvl
  }
  return $map
}
# Model per role. Short names per agent (a full model id also works); 'default' = the agent's own setting
# (Claude and Codex: their configured model; Antigravity: the "model" in ~/.gemini/antigravity-cli/settings.json).
$script:modelNames = @{
  'claude'      = [ordered]@{ fable = 'fable'; opus = 'opus'; sonnet = 'sonnet'; haiku = 'haiku' }
  'codex'       = [ordered]@{ sol = 'gpt-6.2-sol'; astra = 'gpt-6.2-astra'; terra = 'gpt-6.1-terra'; luna = 'gpt-6-luna' }
  'antigravity' = [ordered]@{ hydrogen = 'gemini-4-hydrogen'; flash = 'gemini-3.8-flash'; opus = 'claude-opus-4-6-thinking'
                              sonnet = 'claude-sonnet-4-6'; 'gpt-oss' = 'gpt-oss-120b-medium' }
  # OpenRouter model ids (default = the relay's picker, relay-defaults.json "opencode").
  'opencode'    = [ordered]@{ glm = 'z-ai/glm-5.3'; 'glm-flash' = 'z-ai/glm-5.3-flash'; deepseek = 'deepseek/deepseek-v4.1-flash'
                              nemotron = 'nvidia/nemotron-3-ultra-550b-a55b:free'; kimi = 'moonshotai/kimi-k3.1-pro'; mimo = 'xiaomi/mimo-v2.6-flash' }
}
function Parse-Model([string]$text) {
  $map = [ordered]@{}
  $t = $text.Trim()
  if (-not $t -or $t -in @('none', 'default', 'recommended')) { return $map }
  foreach ($part in ($t -split ',')) {
    $kv = $part.Trim() -split '=', 2
    $role = $kv[0].Trim().ToLower(); $m = $(if ($kv.Count -gt 1) { $kv[1].Trim().ToLower() } else { '' })
    # '/' and ':' allow full OpenRouter ids for OpenCode (tester=nvidia/nemotron-3-ultra-550b-a55b:free).
    if ($role -notmatch '^[a-z][a-z0-9-]*$' -or $m -notmatch '^[a-z0-9][a-z0-9.\-/:]*$') {
      throw "Bad -Model part '$part'. Use role=model, e.g. planner=fable or tester=astra."
    }
    $map[$role] = $m
  }
  return $map
}
# Args for one agent's model, or @() for its default. Throws if the name isn't one of that agent's models.
function Model-Args([string]$agent, [string]$name) {
  if (-not $name -or $name -eq 'default') { return @() }
  $names = $script:modelNames[$agent]
  $id = if ($names.Contains($name)) { $names[$name] } elseif ($name -match '[.\-]') { $name } else {
    throw "Model '$name' isn't a $agent model. Use one of: default, $($names.Keys -join ', '), or a full model id."
  }
  if ($agent -eq 'codex') { return @('-m', $id) }
  if ($agent -eq 'opencode') { return @('--model', "openrouter/$id") }
  return @('--model', $id)
}
function Format-Effort($map) {
  if (-not $map -or $map.Count -eq 0) { return "each agent's own default" }
  return (($map.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')
}
# ---------- calling native programs safely ----------
# PowerShell's own `& exe args` mangles arguments that contain both spaces and double quotes
# (Windows PowerShell 5.1 doesn't quote them, so they split at every space; PowerShell 7 differs
# again by version and $PSNativeCommandArgumentPassing). So we never use it for herdr-app:
# Quote-Arg builds the command line by the standard Windows (CommandLineToArgvW / MSVC) rules
# and Invoke-Native starts the process directly. Every argument arrives exactly as given,
# in every PowerShell version.
function Quote-Arg([string]$s) {
  if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
  # Double the backslashes before each quote and escape the quote; double trailing backslashes
  # so they don't escape the closing quote.
  $s = [regex]::Replace($s, '(\\*)"', { param($m) $m.Groups[1].Value + $m.Groups[1].Value + '\"' })
  $s = [regex]::Replace($s, '(\\+)$', { param($m) $m.Groups[1].Value + $m.Groups[1].Value })
  return '"' + $s + '"'
}
function Invoke-Native([string]$exe, [string[]]$argList, [int]$timeoutSec = 60) {
  $cmdLine = ($argList | ForEach-Object { Quote-Arg $_ }) -join ' '
  if ($cmdLine.Length -gt 30000) { throw "Command line too long ($($cmdLine.Length) chars) for $exe." }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = $cmdLine
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  # Read both streams at once, so a full stderr pipe can't block the program.
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    try { $p.Kill() } catch {}
    throw "$([IO.Path]::GetFileName($exe)) $($argList[0..1] -join ' ') did not finish within $timeoutSec s."
  }
  $p.WaitForExit()   # flush the async readers
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}
function Herdr([string[]]$cmdArgs) {
  # The Herdr window can be away for a while (it updates and restarts itself: 2026-11-23 a relay died asking for a
  # tab at 16:04 while Herdr restarted until 16:06). So when no window answers, wait up to 20 min and try again.
  $deadline = (Get-Date).AddMinutes(20); $told = $false
  while ($true) {
    $r = Invoke-Native $script:herdrApp $cmdArgs
    $all = ($r.Out + "`n" + $r.Err).Trim()
    if ($r.Code -eq 0 -or $all -notmatch '(?i)no Herdr window|actively refused|os error 10061|os error 2\b|connection reset') { break }
    if ((Get-Date) -gt $deadline) { throw "Herdr didn't come back within 20 minutes: $all" }
    if (-not $told) {
      Write-Host "  Herdr isn't answering (restarting or updating?). Waiting for it to come back..." -ForegroundColor Magenta; $told = $true
      if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
        Write-Status 'waiting' $null '' '' "Herdr isn't answering (restarting or updating?). The relay carries on by itself when Herdr is back."
      }
    }
    Start-Sleep -Seconds 10
  }
  if ($told) { Write-Host '  Herdr is back.' -ForegroundColor Magenta }
  $json = [regex]::Match($r.Out, '\{[\s\S]*\}').Value
  if ($r.Code -ne 0 -or -not $json) { throw "herdr-app $($cmdArgs[0..1] -join ' ') failed: $all" }
  try { $o = $json | ConvertFrom-Json } catch { throw "Unexpected herdr-app output: $all" }
  if ($o.PSObject.Properties['error'] -and $o.error) { throw "herdr-app $($cmdArgs[0..1] -join ' ') failed: $($o.error)" }
  return $o
}
function New-RelayStageTab([string]$space, [string]$name, [string[]]$argsAfterName) {
  # A window timeout does not cancel tab.new. Identify the one request by its unique tab name.
  $uniqueName = "$name [$([guid]::NewGuid().ToString('N').Substring(0, 12))]"
  try {
    return Herdr (@('do', 'tab.new', '--space', $space, '--name', $uniqueName) + $argsAfterName)
  } catch {
    if ($_.Exception.Message -notmatch '(?i)the window did not answer') { throw }
  }
  Write-Host "  Herdr did not acknowledge '$uniqueName'. Looking for the existing tab..." -ForegroundColor Yellow
  $deadline = (Get-Date).AddMinutes(2)
  while ((Get-Date) -lt $deadline) {
    try {
      $result = Invoke-Native $script:herdrApp @('ls') 8
      if ($result.Code -eq 0) {
        $matchingSpace = ($result.Out | ConvertFrom-Json).spaces | Where-Object id -eq $space
        $tab = $matchingSpace.tabs | Where-Object name -ceq $uniqueName | Select-Object -First 1
        $terminal = $tab.terminals | Where-Object terminal | Select-Object -First 1 -ExpandProperty terminal
        if ($terminal) {
          Write-Host "  Recovered '$uniqueName' in terminal $terminal." -ForegroundColor Green
          return [pscustomobject]@{ terminal = [string]$terminal }
        }
      }
    } catch {
      # The window can still be busy or restarting. Retry only the read.
    }
    Start-Sleep -Seconds 2
  }
  throw "Herdr did not acknowledge '$uniqueName' and it could not be reconciled. Inspect that tab before relaunching."
}

function Space-Exists([string]$id) {
  if (-not $id) { return $false }
  try { $ls = Herdr @('ls') } catch { return $true }   # can't tell: assume it exists (don't create duplicates)
  return [bool](@($ls.spaces) | Where-Object { $_.id -eq $id })
}
function Count-Lines([string]$p) { if (Test-Path $p) { return @(Get-Content $p).Count } else { return 0 } }
function Parse-Stages([string]$spec) {
  $list = @()
  if ($spec.Trim() -eq 'none') { return ,$list }   # same as "" (an empty argument can't survive Herdr's shell hop)
  foreach ($part in ($spec -split ',')) {
    if (-not $part.Trim()) { continue }
    $kv = $part.Trim() -split '=', 2
    $ag = if ($kv.Count -eq 2) { $kv[1].Trim().ToLower() } else { '' }
    if ($ag -eq 'here') {
      if (-not $HereTerminal -or -not $script:agents.ContainsKey($HereAgent) -or $HereAgent -eq 'opencode') {
        throw "Stage '$part' says 'here', so pass -HereTerminal <the agent's HC_TERMINAL_ID> and -HereAgent claude|codex|antigravity (opencode can't be 'here')."
      }
    }
    elseif ($kv.Count -ne 2 -or -not $script:agents.ContainsKey($ag)) {
      throw "Bad stage '$part'. Use role=agent with agent = claude, codex, antigravity or here."
    }
    $list += [pscustomobject]@{ Role = $kv[0].Trim().ToLower(); Agent = $kv[1].Trim().ToLower() }
  }
  return ,$list
}

# ---------- never run as an AI agent's child process ----------
# The relay waits for hours. If an agent (Claude Code, Codex, Antigravity) starts it as one of its own
# commands, the agent's tool limits kill it (2026-11-21: Claude Code stopped it after 22 min for low
# memory) and nothing starts the next stage. So when an agent is among our parent processes, we
# relaunch the relay in its own Herdr tab (a child of herdr-core) and exit.
function Get-AgentAncestor {
  if ($env:CLAUDECODE -or $env:CLAUDE_CODE_ENTRYPOINT) { return 'Claude Code' }
  try {
    $procs = @{}
    Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
    $cur = $procs[[int]$PID]
    for ($i = 0; $i -lt 25 -and $cur; $i++) {
      $parent = $procs[[int]$cur.ParentProcessId]
      # A parent started after its child is a reused PID, not the real parent: stop there.
      if (-not $parent -or ($parent.CreationDate -and $cur.CreationDate -and $parent.CreationDate -gt $cur.CreationDate)) { break }
      $n = $parent.Name.ToLower()
      if ($n -match '^(herdr-core|herdr-app|hc|explorer|services|wininit)\.exe$') { break }   # a Herdr tab or the desktop: fine
      if ($n -match '^(claude|codex|agy|antigravity[^\\]*|gemini|cursor-agent|opencode|copilot)\.exe$') { return $parent.Name }
      $cur = $parent
    }
  } catch {}
  return $null
}
# The Herdr space a terminal lives in ('' if unknown).
function Get-TerminalSpace([string]$terminal) {
  if (-not $terminal) { return '' }
  $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
  if (-not $hcExe) { return '' }
  try { $r = Invoke-Native $hcExe @('get', $terminal, '--json') 30 } catch { return '' }
  $m = [regex]::Match($r.Out, 'herdr\.space"?\s*[:=]\s*"?([A-Za-z0-9_\-]+)')
  if ($m.Success) { return $m.Groups[1].Value } else { return '' }
}
# The project's Herdr space (D-025). A space's saved folder is NOT what the sidebar shows: an unnamed space is
# called after its first terminal's folder, and its saved folder can belong to another project (matching by saved
# folder once opened a relay's tabs in the space the sidebar showed as a different project).
# So judge a space by the terminals running in it: it is this project's when at least one of them works in the
# project folder and none in another project (a parent folder such as home counts as neutral). $prefer (the space
# you started from) wins when it qualifies. Mixed or foreign spaces are never used: then a new space is made.
function Get-ProjectSpace([string]$folder, [string]$name, [string]$prefer = '') {
  $norm = { param($p) ([string]$p).Replace('/', '\').TrimEnd('\').ToLower() }
  $proj = & $norm $folder
  $spaces = @((Herdr @('ls')).spaces)
  $cwd = @{}
  $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
  if ($hcExe) {
    try {
      $r = Invoke-Native $hcExe @('ls') 30
      foreach ($t in @(($r.Out | ConvertFrom-Json).terminals)) { if ($t.cwd) { $cwd[[string]$t.address] = & $norm $t.cwd } }
    } catch {}
  }
  $rows = foreach ($s in $spaces) {
    $own = 0; $foreign = @()
    foreach ($tab in @($s.tabs)) {
      foreach ($t in @($tab.terminals)) {
        $c = $cwd[[string]$t.terminal]
        if (-not $c) { continue }
        if ($c -eq $proj -or $c.StartsWith($proj + '\')) { $own++ }
        elseif (-not $proj.StartsWith($c + '\')) { $foreign += $c }
      }
    }
    [pscustomobject]@{ Id = [string]$s.id; Own = $own; Foreign = @($foreign) }
  }
  $ok = @($rows | Where-Object { $_.Own -gt 0 -and $_.Foreign.Count -eq 0 })
  $hit = $ok | Where-Object { $_.Id -eq $prefer } | Select-Object -First 1
  if (-not $hit) { $hit = $ok | Sort-Object Own -Descending | Select-Object -First 1 }
  if ($hit) { return $hit.Id }
  $mixed = @($rows | Where-Object { $_.Own -gt 0 -and $_.Foreign.Count -gt 0 })
  if ($mixed.Count) {
    $others = ($mixed | ForEach-Object { $_.Foreign } | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique) -join ', '
    Write-Host "  Herdr: this project's terminals share a space with another project ($others), so the relay opens its own space '$name'." -ForegroundColor DarkYellow
  }
  # A name, so the sidebar shows the project even before the first terminal starts. space.new opens an empty shell
  # tab; remember it so the caller can close it once the relay's own tab is there.
  $new = Herdr @('do', 'space.new', '--name', $name, '--folder', $folder, '--focus', 'false')
  $script:freshSpaceTab = [string]$new.tab
  return [string]$new.space
}
# A relay already running for this project (fresh heartbeat in status.json)? Two relays on one project fight.
function Get-LiveRelay([string]$folder) {
  $p = Join-Path $folder '.ai\relay\status.json'
  if (-not (Test-Path $p)) { return $null }
  try { $s = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  if ($s.state -notin @('running', 'waiting', 'paused')) { return $null }
  try { $age = ((Get-Date) - [datetime]$s.updated).TotalSeconds } catch { return $null }
  if ($age -lt 90) { return $s } else { return $null }
}
if (-not $InHerdrTab) {
  $agent = Get-AgentAncestor
  if ($agent) {
    if (-not $Folder -or -not $Goal) {
      throw "The relay was started by $agent without -Folder and -Goal. Pass both (it can't ask questions from inside an agent)."
    }
    $script:herdrApp = Find-Exe 'herdr-app' @("$env:LOCALAPPDATA\Programs\herdr-app")
    if (-not $script:herdrApp) { throw 'herdr-app.exe not found. Is the Herdr app installed?' }
    $Folder = (Resolve-Path $Folder).Path
    $leaf = Split-Path $Folder -Leaf
    $psExe = Join-Path $PSHOME 'powershell.exe'; if (-not (Test-Path $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    # Herdr starts argv through the tab's shell, which drops double quotes inside arguments and empty ones.
    $q = { param($s) ([string]$s).Replace('"', "'") }
    $relArgs = @($psExe, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                 '-Folder', $Folder, '-Goal', (& $q $Goal),
                 '-Stages', $(if ($Stages.Trim()) { & $q $Stages } else { 'none' }),
                 '-Loop', (& $q $Loop), '-MaxRounds', "$MaxRounds", '-TimeoutMin', "$TimeoutMin",
                 '-Effort', $(if ($Effort.Trim()) { & $q $Effort } else { 'none' }),
                 '-Model', $(if ($Model.Trim()) { & $q $Model } else { 'default' }), '-Team', $Team, '-InHerdrTab')
    if ($Queue) { $relArgs += '-Queue' }
    if ($PauseOnUnapproved) { $relArgs += '-PauseOnUnapproved' }
    if ($KeepPermissions) { $relArgs += '-KeepPermissions' }
    if ($Overnight) { $relArgs += @('-Overnight', '-Until', $Until, '-MaxCycles', "$MaxCycles") }
    if ($Tasks.Trim()) { $relArgs += @('-Tasks', ($Tasks -replace '\s', '')) }
    if ($AskEachRound) { $relArgs += '-AskEachRound' }
    if ($NoRulesCheck) { $relArgs += '-NoRulesCheck' }
    if ($HereTerminal) { $relArgs += @('-HereTerminal', $HereTerminal, '-HereAgent', $HereAgent) }
    $argvJson = ConvertTo-Json -InputObject ([object[]]$relArgs) -Compress
    $live = Get-LiveRelay $Folder
    if ($live) {
      throw "A relay is already running for $leaf (stage $($live.stage), terminal $($live.relayTerminal)). Stop it first (AI Project panel: Stop), or switch it with -MakeOvernight."
    }
    $space = Get-ProjectSpace $Folder $leaf (Get-TerminalSpace $env:HC_TERMINAL_ID)
    # The relay asks its first question right away when it is overnight (pre-flight) or a queue: show its tab then.
    $focus = if ($Overnight -or $Queue -or $Tasks.Trim()) { 'true' } else { 'false' }
    $tab = Herdr @('do', 'tab.new', '--space', $space, '--name', 'AI Relay', '--folder', $Folder, '--argv', $argvJson, '--focus', $focus)
    if ($script:freshSpaceTab) { try { [void](Herdr @('do', 'tab.close', '--id', $script:freshSpaceTab, '--confirmed', 'true')) } catch {} }
    $same = ($space -eq (Get-TerminalSpace $env:HC_TERMINAL_ID))
    Write-Host "Started by $agent, so the relay now runs in its own Herdr tab 'AI Relay' (terminal $($tab.terminal))."
    Write-Host ("Where: space '$leaf'" + $(if ($same) { ' (this space)' } else { ' (its own space, not this one)' }) + ", tab 'AI Relay'.")
    $asks = @()
    if ($Overnight) { $asks += 'the overnight pre-flight (y)' }
    elseif ($Queue -or $Tasks.Trim()) { $asks += 'approving the task queue (y)' }
    if ($asks) { Write-Host "It needs ONE answer from the user in that tab before it starts: $($asks -join ', '). The tab is shown now." }
    Write-Host "It keeps running when this agent stops. Watch it in Herdr, or: hc read $($tab.terminal)"
    exit 0
  }
}

# ---------- interactive setup (when -Folder or -Goal is missing) ----------
function Ask([string]$q, [string]$def) {
  $prompt = if ($def) { "$q [$def]" } else { $q }
  $a = Read-Host $prompt
  if ([string]::IsNullOrWhiteSpace($a)) { return $def } else { return $a.Trim() }
}
function Ask-Agent([string]$role, [string]$def) {
  while ($true) {
    $a = (Ask ("  {0,-9} c=claude  x=codex  a=antigravity  o=opencode" -f $role) $def).ToLower()
    if ($a -match '^(c|claude)$') { return 'claude' }
    if ($a -match '^(x|codex)$') { return 'codex' }
    if ($a -match '^(a|antigravity|agy)$') { return 'antigravity' }
    if ($a -match '^(o|opencode)$') { return 'opencode' }
    Write-Host '    please type c, x, a or o' -ForegroundColor Red
  }
}
if (-not $Folder -or -not $Goal) {
  Write-Host "`n== AI relay setup ==   (press Enter to accept the [default])" -ForegroundColor Cyan
  $cwd = (Get-Location).Path
  $defFolder = if ($cwd -ne $HOME) { $cwd } else { '' }
  while (-not $Folder) { $Folder = Ask 'Project folder' $defFolder }
  $statePath = Join-Path $Folder '.ai\STATE.md'
  $existing = Test-Path $statePath
  if ($existing) {
    Write-Host "`nExisting project. Its 'Next' list:" -ForegroundColor DarkGray
    $inNext = $false
    foreach ($l in (Get-Content $statePath)) {
      if ($l -match '^## ') { $inNext = ($l -match '^## Next') ; continue }
      if ($inNext -and $l.Trim()) { Write-Host "  $l" -ForegroundColor DarkGray }
    }
  }
  $defGoal = if ($existing) { 'continue with the Next list in .ai/STATE.md' } else { '' }
  while (-not $Goal) { $Goal = Ask "`nGoal for this run" $defGoal }
  # Team: only asked when relay-defaults.json defines more than the built-in coding team.
  $teamsDef = Default-Of 'teams' $null
  $teamNames = @('coding') + $(if ($teamsDef) { @($teamsDef.PSObject.Properties.Name) } else { @() }) | Select-Object -Unique
  if ($teamNames.Count -gt 1) {
    Write-Host "`nTeam?"
    foreach ($tn in $teamNames) { Write-Host ("  {0,-10} {1}" -f $tn, ((Get-Team $tn | ForEach-Object { $_.role }) -join ' -> ')) }
    $pick = ''
    while ($pick -notin $teamNames) { $pick = (Ask 'Choose a team' $Team).ToLower() }
    if ($pick -ne $Team) {
      $Team = $pick; $script:teamRoles = Get-Team $Team
      $script:judgeRole = ($script:teamRoles | Where-Object judge | Select-Object -First 1).role
      $script:jobOf = @{}; foreach ($r in $script:teamRoles) { if ($r.job) { $script:jobOf[$r.role] = $r.job } }
      $script:effortRecommended = (($script:teamRoles | Where-Object { $_.effort -ne 'default' } | ForEach-Object { "$($_.role)=$($_.effort)" }) -join ',')
    }
  }
  $onceRoles = @($script:teamRoles | Where-Object once | ForEach-Object { $_.role })
  $all = @($script:teamRoles | ForEach-Object { $_.role })
  $build = @($script:teamRoles | Where-Object { -not $_.once } | ForEach-Object { $_.role })
  Write-Host "`nWhat kind of run?"
  Write-Host "  1  Full:   $($all -join ' -> '), then fix rounds"
  if ($onceRoles) { Write-Host "  2  Build:  $($build -join ' -> '), then fix rounds (no $($onceRoles -join '/'))" }
  Write-Host "  3  Review: $($script:judgeRole) only, once"
  if ($onceRoles) { Write-Host "  4  Queue:  $($onceRoles -join '/') splits a big goal into tasks; you approve; then $($build -join ' -> ') per task, each with its own agents" }
  $mode = ''
  $modeDef = if ($existing -and $onceRoles) { '2' } else { '1' }
  while ($mode -notmatch $(if ($onceRoles) { '^[1234]$' } else { '^[13]$' })) { $mode = Ask $(if ($onceRoles) { 'Choose 1, 2, 3 or 4' } else { 'Choose 1 or 3' }) $modeDef }
  if ($mode -eq '4') { $Queue = $true; $mode = '1' }   # a queue plans with the full team's once-roles first
  $use = switch ($mode) { '1' { $all } '2' { $build } default { @($script:judgeRole) } }
  Write-Host "`nWho does what?"
  $picked = [ordered]@{}
  foreach ($r in $script:teamRoles | Where-Object { $_.role -in $use }) {
    $def = switch ($r.agent) { 'codex' { 'x' } 'antigravity' { 'a' } 'opencode' { 'o' } default { 'c' } }
    $picked[$r.role] = Ask-Agent $r.role $def
  }
  if ($mode -eq '3') {
    $Stages = "$($script:judgeRole)=$($picked[$script:judgeRole])"; $MaxRounds = 0
  } else {
    $Loop = (($build | ForEach-Object { "$_=$(if ($picked.Contains($_)) { $picked[$_] } else { ($script:teamRoles | Where-Object role -eq $_).agent })" }) -join ',')
    $Stages = (($use | ForEach-Object { "$_=$($picked[$_])" }) -join ',')
    $r = ''
    while ($r -notmatch '^\d+$') { $r = Ask "`nMax fix rounds if the $($script:judgeRole) asks for changes (0 = none)" "$MaxRounds" }
    $MaxRounds = [int]$r
    $askDef = if ([bool](Default-Of 'askEachRound' $true)) { 'y' } else { 'n' }
    if ($MaxRounds -gt 0) { $AskEachRound = ((Ask 'Ask me before each fix round? y/n' $askDef) -eq 'y') }
  }
  Write-Host "`nEffort (how hard each agent thinks)?"
  Write-Host "  r  Recommended: $(Format-Effort (Parse-Effort 'recommended'))"
  Write-Host "  d  Each agent's own default"
  Write-Host "  c  Choose per role"
  $mine = $Effort.Trim() -notin @('recommended', 'none', '')   # relay-defaults.json has its own per-role effort
  if ($mine) { Write-Host "  k  Keep your defaults: $(Format-Effort (Parse-Effort $Effort))" }
  $e = ''
  $eDef = if ($mine) { 'k' } elseif ($Effort.Trim() -eq 'none') { 'd' } else { 'r' }
  while ($e -notmatch $(if ($mine) { '^[rdck]$' } else { '^[rdc]$' })) { $e = (Ask $(if ($mine) { 'Choose r, d, c or k' } else { 'Choose r, d or c' }) $eDef).ToLower() }
  if ($e -eq 'k') { }
  elseif ($e -eq 'r') { $Effort = 'recommended' }
  elseif ($e -eq 'd') { $Effort = 'none' }
  else {
    $rec = Parse-Effort 'recommended'
    $used = @(($Stages, $Loop) -join ',' -split ',' | ForEach-Object { ($_ -split '=')[0].Trim().ToLower() } |
              Where-Object { $_ } | Select-Object -Unique)
    $picked = @()
    foreach ($role in @($script:teamRoles | ForEach-Object { $_.role }) | Where-Object { $_ -in $used }) {
      $ok = if ($role -eq 'executor') { @('high', 'xhigh', 'max') } else { $script:effortLevels }
      $lvl = ''
      while ($lvl -notin $ok) { $lvl = (Ask ("  {0,-9} {1}" -f $role, ($ok -join '/')) $rec[$role]).ToLower() }
      $picked += "$role=$lvl"
    }
    $Effort = $picked -join ','
  }
  Write-Host "`nModels?"
  Write-Host "  d  Each agent's default (Claude Opus 5.5, Codex GPT-6.2-Sol, Antigravity Gemini 3.8 Flash)"
  Write-Host "  c  Choose per role"
  $mineM = $Model.Trim() -notin @('default', 'none', 'recommended', '')
  if ($mineM) { Write-Host "  k  Keep your defaults: $Model" }
  $mm = ''
  while ($mm -notmatch $(if ($mineM) { '^[dck]$' } else { '^[dc]$' })) { $mm = (Ask $(if ($mineM) { 'Choose d, c or k' } else { 'Choose d or c' }) $(if ($mineM) { 'k' } else { 'd' })).ToLower() }
  if ($mm -eq 'k') { }
  elseif ($mm -eq 'd') { $Model = 'default' }
  else {
    $roleAgent = [ordered]@{}
    foreach ($pair in (($Stages, $Loop) -join ',' -split ',')) {
      $kv = $pair -split '=', 2
      if ($kv.Count -eq 2 -and -not $roleAgent.Contains($kv[0].Trim())) { $roleAgent[$kv[0].Trim()] = $kv[1].Trim() }
    }
    $picked = @()
    foreach ($role in @($roleAgent.Keys)) {
      $ag = $roleAgent[$role]
      while ($true) {
        $m = (Ask ("  {0,-9} ({1}) default/{2}" -f $role, $ag, ($script:modelNames[$ag].Keys -join '/')) 'default').ToLower()
        try { [void](Model-Args $ag $m); break } catch { Write-Host "    $($_.Exception.Message)" -ForegroundColor Red }
      }
      $picked += "$role=$m"
    }
    $Model = $picked -join ','
  }
  Write-Host "`nOvernight (unattended: no questions, all agent permissions skipped, its own git branch, keeps going on"
  Write-Host 'its own)? You can still watch and step in any time.'
  if ((Ask 'Overnight? y/n' $(if ($Overnight) { 'y' } else { 'n' })) -eq 'y') {
    $Overnight = $true
    if ($onceRoles -and -not $Queue -and $mode -ne '3') { $Queue = ((Ask 'Also split the goal into a queue of tasks and keep planning new ones (cycles)? y/n' 'y') -eq 'y') }
    # When the night ends: a time, a cycle count, or 'done' (until nothing worthwhile is left); whichever comes first.
    $defU = if ($Until) { $Until } else { [string](Ovn-Of 'until' '07:00') }
    while ($true) {
      $Until = Ask "  Run until? (a time like 08:00, or 'done' = until all tasks are finished)" $defU
      try { $script:Until = $Until; Set-NightLimits; break } catch { Write-Host "    $($_.Exception.Message)" -ForegroundColor Red }
    }
    if ($Queue) {
      $defC = if ($MaxCycles -ge 0) { "$MaxCycles" } else { "$([int](Ovn-Of 'maxCycles' 3))" }
      $c = ''; while ($c -notmatch '^\d+$') { $c = Ask '  Max cycles? (0 = no limit)' $defC }
      $MaxCycles = [int]$c
    }
    Apply-Overnight
  }
  Write-Host "`nReady:" -ForegroundColor Cyan
  if ($Overnight) { Write-Host "  night  : unattended $(Night-LimitText); all permissions skipped, new git branch" -ForegroundColor Yellow }
  Write-Host "  folder : $Folder"
  Write-Host "  goal   : $Goal"
  Write-Host "  team   : $Team   (the $($script:judgeRole) approves or asks for changes)"
  if ($Queue) { Write-Host "  queue  : yes - planning splits the goal into tasks; you approve the queue; agents per task from each task's Relay: line" }
  Write-Host "  stages : $($Stages -replace ',', ' -> ')"
  if ($MaxRounds -gt 0) { Write-Host "  fixes  : up to $MaxRounds round(s) of $($Loop -replace ',', ' -> ')$(if ($AskEachRound) { ', asking you each time' })" }
  Write-Host "  effort : $(Format-Effort (Parse-Effort $Effort))   (executor always high or above)"
  $mp = Parse-Model $Model
  Write-Host "  models : $(if ($mp.Count) { ($mp.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ' } else { "each agent's default" })"
  if ((Ask 'Start? y/n' 'y') -ne 'y') { Write-Host 'Cancelled.'; exit 0 }
}

# ---------- tools ----------
$script:herdrApp = Find-Exe 'herdr-app' @("$env:LOCALAPPDATA\Programs\herdr-app")
if (-not $script:herdrApp) { throw 'herdr-app.exe not found. Is the Herdr app installed?' }
$claude = Find-Exe 'claude' @("$HOME\.local\bin")
$agy    = Find-Exe 'agy'    @("$HOME\.gemini\bin")
$script:codexSandbox = ([string](Default-Of 'codexWindowsSandbox' 'mxc')).Trim()
$script:agents = @{
  'claude'      = @($(if ($claude) { $claude } else { 'claude' }))
  # --approve-for-me: Codex keeps its sandbox, but its own automatic reviewer answers approval requests (staging and
  # committing, which its sandbox always blocks on .git) instead of stopping for you every time. Risky requests are
  # still refused or escalated by that reviewer. relay-defaults.json "codexApproveForMe": false turns it off.
  # windows.sandbox: which Codex sandbox to run in on Windows (relay-defaults.json "codexWindowsSandbox", default
  # "mxc"; "none" leaves the flag out so Codex uses its own config).
  'codex'       = @('codex', '--no-daemon') + $(if ($script:codexSandbox -and $script:codexSandbox -ne 'none') { @('-c', "windows.sandbox=$($script:codexSandbox)") } else { @() }) +
                  $(if ([bool](Default-Of 'codexApproveForMe' $true)) { @('--approve-for-me') } else { @() })
  'antigravity' = @($(if ($agy) { $agy } else { 'agy' }))
  # OpenCode on OpenRouter models (D-028): the relay picks the model per stage (Pick-OpenCodeModel).
  'opencode'    = @('opencode')
}
# Overnight: nobody is there to answer, so every agent runs with its permission checks off (user's choice,
# relay-defaults.json overnight.skipPermissions). Codex then needs no sandbox flags at all.
if ($Overnight) { $AskEachRound = $false }
if ($Overnight -and $script:skipPerms) {
  $script:agents['claude']      = $script:agents['claude'] + @('--dangerously-skip-permissions')
  $script:agents['codex']       = @('codex', '--no-daemon', '--dangerously-bypass-approvals-and-sandbox')
  $script:agents['antigravity'] = $script:agents['antigravity'] + @('--dangerously-skip-permissions')
  $script:agents['opencode']    = $script:agents['opencode'] + @('--auto')
}
$script:effortByRole = Parse-Effort $Effort
$script:modelByRole = Parse-Model $Model
$first = Parse-Stages $Stages
$loopStages = Parse-Stages $Loop
# Check every model name against its stage's agent now, not hours later when that stage starts.
foreach ($st in @($first) + @($loopStages)) {
  if (-not $st) { continue }
  if ($st.Agent -eq 'here') {
    if ($script:modelByRole[$st.Role] -or ($script:effortByRole[$st.Role] -and $script:effortByRole[$st.Role] -ne 'default')) {
      Write-Host "  note: $($st.Role) runs in your own $HereAgent session ($HereTerminal), so its model/effort stay as that session has them." -ForegroundColor DarkGray
    }
    continue
  }
  [void](Model-Args $st.Agent $script:modelByRole[$st.Role])
}
if ($MaxRounds -gt 0 -and -not ($loopStages | Where-Object { $_.Role -eq $script:judgeRole })) {
  throw "-Loop must include the $($script:judgeRole) stage (team '$Team''s judge), so the relay knows when the work is approved."
}

# ---------- project folder + Herdr space ----------
if (-not (Test-Path $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
$Folder = (Resolve-Path $Folder).Path
$relayDir = Join-Path $Folder '.ai\relay'
$liveRelay = Get-LiveRelay $Folder
if ($liveRelay) {
  throw "A relay is already running for $(Split-Path $Folder -Leaf) (stage $($liveRelay.stage), terminal $($liveRelay.relayTerminal)). Stop it first (AI Project panel: Stop), or switch it with -MakeOvernight."
}
New-Item -ItemType Directory -Path $relayDir -Force | Out-Null
Set-Content -Path (Join-Path $relayDir '.gitignore') -Value '*' -Encoding ASCII   # relay files never go into git
Get-ChildItem $relayDir -Filter 'stage-*.done' -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $relayDir -Filter 'stage-*.task.txt' -ErrorAction SilentlyContinue | Remove-Item -Force
$stopFile  = Join-Path $relayDir 'STOP'
$pauseFile = Join-Path $relayDir 'PAUSE'
$overnightFile = Join-Path $relayDir 'OVERNIGHT'   # "Make overnight" (panel button / 'relay overnight')
foreach ($f in @($stopFile, $pauseFile, $overnightFile)) { if (Test-Path $f) { Remove-Item $f -Force } }
$goalText = $Goal.Replace('"', "'").Replace("`r", ' ').Replace("`n", ' ')
$name = Split-Path $Folder -Leaf

function Show-Summary {
  $ErrorActionPreference = 'Continue'
  Push-Location $Folder
  try {
    Write-Host "`nGit history (author | message):"
    git log --format='  %an | %s' 2>$null
    Write-Host "`n.ai/LOG.md (last 12 lines):"
    Get-Content '.ai\LOG.md' -ErrorAction SilentlyContinue | Select-Object -Last 12 | ForEach-Object { "  $_" }
  } finally { Pop-Location }
}

# ---------- usage: plan limits and tokens, for the Herdr panel ----------
# Claude: relay-started Claude sessions run bin/claude-statusline.ps1, which saves Claude's own numbers
#   (5-hour / weekly plan use, tokens, cost) into usage/claude.json and usage/sessions/<session-id>.json.
# Codex: its session files (~/.codex/sessions/.../rollout-*.jsonl) carry token counts and plan limits.
# Antigravity: keeps no usage numbers on disk, so none are shown.
$script:usageDir = Join-Path $PSScriptRoot 'usage'
New-Item -ItemType Directory -Path (Join-Path $script:usageDir 'sessions') -Force | Out-Null
$script:claudeSettings = Join-Path $script:usageDir 'claude-relay-settings.json'
$slCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + ((Join-Path $PSScriptRoot 'bin\claude-statusline.ps1') -replace '\\', '/')
[IO.File]::WriteAllText($script:claudeSettings, (@{ statusLine = @{ type = 'command'; command = $slCmd } } | ConvertTo-Json -Compress),
  (New-Object System.Text.UTF8Encoding($false)))
function Read-Json([string]$p) { try { if (Test-Path $p) { return (Get-Content $p -Raw) | ConvertFrom-Json } } catch {} return $null }
function Limit-Of($w) {
  if (-not $w) { return $null }
  $used = if ($null -ne $w.used_percentage) { $w.used_percentage } else { $w.used_percent }
  $reset = if ($w.resets_at) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$w.resets_at).LocalDateTime.ToString('o') } else { '' }
  return [ordered]@{ used = [double]$used; resets = $reset }
}
# The newest Codex session files (today's and yesterday's folders only: they can be many).
function Codex-Rollouts {
  $root = Join-Path $HOME '.codex\sessions'
  $dirs = @((Get-Date), (Get-Date).AddDays(-1)) | ForEach-Object { Join-Path $root $_.ToString('yyyy\\MM\\dd') } | Where-Object { Test-Path $_ }
  if (-not $dirs) { return @() }
  return @(Get-ChildItem $dirs -Filter 'rollout-*.jsonl' -File | Sort-Object LastWriteTime -Descending)
}
# The end of a file that another program is still writing. (Get-Content -Tail is far too slow on Codex's
# long JSON lines in Windows PowerShell 5.1: ~50 s for a 1.6 MB file.)
function Read-TailText([string]$path, [int]$bytes = 524288) {
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
  try {
    $n = [int][Math]::Min([int64]$bytes, $fs.Length)
    [void]$fs.Seek(-$n, [IO.SeekOrigin]::End)
    $buf = New-Object byte[] $n
    $read = 0; while ($read -lt $n) { $k = $fs.Read($buf, $read, $n - $read); if ($k -le 0) { break }; $read += $k }
    return [Text.Encoding]::UTF8.GetString($buf, 0, $read)
  } finally { $fs.Dispose() }
}
function Codex-LastCount([string]$file) {
  try {
    $line = (Read-TailText $file) -split "`n" | Where-Object { $_ -match '"type":"token_count"' } | Select-Object -Last 1
    if ($line) {
      $o = $line | ConvertFrom-Json
      $o.payload | Add-Member -NotePropertyName at -NotePropertyValue ([datetime]::Parse($o.timestamp).ToLocalTime().ToString('o')) -Force
      return $o.payload
    }
  } catch {}
  return $null
}
function Get-PlanUsage {
  $u = [ordered]@{}
  $c = Read-Json (Join-Path $script:usageDir 'claude.json')
  if ($c -and $c.rate_limits) {
    $u.claude = [ordered]@{ fiveHour = Limit-Of $c.rate_limits.five_hour; week = Limit-Of $c.rate_limits.seven_day; at = [string]$c.at }
  }
  foreach ($f in (Codex-Rollouts | Select-Object -First 3)) {
    $p = Codex-LastCount $f.FullName
    if ($p -and $p.rate_limits) {
      $u.codex = [ordered]@{ fiveHour = Limit-Of $p.rate_limits.primary; week = Limit-Of $p.rate_limits.secondary
                             plan = [string]$p.rate_limits.plan_type; at = [string]$p.at }
      break
    }
  }
  $u.antigravity = $null   # not recorded by Antigravity
  return $u
}
# Tokens (and cost for Claude) used by one stage so far, or $null if unknown.
function Stage-Usage($h) {
  try {
    if ($h.agent -eq 'opencode') { return OpenCode-Usage ([datetime]::Parse($h.started)) }
    if ($h.agent -eq 'claude' -and $h.session) {
      $s = Read-Json (Join-Path $script:usageDir "sessions\$($h.session).json")
      if ($s) { return [ordered]@{ tokens = [int64]$s.tokens; cost = [double]$s.cost; context = $s.context } }
    }
    if ($h.agent -eq 'codex') {
      if (-not $h.rollout) {
        $since = [datetime]::Parse($h.started).AddSeconds(-30)
        foreach ($f in (Codex-Rollouts | Where-Object { $_.CreationTime -ge $since })) {
          $meta = Get-Content $f.FullName -TotalCount 1 | ConvertFrom-Json
          if ($meta.payload.cwd -and ($meta.payload.cwd.TrimEnd('\') -eq $Folder.TrimEnd('\'))) { $h.rollout = $f.FullName; break }
        }
      }
      if ($h.rollout) {
        $p = Codex-LastCount $h.rollout
        if ($p -and $p.info) { return [ordered]@{ tokens = [int64]$p.info.total_token_usage.total_tokens } }
      }
    }
  } catch {}
  return $null
}

# ---------- model fallback: plan quota runs out (D-027, relay-defaults.json "fallback") ----------
# Before a stage: an agent (or Antigravity model) known to be out of quota is replaced by the next one in its chain,
# and near a plan limit some roles start one effort step lower. During a stage: when the agent's screen shows a
# quota message, a limit that resets soon is waited out; otherwise Antigravity switches model inside the running
# session (its /model picker), and Claude/Codex (whose limits cover every model) hand the stage to another agent.
# What ran out, and until when, is kept in usage/quota.json, so every relay on this PC knows it.
$script:fb = Default-Of 'fallback' $null
function Fb-Of([string]$k, $d) { if ($script:fb -and $script:fb.PSObject.Properties[$k] -and $null -ne $script:fb.$k) { return $script:fb.$k }; return $d }
$script:fbOn = [bool](Fb-Of 'enabled' $true)
$script:fbWait = [int](Fb-Of 'waitMinutes' 20)
$script:quotaFile = Join-Path $script:usageDir 'quota.json'
$script:agySettings = Join-Path $HOME '.gemini\antigravity-cli\settings.json'
$script:agySearch = @{ hydrogen = 'hydrogen'; flash = 'flash'; opus = 'opus'; sonnet = 'sonnet'; 'gpt-oss' = 'gpt' }
# Antigravity's own default model (its /model picker saves the choice there; the relay puts it back after a switch).
$script:agyDefaultRaw = ''
try { if (Test-Path $script:agySettings) { $script:agyDefaultRaw = [string]((Get-Content $script:agySettings -Raw -Encoding UTF8 | ConvertFrom-Json).model) } } catch {}
# Short model name (hydrogen, opus, sol, ...) from an id or a display name, or '' when unknown.
function Model-Short([string]$agent, [string]$text) {
  $t = ([string]$text).ToLower()
  if (-not $t) { return '' }
  if ($agent -eq 'antigravity') {
    foreach ($p in @(@('hydrogen', 'hydrogen'), @('flash', 'flash'), @('opus', 'opus'), @('sonnet', 'sonnet'), @('gpt', 'gpt-oss'))) {
      if ($t.Contains($p[0])) { return $p[1] }
    }
    return ''
  }
  foreach ($k in $script:modelNames[$agent].Keys) { if ($t.Contains($k)) { return $k } }
  return ''
}
# Which quota a model uses: Antigravity's Gemini models share one; Claude's and Codex's limits cover all their models.
function Quota-Key([string]$agent, [string]$short) {
  if ($agent -eq 'antigravity') { if ($short -in @('hydrogen', 'flash', '')) { return 'antigravity/gemini' } else { return "antigravity/$short" } }
  if ($agent -eq 'opencode') { return "opencode/$short" }   # OpenRouter: every model has its own limits
  return $agent
}
function Read-Quota {
  $h = @{}
  $o = Read-Json $script:quotaFile
  if ($o) { foreach ($p in $o.PSObject.Properties) { try { $h[$p.Name] = [datetime]$p.Value } catch {} } }
  return $h
}
function Set-Quota([string]$key, [datetime]$until) {
  $h = Read-Quota; $h[$key] = $until
  $o = [ordered]@{}; foreach ($k in $h.Keys) { if ($h[$k] -gt (Get-Date)) { $o[$k] = $h[$k].ToString('o') } }
  try { [IO.File]::WriteAllText($script:quotaFile, ($o | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false))) } catch {}
}
# When a quota is back, or $null if it isn't out.
function Quota-Out([string]$key) {
  $u = (Read-Quota)[$key]
  if ($u -and $u -gt (Get-Date)) { return $u }
  return $null
}
# Claude/Codex: out when the relay saw a quota message, or the plan use it reads is at 98 % or more.
function Agent-Out([string]$agent) {
  if ($agent -notin @('claude', 'codex')) { return $null }
  $q = Quota-Out $agent
  if ($q) { return $q }
  if (-not $script:usage -or ((Get-Date) - $script:usageAt).TotalMinutes -ge 5) { $script:usage = Get-PlanUsage; $script:usageAt = Get-Date }
  $v = $script:usage.$agent
  if (-not $v) { return $null }
  foreach ($w in @($v.fiveHour, $v.week)) {
    if ($w -and $w.used -ge 98 -and $w.resets) { $r = [datetime]$w.resets; if ($r -gt (Get-Date)) { return $r } }
  }
  return $null
}
function Plan-UsedPercent([string]$agent) {
  if (-not $script:usage -or ((Get-Date) - $script:usageAt).TotalMinutes -ge 5) { $script:usage = Get-PlanUsage; $script:usageAt = Get-Date }
  $v = $script:usage.$agent
  if (-not $v) { return -1 }
  return [double](@($v.fiveHour, $v.week) | Where-Object { $_ } | ForEach-Object { $_.used } | Measure-Object -Maximum).Maximum
}
# ---------- quota planner (D-029) ----------
$script:fbMaxWait = [int](Fb-Of 'maxWaitMinutes' 30)
# 5-hour window of Claude/Codex: @{ used; resets } or $null.
function Plan-5h([string]$agent) {
  if (-not $script:usage -or ((Get-Date) - $script:usageAt).TotalMinutes -ge 5) { $script:usage = Get-PlanUsage; $script:usageAt = Get-Date }
  $v = $script:usage.$agent
  if (-not $v -or -not $v.fiveHour) { return $null }
  return @{ used = [double]$v.fiveHour.used; resets = $(if ($v.fiveHour.resets) { [datetime]$v.fiveHour.resets } else { $null }) }
}
# The share of Claude's 5-hour window this role may use: the reserve keeps the rest for the user's own Claude chats.
function Claude-Cap([string]$role) {
  if ($role -eq $script:judgeRole) { return [double](Fb-Of 'judgeClaudePercent' 90) }
  return [double](Fb-Of 'claudeReservePercent' 75)
}
# Typical 5-hour plan use of one stage of this agent and role (median of its last 10 recorded stages, else 10 %).
$script:predCache = $null
function Predict-Use([string]$agent, [string]$role) {
  if (-not $script:predCache -or ((Get-Date) - $script:predCache.read).TotalMinutes -ge 10) {
    $rows = @()
    $p = Join-Path $script:usageDir 'model-stats.jsonl'
    if (Test-Path $p) {
      $rows = @([IO.File]::ReadAllLines($p) | Select-Object -Last 500 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
                Where-Object { $null -ne $_.planBefore -and $null -ne $_.planAfter -and [double]$_.planAfter -ge [double]$_.planBefore })
    }
    $script:predCache = @{ read = Get-Date; rows = $rows }
  }
  $d = @($script:predCache.rows | Where-Object { $_.agent -eq $agent -and $_.role -eq $role } | Select-Object -Last 10 |
         ForEach-Object { [double]$_.planAfter - [double]$_.planBefore } | Sort-Object)
  if ($d.Count -lt 3) { return 10.0 }
  return $d[[math]::Floor($d.Count / 2)]
}
# Can this Claude/Codex agent take a stage of this role now? No when its plan is out, when Claude is over the reserve,
# or (prediction) when the stage probably won't fit before the 5-hour window resets more than maxWaitMinutes away.
function Agent-Fits([string]$agent, [string]$role) {
  if ($agent -notin @('claude', 'codex')) { return $true }
  $out = Agent-Out $agent
  if ($out -and ($out - (Get-Date)).TotalMinutes -gt $script:fbWait) { return $false }
  $w = Plan-5h $agent
  if (-not $w) { return $true }   # no numbers yet (e.g. Claude before its first reply): don't guess
  $cap = if ($agent -eq 'claude') { Claude-Cap $role } else { 100.0 }
  $far = (-not $w.resets) -or (($w.resets - (Get-Date)).TotalMinutes -gt $script:fbMaxWait)
  if ($w.used -ge $cap -and $far) { return $false }
  if ([bool](Fb-Of 'predict' $true) -and $far -and ($w.used + (Predict-Use $agent $role)) -gt $cap) { return $false }
  return $true
}
# Last resort when every agent and the paid budget are out (allOut 'free-models'): a free OpenRouter model for any role.
function Pick-FreeModel([string]$role) {
  if (-not (Get-Command opencode -ErrorAction SilentlyContinue) -or -not (Free-Allowed) -or -not (OR-Key)) { return '' }
  $live = Get-ORModels
  $chains = Oc-Of 'models' $null
  $ids = @()
  foreach ($r in @($role, 'tester')) { if ($chains -and $chains.PSObject.Properties[$r]) { $ids += @($chains.$r) } }
  $ids += 'openrouter/free'   # OpenRouter's own router across free tool-calling models
  foreach ($id in $ids) {
    foreach ($c in @($(if ($id -like '*:free' -or $id -eq 'openrouter/free') { $id } else { "$id`:free" }))) {
      if ($live.Count -and -not $live.ContainsKey($c)) { continue }
      if ($live.Count -and -not $live[$c].tools) { continue }
      if (Quota-Out "opencode/$c") { continue }
      return $c
    }
  }
  return ''
}
# OpenRouter paid budget: what this period may spend by now (budgetPace weekly/daily/none) and what it has spent.
function OR-Budget {
  $k = Get-ORKeyInfo
  if (-not $k -or -not $k.limit) { return $null }
  $limit = [double]$k.limit
  $used = if ($null -ne $k.remaining) { $limit - [double]$k.remaining } else { [double]$k.usage }
  $now = [datetime]::UtcNow; $dim = [datetime]::DaysInMonth($now.Year, $now.Month)
  $pace = ([string](Oc-Of 'budgetPace' 'weekly')).ToLower()
  $share = switch ($pace) {
    'daily'  { [math]::Min(1.0, $now.Day / $dim) }
    'none'   { 1.0 }
    default  { [math]::Min(1.0, ([math]::Floor(($now.Day - 1) / 7) + 1) * 7 / $dim) }
  }
  $allowed = [math]::Min($limit * $share, $limit * [double](Oc-Of 'budgetStopPercent' 90) / 100)
  return [ordered]@{ limit = $limit; used = [math]::Round($used, 4); allowedNow = [math]::Round($allowed, 2); pace = $pace
                     paidOk = ($used -lt $allowed); reset = $k.reset }
}

# What the panel shows about quotas (status.json "outlook" and usage/outlook.json): per agent its state, and for Claude
# and Codex a "safe until" estimate from this relay's own burn rate (5-hour use per minute over the last hour).
# The burn samples live in usage/burn.json, shared by every relay and the 10-minute refresher (tools/usage-refresh.ps1).
function Get-Outlook {
  $o = [ordered]@{ at = (Get-Date).ToString('o') }
  $burnFile = Join-Path $script:usageDir 'burn.json'
  $burn = @{ claude = New-Object System.Collections.ArrayList; codex = New-Object System.Collections.ArrayList }
  $saved = Read-Json $burnFile
  foreach ($a in @('claude', 'codex')) {
    if ($saved -and $saved.$a) { foreach ($s in @($saved.$a)) { try { [void]$burn[$a].Add(@{ t = [datetime]$s.t; u = [double]$s.u }) } catch {} } }
  }
  foreach ($a in @('claude', 'codex')) {
    $w = Plan-5h $a
    if (-not $w) { $o[$a] = $null; continue }
    $list = $burn[$a]
    # A new sample only when the reading is newer than the last one (several relays may read the same numbers).
    if (-not $list.Count -or ((Get-Date) - $list[$list.Count - 1].t).TotalMinutes -ge 2) { [void]$list.Add(@{ t = Get-Date; u = $w.used }) }
    # A drop means the 5-hour window reset: start the rate again from there.
    if ($list.Count -gt 1 -and $w.used -lt $list[$list.Count - 2].u) { $last = $list[$list.Count - 1]; $list.Clear(); [void]$list.Add($last) }
    while ($list.Count -gt 1 -and ((Get-Date) - $list[0].t).TotalMinutes -gt 60) { $list.RemoveAt(0) }
    $cap = if ($a -eq 'claude') { Claude-Cap 'any' } else { 100.0 }
    $safe = 'ok'
    $first = $list[0]; $mins = ((Get-Date) - $first.t).TotalMinutes
    if ($w.used -ge $cap) { $safe = 'over' }
    elseif ($mins -ge 5 -and $w.used -gt $first.u) {
      $eta = (Get-Date).AddMinutes(($cap - $w.used) / (($w.used - $first.u) / $mins))
      if (-not $w.resets -or $eta -lt $w.resets) { $safe = $eta.ToString('o') }
    }
    $wk = $script:usage.$a.week
    $o[$a] = [ordered]@{ used = $w.used; cap = $cap; resets = $(if ($w.resets) { $w.resets.ToString('o') } else { '' })
                         week = $(if ($wk) { [double]$wk.used } else { $null }); safeUntil = $safe
                         out = $(if (Agent-Out $a) { (Agent-Out $a).ToString('o') } else { '' }) }
  }
  $q = Read-Quota
  $o.antigravity = @($q.Keys | Where-Object { $_ -like 'antigravity/*' -and $q[$_] -gt (Get-Date) } | Sort-Object |
                     ForEach-Object { [ordered]@{ model = $_.Substring(12); until = $q[$_].ToString('o') } })
  $o.opencode = [ordered]@{ budget = $(try { OR-Budget } catch { $null })
                            out = @($q.Keys | Where-Object { $_ -like 'opencode/*' -and $q[$_] -gt (Get-Date) } | ForEach-Object { $_.Substring(9) }) }
  try {
    $keep = [ordered]@{}
    foreach ($a in @('claude', 'codex')) { $keep[$a] = @($burn[$a] | ForEach-Object { [ordered]@{ t = $_.t.ToString('o'); u = $_.u } }) }
    [IO.File]::WriteAllText($burnFile, ($keep | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  return $o
}

# Next Antigravity model with quota left that may do this role ('' = none).
function Pick-AgyModel([string]$role) {
  $basic = @(Fb-Of 'basicModels' @('gpt-oss'))
  foreach ($m in @((Fb-Of 'models' $null).antigravity)) {
    $m = ([string]$m).ToLower()
    if (-not $script:modelNames['antigravity'].Contains($m)) { continue }
    if ($m -in $basic -and $role -ne 'tester') { continue }
    if (Quota-Out (Quota-Key 'antigravity' $m)) { continue }
    return $m
  }
  return ''
}
# Another agent that can take this role now: @{ agent; model } or $null.
function Pick-Agent([string]$role, [string]$exclude) {
  foreach ($a in @(Fb-Of 'agents' @('codex', 'claude', 'antigravity'))) {
    $a = ([string]$a).ToLower()
    if ($a -eq $exclude -or -not $script:agents.ContainsKey($a)) { continue }
    if ($a -eq 'opencode') {
      if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { continue }
      $m = Pick-OpenCodeModel $role
      if ($m) { return @{ agent = $a; model = $m } }
      continue
    }
    if ($a -eq 'antigravity') {
      $def = Model-Short 'antigravity' $script:agyDefaultRaw
      if (-not (Quota-Out (Quota-Key 'antigravity' $def))) { return @{ agent = $a; model = '' } }
      $m = Pick-AgyModel $role
      if ($m) { return @{ agent = $a; model = $m } }
      continue
    }
    if (Agent-Fits $a $role) { return @{ agent = $a; model = '' } }   # plan left, Claude reserve, prediction (D-029)
  }
  # Everyone is out (plans and the paid OpenRouter budget): free OpenRouter models for any role, flagged (D-029).
  if (([string](Fb-Of 'allOut' 'free-models')) -eq 'free-models') {
    $m = Pick-FreeModel $role
    if ($m) { return @{ agent = 'opencode'; model = $m; lastResort = $true } }
  }
  return $null
}
# Before a stage: which agent, model and effort, given what is out of quota. Returns @{ agent; model; effort; notes }.
function Plan-Stage($st, [string]$model, [string]$lvl) {
  # notes = real fallbacks (shown with the panel's switch mark); info = plain remarks, printed only.
  $plan = @{ agent = $st.Agent; model = $model; effort = $lvl; notes = @(); info = @() }
  if (-not $script:fbOn) { return $plan }
  $role = $st.Role
  $p = $null   # set here: PowerShell's dynamic scoping would otherwise read a caller's $p below
  if ($plan.agent -eq 'opencode') {
    # The picker chooses the model (free first where allowed, budget, quota); a model you named is kept if usable.
    $want = if ($model -and $model -ne 'default') { $script:modelNames['opencode'][$model] } else { '' }
    if (-not $want -and $model -and $model -ne 'default') { $want = $model }
    $trial = if (-not $want) { Pick-TrialModel $role } else { '' }
    if ($want -and -not (Quota-Out "opencode/$want")) { $plan.model = $want }
    elseif ($trial) { $plan.model = $trial; $plan.trial = $true; $plan.info += "trial: $trial for this $role stage (1 in $((Default-Of 'scout' $null).trialEvery) tester stages, picked by the model scout)" }
    else {
      $m = Pick-OpenCodeModel $role
      if ($m) { $plan.model = $m; $plan.info += "OpenCode picked $m for the $role" }
      else {
        $p = Pick-Agent $role 'opencode'
        if ($p) { $plan.agent = $p.agent; $plan.model = $p.model; $plan.notes += "no OpenRouter model fits now (budget, quota or listing): $($p.agent) takes the $role stage" }
        if ($p -and $p.lastResort) { $plan.notes += "every plan and the paid OpenRouter budget are out: running on the free model $($p.model) (last resort)" }
      }
    }
    return $plan
  }
  if ($plan.agent -eq 'antigravity') {
    $cur = if ($model -and $model -ne 'default') { Model-Short 'antigravity' $model } else { Model-Short 'antigravity' $script:agyDefaultRaw }
    $out = Quota-Out (Quota-Key 'antigravity' $cur)
    if ($out) {
      $alt = Pick-AgyModel $role
      if ($alt) { $plan.model = $alt; $plan.notes += "Antigravity's $(if ($cur) { $cur } else { 'default model' }) is out of quota until $($out.ToString('HH:mm')): using its $alt model" }
      else {
        $p = Pick-Agent $role 'antigravity'
        if ($p) { $plan.agent = $p.agent; $plan.model = $p.model; $plan.notes += "every Antigravity model for this role is out of quota: $($p.agent) takes the $role stage" }
      }
    }
  } elseif ($plan.agent -in @('claude', 'codex')) {
    if (-not (Agent-Fits $plan.agent $role)) {
      $w = Plan-5h $plan.agent
      $why = if ($plan.agent -eq 'claude' -and $w -and $w.used -ge (Claude-Cap $role)) { "Claude is at $([int]$w.used) % of its 5-hour limit (reserve: $([int](Claude-Cap $role)) % for this role, the rest stays for you)" }
             elseif ($w) { "$($plan.agent) is at $([int]$w.used) % of its 5-hour limit and a $role stage usually takes ~$([int](Predict-Use $plan.agent $role)) %" }
             else { "$($plan.agent) is out of plan quota" }
      $p = Pick-Agent $role $plan.agent
      if ($p) { $plan.notes += "${why}: $($p.agent) takes the $role stage"; $plan.agent = $p.agent; $plan.model = $p.model }
      else { $plan.info += "$why, but no other agent fits either: starting it anyway (the quota watcher waits at most $($script:fbMaxWait) min)" }
    }
  }
  if ($p -and $p.lastResort) { $plan.notes += "every plan and the paid OpenRouter budget are out: running on the free model $($p.model) (last resort)" }
  # Near a plan limit: one effort step lower, only where it costs little (D-027). Never the executor or a once-role
  # (planner); the judge only in fix rounds and not below medium; the tester not below low.
  $levels = @('low', 'medium', 'high', 'xhigh', 'max')
  $isOnce = [bool]($script:teamRoles | Where-Object { $_.role -eq $role -and $_.once })
  $isJudge = ($role -eq $script:judgeRole)
  $mayLower = ($role -in @(Fb-Of 'lowerEffortRoles' @('tester', 'reviewer'))) -and $role -ne 'executor' -and -not $isOnce -and
              (-not $isJudge -or $script:round -ge 1)
  if ($mayLower -and $plan.agent -in @('claude', 'codex') -and $plan.effort -in $levels) {
    $used = Plan-UsedPercent $plan.agent
    $floor = if ($isJudge) { 'medium' } else { 'low' }
    $ix = [array]::IndexOf($levels, $plan.effort)
    if ($used -ge [double](Fb-Of 'lowerEffortAtPercent' 85) -and $ix -gt [array]::IndexOf($levels, $floor)) {
      $plan.notes += "$($plan.agent) plan use is at $([int]$used) %: $role effort $($plan.effort) -> $($levels[$ix - 1]) to stretch the quota"
      $plan.effort = $levels[$ix - 1]
    }
  }
  return $plan
}
# Antigravity: switch the running session's model with its /model picker (search, Enter), then put the saved
# default back (the picker saves its choice as the default for every new session). $true when the screen confirms.
function Switch-AgyModel([string]$terminal, [string]$short) {
  $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
  $search = $script:agySearch[$short]; if (-not $search) { return $false }
  [void](Invoke-Native $hcExe @('send', $terminal, '/model') 60)   # hc send submits it; no extra Enter (that would pick the current model)
  Start-Sleep -Seconds 3
  [void](Invoke-Native $hcExe (@('keys', $terminal) + @($search.ToCharArray() | ForEach-Object { [string]$_ })) 30)
  Start-Sleep -Seconds 2
  $scr = (Invoke-Native $hcExe @('read', $terminal, '--lines', '12') 30).Out
  if ($scr -notmatch "(?i)Search:\s*$([regex]::Escape($search))") { [void](Invoke-Native $hcExe @('keys', $terminal, 'escape') 30); return $false }
  [void](Invoke-Native $hcExe @('keys', $terminal, 'enter') 30)
  Start-Sleep -Seconds 2
  $scr = (Invoke-Native $hcExe @('read', $terminal, '--lines', '40') 30).Out
  $ok = ($scr -match '(?i)Model set to') -and ((Model-Short 'antigravity' ([regex]::Matches($scr, '(?i)Model set to ([^\r\n]+)') | Select-Object -Last 1).Groups[1].Value) -eq $short)
  if ($script:agyDefaultRaw -and (Test-Path $script:agySettings)) {
    try {
      $raw = Get-Content $script:agySettings -Raw -Encoding UTF8
      $fixed = [regex]::Replace($raw, '("model"\s*:\s*)"[^"]*"', { param($m) $m.Groups[1].Value + (ConvertTo-Json $script:agyDefaultRaw) }, 1)
      if ($fixed -ne $raw) { [IO.File]::WriteAllText($script:agySettings, $fixed, (New-Object System.Text.UTF8Encoding($false))) }
    } catch {}
  }
  return $ok
}
# Minutes until a quota is back, read from the agent's screen ("Resets in 2h20m59s", "try again in 45 min"), else from
# the plan use the relay reads; -1 when unknown.
function Reset-Minutes([string]$agent, [string]$screen) {
  # OpenRouter's daily cap on free models resets at midnight UTC.
  if ($screen -match '(?i)free-models-per-day') { return [int][math]::Ceiling(([datetime]::UtcNow.Date.AddDays(1) - [datetime]::UtcNow).TotalMinutes) }
  $m = [regex]::Matches($screen, '(?i)(?:resets?|try again) in\s*(?:(\d+)\s*h(?:ours?|rs?)?)?\s*(?:(\d+)\s*m(?:in(?:utes?|s)?)?)?\s*(?:(\d+)\s*s(?:ec(?:onds?|s)?)?)?') | Select-Object -Last 1
  if ($m -and ($m.Groups[1].Success -or $m.Groups[2].Success)) {
    return [int]$m.Groups[1].Value * 60 + [int]$m.Groups[2].Value + [int]([int]$m.Groups[3].Value -gt 0)
  }
  if ($agent -in @('claude', 'codex')) {
    $script:usage = Get-PlanUsage; $script:usageAt = Get-Date
    $v = $script:usage.$agent
    $r = @($v.fiveHour, $v.week) | Where-Object { $_ -and $_.resets -and $_.used -ge 95 } | ForEach-Object { [datetime]$_.resets } |
         Where-Object { $_ -gt (Get-Date) } | Sort-Object | Select-Object -First 1
    if ($r) { return [int][math]::Ceiling(($r - (Get-Date)).TotalMinutes) }
  }
  return -1
}

# ---------- OpenCode on OpenRouter: live model list, budget, picker (D-028, relay-defaults.json "opencode") ----------
# Before each OpenCode stage the relay picks the first model of the role's chain that OpenRouter lists right now with
# tool calling, that has quota left (usage/quota.json), that the budget allows (paid models stop at budgetStopPercent of
# the key's limit) and, for a project allowed to use free models, its ":free" variant when one is listed. The model
# list is cached for 6 hours (usage/openrouter-models.json); prices are kept once a day (usage/openrouter-prices.jsonl)
# for the model report. The key is read from OPENROUTER_API_KEY and only sent to openrouter.ai.
$script:oc = Default-Of 'opencode' $null
function Oc-Of([string]$k, $d) { if ($script:oc -and $script:oc.PSObject.Properties[$k] -and $null -ne $script:oc.$k) { return $script:oc.$k }; return $d }
function OR-Key { if ($env:OPENROUTER_API_KEY) { return $env:OPENROUTER_API_KEY }; return [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User') }
$script:orModels = $null
function Get-ORModels {
  if ($script:orModels -and ((Get-Date) - $script:orModels.read).TotalMinutes -lt 30) { return $script:orModels.list }
  $cache = Join-Path $script:usageDir 'openrouter-models.json'
  $c = Read-Json $cache
  $fresh = $c -and $c.at -and ((Get-Date) - [datetime]$c.at).TotalHours -lt 6
  if (-not $fresh) {
    try {
      $r = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/models' -TimeoutSec 60
      $list = @($r.data | ForEach-Object {
        [ordered]@{ id = [string]$_.id; name = [string]$_.name; ctx = [int64]$_.context_length
                    tools = (@($_.supported_parameters) -contains 'tools')
                    inPrice = [math]::Round([double]$_.pricing.prompt * 1e6, 4); outPrice = [math]::Round([double]$_.pricing.completion * 1e6, 4) } })
      $c = [ordered]@{ at = (Get-Date).ToString('o'); models = $list }
      [IO.File]::WriteAllText($cache, ($c | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))
      Save-ORPrices $list
      $c = Read-Json $cache
    } catch { Write-Host "  OpenRouter model list not reachable ($($_.Exception.Message)); using the last one." -ForegroundColor DarkYellow }
  }
  $h = @{}
  if ($c) { foreach ($m in @($c.models)) { $h[[string]$m.id] = $m } }
  $script:orModels = @{ read = Get-Date; list = $h }
  return $h
}
# Once a day: today's prices of the models the relay may pick plus every free tool-calling model (for the report).
function Save-ORPrices($list) {
  $p = Join-Path $script:usageDir 'openrouter-prices.jsonl'
  $day = (Get-Date).ToString('yyyy-MM-dd')
  if ((Test-Path $p) -and ((Get-Item $p).LastWriteTime.ToString('yyyy-MM-dd') -eq $day)) { return }
  $want = @{}
  foreach ($r in @((Oc-Of 'models' $null).PSObject.Properties)) { foreach ($id in @($r.Value)) { $want[[string]$id] = $true; $want["$id`:free"] = $true } }
  $rows = foreach ($m in $list) {
    if ($want.ContainsKey($m.id) -or ($m.id -like '*:free' -and $m.tools)) {
      ([ordered]@{ day = $day; id = $m.id; inPrice = $m.inPrice; outPrice = $m.outPrice; ctx = $m.ctx; tools = $m.tools } | ConvertTo-Json -Compress)
    }
  }
  if ($rows) { [IO.File]::AppendAllText($p, (($rows -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false))) }
}
$script:orKey = $null
# The key's limit and use, or $null. Cached 5 minutes.
function Get-ORKeyInfo {
  if ($script:orKey -and ((Get-Date) - $script:orKey.read).TotalMinutes -lt 5) { return $script:orKey.info }
  $k = OR-Key
  $info = $null
  if ($k) {
    try {
      $d = (Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/key' -Headers @{ Authorization = "Bearer $k" } -TimeoutSec 30).data
      $info = [ordered]@{ limit = $d.limit; usage = [double]$d.usage; remaining = $d.limit_remaining; reset = [string]$d.limit_reset }
    } catch {}
  }
  $script:orKey = @{ read = Get-Date; info = $info }
  return $info
}
# May this project send its code to free models (whose providers may keep it)? relay-defaults opencode.freeModelProjects.
function Free-Allowed {
  $f = @(Oc-Of 'freeModelProjects' @('all'))
  if ($f -contains 'all') { return $true }
  return ($f | Where-Object { $_ -ieq (Split-Path $Folder -Leaf) }).Count -gt 0
}
# OpenRouter model id for an OpenCode stage of this role, or '' when nothing qualifies. $skip: ids not to use.
# Trials (D-032): 1 in scout.trialEvery tester stages tries the model scout's trial model (usage/model-scout.json),
# only on projects that may use free models and only when that model is free, listed with tool calling and not out.
function Pick-TrialModel([string]$role) {
  if ($role -ne 'tester' -or -not (Free-Allowed) -or -not (OR-Key)) { return '' }
  $every = 5; $sc = Default-Of 'scout' $null; if ($sc -and $sc.trialEvery) { $every = [int]$sc.trialEvery }
  if ($every -le 0) { return '' }
  $cf = Join-Path $script:usageDir 'trial-counter.json'
  $n = 0; try { $n = [int](Read-Json $cf).tester } catch {}
  $n++
  try { [IO.File]::WriteAllText($cf, ((@{ tester = $n }) | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  if ($n % $every -ne 0) { return '' }
  $scout = Read-Json (Join-Path $script:usageDir 'model-scout.json')
  $t = if ($scout) { [string]$scout.roles.tester.trial } else { '' }
  if (-not $t -or $t -notlike '*:free') { return '' }
  $live = Get-ORModels
  if ($live.Count -and (-not $live.ContainsKey($t) -or -not $live[$t].tools)) { return '' }
  if (Quota-Out "opencode/$t") { return '' }
  return $t
}
function Pick-OpenCodeModel([string]$role, [string[]]$skip = @()) {
  if (-not (OR-Key)) { return '' }   # no OpenRouter key: OpenCode can't run any model, so it never gets a stage
  $chains = Oc-Of 'models' $null
  $chain = @()
  if ($chains -and $chains.PSObject.Properties[$role]) { $chain = @($chains.$role) }
  elseif ($chains -and $chains.PSObject.Properties['tester']) { $chain = @($chains.tester) }
  $live = Get-ORModels
  # Paid models only while this period's spend is under the paced share (weekly by default) and under budgetStopPercent.
  $bud = OR-Budget
  $budgetLow = $bud -and -not $bud.paidOk
  $free = Free-Allowed
  foreach ($id in $chain) {
    $id = [string]$id
    $cands = @()
    if ($free -and $id -notlike '*:free' -and $live.ContainsKey("$id`:free")) { $cands += "$id`:free" }
    $cands += $id
    foreach ($c in $cands) {
      if ($c -in $skip) { continue }
      if ($live.Count -and -not $live.ContainsKey($c)) { continue }        # not listed now
      if ($live.Count -and -not $live[$c].tools) { continue }              # a coding agent needs tool calling
      if (Quota-Out "opencode/$c") { continue }
      $isFree = ($c -like '*:free') -or ($live.Count -and $live[$c].outPrice -eq 0 -and $live[$c].inPrice -eq 0)
      if ($isFree -and -not $free) { continue }
      if (-not $isFree -and $budgetLow) { continue }
      return $c
    }
  }
  return ''
}
# Tokens and exact cost of the OpenCode sessions started in this project since a stage began (from opencode export).
function OpenCode-Usage([datetime]$since) {
  $exe = Get-Command opencode -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $exe) { return $null }
  $bin = $exe.Source
  if ($bin -like '*.ps1' -or $bin -like '*.cmd') {
    $cand = Join-Path (Split-Path $bin) 'node_modules\opencode-ai\bin\opencode.exe'
    if (Test-Path $cand) { $bin = $cand } else { return $null }
  }
  $old = [Environment]::CurrentDirectory
  try {
    [Environment]::CurrentDirectory = $Folder
    $r = Invoke-Native $bin @('session', 'list', '--format', 'json', '-n', '20') 60
    # ForEach-Object unrolls the array (Windows PowerShell 5.1's ConvertFrom-Json passes a JSON array on as one object).
    $ses = @(($r.Out.Substring([Math]::Max(0, $r.Out.IndexOf('[')))) | ConvertFrom-Json | ForEach-Object { $_ })
    $tok = 0; $cost = 0.0; $models = @{}
    foreach ($s in $ses) {
      if ([string]$s.directory -ne $Folder) { continue }
      if ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.created).LocalDateTime -lt $since.AddSeconds(-30)) { continue }
      $e = Invoke-Native $bin @('export', [string]$s.id) 120
      $j = $e.Out.Substring([Math]::Max(0, $e.Out.IndexOf('{'))) | ConvertFrom-Json
      foreach ($m in @($j.messages)) {
        $i = $m.info
        if ($i.role -ne 'assistant') { continue }
        $cost += [double]$i.cost; $tok += [int64]$i.tokens.total
        if ($i.modelID) { $models[[string]$i.modelID] = $true }
      }
    }
    return [ordered]@{ tokens = $tok; cost = [math]::Round($cost, 5); models = @($models.Keys) }
  } catch { return $null } finally { [Environment]::CurrentDirectory = $old }
}

# ---------- performance record: one line per finished stage, every agent (usage/model-stats.jsonl) ----------
# tools/model-report.ps1 turns it into the model report (pass rates, minutes, cost, quota trouble, prices).
function Write-StageStats($entry) {
  try {
    $row = [ordered]@{ at = (Get-Date).ToString('o'); project = (Split-Path $Folder -Leaf); relay = $script:relayStart.ToString('o')
      task = [string]$entry.task; round = [int]$entry.round; n = [int]$entry.n; role = $entry.role; agent = $entry.agent
      model = [string]$entry.model; effort = [string]$entry.effort; minutes = $entry.minutes; state = $entry.state
      verdict = [string]$entry.verdict; judge = ($entry.role -eq $script:judgeRole); switches = @($entry.switches).Count
      tokens = $(if ($entry.usage -and $entry.usage.tokens) { [int64]$entry.usage.tokens } else { $null })
      cost = $(if ($entry.usage -and $null -ne $entry.usage.cost) { [double]$entry.usage.cost } else { $null })
      planBefore = $entry.planBefore; planAfter = $entry.planAfter
      logLines = $entry.logLines; logFilled = [bool]$entry.logFilled; sigOk = [bool]$entry.sigOk; commits = $entry.commits
      compliant = ($entry.state -eq 'done' -and $entry.logLines -gt 0 -and [bool]$entry.sigOk -and $entry.commits -gt 0)
      trial = [bool]$entry.trial
      overnight = [bool]$Overnight }
    [IO.File]::AppendAllText((Join-Path $script:usageDir 'model-stats.jsonl'), (($row | ConvertTo-Json -Compress) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

# Live status for Herdr panels: .ai/relay/status.json (never committed; .ai/relay is git-ignored)
$script:history = New-Object System.Collections.ArrayList
$script:queueList = New-Object System.Collections.ArrayList
$script:currentTask = ''
$script:usage = $null; $script:usageAt = [datetime]::MinValue
function Write-Status([string]$state, $st = $null, [string]$label = '', [string]$terminal = '', [string]$waiting = '') {
  try {
    if (((Get-Date) - $script:usageAt).TotalSeconds -ge 60) {
      $script:usage = Get-PlanUsage; $script:usageAt = Get-Date
      [IO.File]::WriteAllText((Join-Path $script:usageDir 'plan.json'), ($script:usage | ConvertTo-Json -Compress -Depth 5),
        (New-Object System.Text.UTF8Encoding($false)))
      foreach ($h in $script:history) { if ($h.state -eq 'running' -or -not $h.usage) { $h.usage = Stage-Usage $h } }
      try {
        $script:outlook = Get-Outlook
        [IO.File]::WriteAllText((Join-Path $script:usageDir 'outlook.json'), ($script:outlook | ConvertTo-Json -Compress -Depth 5),
          (New-Object System.Text.UTF8Encoding($false)))
      } catch {}
    }
    $o = [ordered]@{
      state    = $state                     # running | waiting | paused | finished | stopped
      waiting  = $waiting                   # the question the relay is asking you, if any
      error    = $(if ($script:fatal) { [string]$script:fatal } else { '' })   # why it stopped, if an error ended it
      stage    = $script:n
      role     = $(if ($st) { $st.Role } else { '' })
      agent    = $(if ($st) { $st.Agent } else { '' })
      label    = $label
      terminal = $terminal
      round    = $script:round
      maxRounds = $MaxRounds
      verdict  = $(if ($script:verdict) { $script:verdict } else { '' })
      goal     = $goalText
      started  = $(if ($script:stageStart) { $script:stageStart.ToString('o') } else { '' })
      updated  = (Get-Date).ToString('o')
      relayStarted = $script:relayStart.ToString('o')
      relayTerminal = [string]$env:HC_TERMINAL_ID   # this relay's own Herdr tab: where its questions are answered
      overnight = [bool]$script:Overnight
      until    = $(if (-not $script:Overnight) { '' } elseif ($script:untilAt -ne [datetime]::MaxValue) { $script:untilAt.ToString('o') } else { 'done' })
      maxCycles = [int]$script:MaxCycles    # overnight cycle limit; 0 = none
      queueMode = [bool]($script:Queue -or ([string]$script:Tasks).Trim())
      cycle    = [int]$script:cycle
      nightBranch = [string]$script:nightBranch
      firstPass = @($first).Count           # stages in the first pass
      loopSize  = @($loopStages).Count      # stages per fix round
      plannedMax = @($first).Count + @($loopStages).Count * $MaxRounds
      timeoutMin = $TimeoutMin
      # $script: on purpose: PowerShell scoping is dynamic, so a bare $Stages/$Loop here would read Run-Pass's
      # $stages / Run-Job's $loop (lists of stage objects) when Write-Status is called from inside them.
      config   = [ordered]@{ team = $script:Team; judge = $script:judgeRole; stages = [string]$script:Stages; loop = [string]$script:Loop
                             effort = [string]$script:Effort; model = [string]$script:Model; askEachRound = [bool]$script:AskEachRound
                             here = $(if ($HereTerminal) { "$HereAgent ($HereTerminal)" } else { '' }) }
      stages   = @($script:history)
      queue    = @($script:queueList)       # queue mode: one entry per task (id, title, agents, state, verdict)
      currentTask = $script:currentTask
      usage    = $script:usage
      outlook  = $script:outlook            # quota planner (D-029): states, safe-until, Antigravity outages, OpenRouter budget
    }
    $json = $o | ConvertTo-Json -Compress -Depth 6
    [IO.File]::WriteAllText((Join-Path $relayDir 'status.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

# ---------- overnight helpers (start-up and "Make overnight" share them) ----------
function Set-NightAgents {
  if (-not $script:skipPerms) { return }
  if ($script:agents['claude'] -notcontains '--dangerously-skip-permissions') { $script:agents['claude'] = $script:agents['claude'] + @('--dangerously-skip-permissions') }
  $script:agents['codex'] = @('codex', '--no-daemon', '--dangerously-bypass-approvals-and-sandbox')
  if ($script:agents['antigravity'] -notcontains '--dangerously-skip-permissions') { $script:agents['antigravity'] = $script:agents['antigravity'] + @('--dangerously-skip-permissions') }
  if ($script:agents['opencode'] -notcontains '--auto') { $script:agents['opencode'] = $script:agents['opencode'] + @('--auto') }
}
function Keep-Awake {
  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED: Windows doesn't sleep while this process runs; ends with the process.
  try {
    if (-not ('RelayNight.Power' -as [type])) {
      Add-Type -Namespace RelayNight -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction Stop
    }
    [void][RelayNight.Power]::SetThreadExecutionState([uint32]2147483649)
  } catch { Write-Host "  couldn't keep the PC awake: $($_.Exception.Message)" -ForegroundColor Yellow }
}
# "Make overnight" on a running relay: from the next step on, everything an overnight run does. The click was the
# user's yes, so no pre-flight question; the agent already running keeps its own permission mode.
function Convert-ToOvernight {
  if (-not (Test-Path $overnightFile)) { return }
  # The file may carry the limits chosen in the panel box / 'relay overnight -Until .. -MaxCycles ..' as JSON.
  $req = $null
  try { $req = (Get-Content $overnightFile -Raw) | ConvertFrom-Json } catch {}
  Remove-Item $overnightFile -Force -ErrorAction SilentlyContinue
  if ($req -and $req.PSObject.Properties['until'] -and "$($req.until)") { $script:Until = [string]$req.until }
  if ($req -and $req.PSObject.Properties['maxCycles'] -and $null -ne $req.maxCycles) { $script:MaxCycles = [int]$req.maxCycles }
  if ($Overnight) {
    # Already overnight: just new limits (e.g. extend 07:00 to 10:00, or 'done').
    Set-NightLimits
    Write-Host "`n== Overnight limits updated == now $(Night-LimitText)." -ForegroundColor Yellow
    Write-Status 'running'
    return
  }
  $script:Overnight = $true
  Apply-Overnight
  Set-NightAgents
  $script:nightStart = Get-Date
  $script:nightBase = (Git-Out @('rev-parse', '--short', 'HEAD')).Trim()
  $script:nightBranch = 'relay/overnight-' + (Get-Date).ToString('yyyyMMdd-HHmm')
  $script:pendingBranch = [bool]$script:nightBase          # switch at the next stage start, not under a working agent
  if (-not $script:nightBase) { $script:nightBranch = ''; Write-Host '  (not a git repository: no overnight branch)' -ForegroundColor Yellow }
  if (-not (Codex-Trusts $Folder)) {
    Add-Content -Path (Join-Path $HOME '.codex\config.toml') -Value "`n[projects.'$($Folder.TrimEnd('\'))']`ntrust_level = `"trusted`"" -Encoding UTF8
    Write-Host '  marked this folder trusted in Codex, so Codex stages don''t stop at its trust question.' -ForegroundColor DarkGray
  }
  Keep-Awake
  Write-Host ("`n== Switched to OVERNIGHT mode == no more questions; next stages skip all permissions; " +
    "$(if ($script:nightBranch) { "new branch $($script:nightBranch) from the next stage; " })keeps going $(Night-LimitText).") -ForegroundColor Yellow
  Write-Status 'running'
}

# A question the relay asks in its tab, that "Make overnight" can also answer: it reads keys itself (no blocking
# Read-Host) so it can notice the OVERNIGHT switch meanwhile and then take $nightAnswer.
function Read-Choice([string]$prompt, [string]$nightAnswer) {
  if ($Overnight) { Write-Host "$prompt (overnight: $nightAnswer)"; return $nightAnswer }
  try { [void][Console]::KeyAvailable } catch { return (Read-Host $prompt) }   # no console keys here: plain Read-Host
  Write-Host -NoNewline "${prompt}: "
  $buf = New-Object System.Text.StringBuilder
  while ($true) {
    if (Test-Path $overnightFile) { Write-Host ''; Convert-ToOvernight; Write-Host "  (answered '$nightAnswer' for you: overnight)"; return $nightAnswer }
    while ([Console]::KeyAvailable) {
      $k = [Console]::ReadKey($true)
      if ($k.Key -eq 'Enter') { Write-Host ''; return $buf.ToString() }
      if ($k.Key -eq 'Backspace') { if ($buf.Length) { [void]$buf.Remove($buf.Length - 1, 1); Write-Host -NoNewline "`b `b" }; continue }
      if ($k.KeyChar -and [int]$k.KeyChar -ge 32) { [void]$buf.Append($k.KeyChar); Write-Host -NoNewline $k.KeyChar }
    }
    Start-Sleep -Milliseconds 250
  }
}

function Check-Controls {
  Convert-ToOvernight
  if (Test-Path $stopFile) {
    Write-Status 'stopped'; Write-Host "`nSTOP file found - relay stopped. Agents keep running in their tabs." -ForegroundColor Red
    if (Get-Command Write-NightReport -ErrorAction SilentlyContinue) { Write-NightReport 'stopped by you' }
    Show-Summary; exit 2
  }
  if (Test-Path $pauseFile) {
    Write-Status 'paused'
    Write-Host "  PAUSED - delete $pauseFile to continue (or create STOP to end)." -ForegroundColor Magenta
    while ((Test-Path $pauseFile) -and -not (Test-Path $stopFile)) { Start-Sleep -Seconds 5 }
    if (Test-Path $stopFile) { Check-Controls }
    Write-Host '  resumed.' -ForegroundColor Magenta
    Write-Status 'running'
  }
}

# ---------- cleanup: no stage may leave servers or test runs behind ----------
# 2026-11-22: a Codex tester left a test server holding port 8787; the next executor's e2e tests reused the dead
# server and hung for two hours. So after every finished stage the relay stops what that stage left running:
#  - under the stage's terminal (below the agent): anything holding a TCP port, or a runtime/shell running a
#    dev/test/server command;
#  - orphans (parent already exited) that hold a port, started during the stage and mention the project folder.
# Never touched: the agent itself, its MCP servers and helpers (command line names mcp / modelcontextprotocol,
# or the program lives in the agent's own install folder), and anything outside the stage's tree and project.
$script:cleanupRuntimes = '^(node|deno|bun|python|python3|py|pythonw|php|ruby|java|javaw|dotnet|go|cargo|workerd|esbuild|chrome|msedge|firefox|cmd|powershell|pwsh|bash|sh)\.exe$'
$script:cleanupWords = '(?i)\b(dev|serve|server|start|preview|watch|test|tests|e2e|playwright|vitest|jest|mocha|pytest|wrangler|vite|next|nuxt|astro|webpack|uvicorn|gunicorn|flask|manage\.py|http\.server|live-server|nodemon)\b'
$script:cleanupKeep = '(?i)mcp|modelcontextprotocol|\\\.local\\bin\\claude|\\OpenAI\\Codex\\|\\\.gemini\\|\\WindowsApps\\'
function Stop-StageLeftovers([string]$terminal, [datetime]$since) {
  $stopped = @()
  try {
    $procs = @{}; Get-CimInstance Win32_Process | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
    $ports = @{}
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
      $o = [int]$_.OwningProcess; if ($o -gt 4) { if (-not $ports[$o]) { $ports[$o] = @() }; $ports[$o] += $_.LocalPort } }
    $kids = @{}; foreach ($p in $procs.Values) { $pp = [int]$p.ParentProcessId; if (-not $kids[$pp]) { $kids[$pp] = @() }; $kids[$pp] += [int]$p.ProcessId }
    $subtree = { param($id) $all = @(); $q = @($id); while ($q) { $x = $q[0]; $q = @($q | Select-Object -Skip 1); foreach ($c in @($kids[$x])) { if ($c) { $all += $c; $q += $c } } }; $all }
    $keep = { param($p) ("$($p.CommandLine) $($p.ExecutablePath)" -match $script:cleanupKeep) -or ($p.Name -match '^(claude|codex|agy|antigravity[^\\]*|herdr[^\\]*|hc)\.exe$') }
    $targets = @{}   # plain hashtable: an [ordered] one reads $targets[<int>] as a position, not a key
    # 1. Below the stage's agent, inside its terminal.
    $root = $null; $agentPid = $null
    if ($terminal) {
      $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
      $g = Invoke-Native $hcExe @('get', $terminal, '--json') 30
      if ($g.Code -eq 0) { try { $gj = $g.Out | ConvertFrom-Json; $root = [int]$gj.pid; $agentPid = [int]$gj.foreground.pid } catch {} }
    }
    if ($root -and $procs[$root]) {
      $top = if ($agentPid -and $procs[$agentPid]) { $agentPid } else { $root }
      foreach ($id in (& $subtree $top)) {
        $p = $procs[$id]; if (-not $p -or (& $keep $p)) { continue }
        if (@(& $subtree $id | ForEach-Object { $procs[$_] } | Where-Object { $_ -and (& $keep $_) }).Count) { continue }   # holds an MCP/helper
        $listens = [bool]$ports[$id] -or [bool](@(& $subtree $id | Where-Object { $ports[$_] }).Count)
        if ($listens -or (($p.Name -match $script:cleanupRuntimes) -and ("$($p.CommandLine)" -match $script:cleanupWords))) { $targets[$id] = $p }
      }
    }
    # 2. Orphaned servers from this stage in this project.
    $folderRx = [regex]::Escape($Folder.TrimEnd('\'))
    foreach ($id in $ports.Keys) {
      $p = $procs[$id]; if (-not $p -or $targets.Contains($id) -or (& $keep $p)) { continue }
      if ($procs[[int]$p.ParentProcessId]) { continue }                                     # parent alive: not an orphan
      if ($p.CreationDate -and $p.CreationDate -lt $since) { continue }                      # older than the stage
      if ("$($p.CommandLine) $($p.ExecutablePath)" -notmatch $folderRx) { continue }        # not this project's
      $targets[$id] = $p
    }
    # Stop only the top-most targets (taskkill /t takes their children with them).
    foreach ($id in @($targets.Keys)) {
      $up = $procs[[int]$targets[$id].ParentProcessId]; $covered = $false
      while ($up) { if ($targets.Contains([int]$up.ProcessId)) { $covered = $true; break }; $up = $procs[[int]$up.ParentProcessId] }
      if ($covered) { continue }
      $p = $targets[$id]
      $portList = @(& $subtree $id | ForEach-Object { $ports[$_] }) + @($ports[$id]) | Where-Object { $_ } | Select-Object -Unique
      $what = "$($p.Name) $id" + $(if ($portList) { " (port $($portList -join ','))" } else { '' })
      $r = Invoke-Native 'taskkill.exe' @('/pid', "$id", '/t', '/f') 30
      if ($r.Code -eq 0) { $stopped += $what } else { $stopped += "$what (could not stop: $($r.Err.Trim()))" }
    }
  } catch { $stopped += "cleanup error: $($_.Exception.Message)" }
  if ($stopped) { Write-Host "  cleaned up what the stage left running: $($stopped -join '; ')" -ForegroundColor DarkYellow }
  return ,$stopped
}

# ---------- overnight watchdog ----------
# Every minute it reads the stage agent's screen. Plan limit text ("usage limit", "rate limit", ...): wait (up to the
# reset time Claude/Codex reported, checking every 30 min) and then tell the agent to carry on. No change on screen for
# stallMinutes: interrupt the agent and tell it to finish; the second time, give up on the stage.
function Reset-Watch {
  $script:watch = @{ last = ''; changed = Get-Date; checked = [datetime]::MinValue; nudges = 0; limit = $false; limitNudge = [datetime]::MinValue
                     qchecked = [datetime]::MinValue; seen = @{}; handled = $false; qlast = ''; limitSince = $null }
}
function Send-Agent([string]$terminal, [string]$text) {
  $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
  [void](Invoke-Native $hcExe @('send', $terminal, $text, '--force') 120)
  Start-Sleep -Milliseconds 1500
  [void](Invoke-Native $hcExe @('keys', $terminal, 'enter') 30)   # Codex takes a pasted Enter as a newline
}
function Stop-Agent([string]$terminal) {
  $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
  [void](Invoke-Native $hcExe @('interrupt', $terminal) 60)
}
function Limit-ResetText([string]$kind) {
  $u = $script:usage; if (-not $u) { return 'soon' }
  $v = $u.$kind; if (-not $v) { return 'soon' }
  $r = @($v.fiveHour, $v.week) | Where-Object { $_ -and $_.resets -and $_.used -ge 95 } | ForEach-Object { [datetime]$_.resets } | Sort-Object | Select-Object -First 1
  if ($r) { return $r.ToString('HH:mm') } else { return 'soon' }
}
function Watch-Stage([string]$terminal, [string]$kind, [int]$i, $st, [string]$label) {
  $w = $script:watch
  if (((Get-Date) - $w.checked).TotalSeconds -lt 60 -or -not $terminal) { return 'ok' }
  $w.checked = Get-Date
  $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
  try { $r = Invoke-Native $hcExe @('read', $terminal, '--lines', '40') 90 } catch { return 'ok' }   # skip this minute (see Check-StageQuota)
  $screen = ($r.Out -replace '\s+', ' ').Trim()
  $tail = if ($screen.Length -gt 1500) { $screen.Substring($screen.Length - 1500) } else { $screen }
  if ($screen -ne $w.last) { $w.last = $screen; $w.changed = Get-Date }
  if ($w.limit) { $w.changed = Get-Date; return 'ok' }   # waiting out a plan limit (Check-StageQuota): not a stall
  # No change on screen for stallMinutes: nudge once, then give up on the stage.
  if (((Get-Date) - $w.changed).TotalMinutes -ge $script:stallMin) {
    if ($w.nudges -ge 1) {
      Write-Host "  stage $i is still stuck after a nudge: interrupting it and moving on." -ForegroundColor DarkYellow
      Stop-Agent $terminal; return 'skip'
    }
    $w.nudges++; $w.changed = Get-Date
    Write-Host "  stage $i shows no progress for $($script:stallMin) min: interrupting and nudging the agent." -ForegroundColor DarkYellow
    Stop-Agent $terminal; Start-Sleep -Seconds 3
    Send-Agent $terminal ("You made no progress for $($script:stallMin) minutes (a command may be hanging, e.g. waiting on a server). " +
      "Stop anything hanging, then finish your $($st.Role) work, do the end-of-session steps (clean up, STATE, HANDOFF, LOG, commit) " +
      "and create .ai/relay/stage-$i.done as your last action.")
  }
  return 'ok'
}

# A notification for the user (D-030): appended to usage/notify.jsonl; the Herdr panel shows each new line as a toast
# (click = the stage's tab), whichever project you are looking at.
function Notify-User([string]$title, [string]$body, [string]$level = 'warning', [string]$terminal = '') {
  try {
    $n = [ordered]@{ id = [guid]::NewGuid().ToString('N').Substring(0, 12); at = (Get-Date).ToString('o'); project = (Split-Path $Folder -Leaf)
                     title = $title; body = $body; level = $level; terminal = $terminal }
    $p = Join-Path $script:usageDir 'notify.jsonl'
    [IO.File]::AppendAllText($p, (($n | ConvertTo-Json -Compress) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    # Keep the file small: the last 200 lines.
    $all = [IO.File]::ReadAllLines($p)
    if ($all.Count -gt 400) { [IO.File]::WriteAllLines($p, [string[]]($all | Select-Object -Last 200)) }
  } catch {}
}
# Everything needed to start one agent for one role: argv (+ Herdr --task args), and what to show as model/effort.
function New-AgentLaunch([string]$agent, [string]$role, [string]$modelName, [string]$lvl, [string]$msg) {
  $argv = [object[]]$script:agents[$agent]
  $modelArgs = @(Model-Args $agent $modelName)
  $argv = $argv + $modelArgs
  # The executor's mistakes cost whole fix rounds: it always thinks at high or above (user's rule, D-008).
  if ($role -eq 'executor' -and $lvl -notin @('xhigh', 'max')) { $lvl = 'high' }
  # Antigravity's non-Gemini models reject --effort and silently fall back to Gemini, so none for them.
  if ($agent -eq 'antigravity') {
    $short = if ($modelArgs.Count) { Model-Short 'antigravity' ([string]$modelArgs[-1]) } else { Model-Short 'antigravity' $script:agyDefaultRaw }
    if ($short -and $short -notin @('hydrogen', 'flash')) { $lvl = '' }
  }
  if ($agent -eq 'opencode') {
    # OpenCode's interactive mode has no effort flag: the picker gives the executor a strong model instead (D-028).
    # Its first message goes in argv (--prompt); like agy's -i, it must not contain double quotes (Herdr's shell hop).
    # The relay knows the exact model (also after a switch or takeover), so it hands OpenCode its exact signature:
    # the LOG line, the commit and the done file then always name the model that did the work (D-032).
    if ($modelArgs.Count) {
      $sigText = 'opencode-cli/' + (([string]$modelArgs[-1]) -replace '^openrouter/', '')
      $msg = "Your protocol signature for this stage is exactly $sigText (it names the OpenRouter model you run on): use it in the LOG line, the commit message and the done file. " + $msg
    }
    return @{ argv = ($argv + @('--prompt', $msg.Replace('"', "'"))); taskArgs = @(); session = ''
              model = $(if ($modelArgs.Count) { ([string]$modelArgs[-1]) -replace '^openrouter/', '' } else { 'default' }); effort = 'default' }
  }
  if ($lvl -and $lvl -ne 'default') {
    if ($agent -eq 'codex') { $argv = $argv + @('-c', "model_reasoning_effort=$lvl") }
    else { $argv = $argv + @('--effort', $lvl) }   # claude and agy take the same flag
  }
  $session = ''
  if ($agent -eq 'claude') {
    # Our own session id + a status line that saves Claude's usage numbers for the panel.
    $session = [guid]::NewGuid().ToString()
    $argv = $argv + @('--session-id', $session, '--settings', $script:claudeSettings)
  }
  $taskArgs = @('--task', $msg)
  # Claude and Codex take Herdr's first message (--task). Antigravity CLI only accepts an interactive first prompt
  # through -i, so it goes in argv. Herdr starts argv through the tab's shell, and Windows PowerShell drops double
  # quotes inside arguments on that hop, so the -i message must not contain double quotes.
  if ($agent -eq 'antigravity') { $argv = $argv + @('-i', $msg.Replace('"', "'")); $taskArgs = @() }
  return @{ argv = $argv; taskArgs = $taskArgs; session = $session
            model = $(if ($modelArgs.Count) { [string]$modelArgs[-1] } else { 'default' })
            effort = $(if ($lvl -and $lvl -ne 'default') { $lvl } else { 'default' }) }
}
# Every minute while a stage runs: did its agent run out of plan quota? Waits, switches Antigravity's model in the
# session, or hands the stage to another agent (D-027). Returns the new terminal after a takeover, else $null.
# Counted as a quota only when the agent stopped working and its last screen says so (an agent writing about
# "rate limits" in its own code must not trigger it); Antigravity numbers each message (Error ID), so a message
# that was already handled and is still on screen doesn't count twice.
function Check-StageQuota([string]$terminal, [string]$kind, $entry, $st, [int]$i, [string]$msg, [bool]$here) {
  $w = $script:watch
  if (((Get-Date) - $w.qchecked).TotalSeconds -lt 60 -or -not $terminal) { return $null }
  $w.qchecked = Get-Date
  $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
  # A watcher must never stop the relay: a slow or failed screen read (2026-11-25: hc read of a busy OpenCode tab
  # took over 30 s) just skips this minute's check.
  try { $screen = (Invoke-Native $hcExe @('read', $terminal, '--lines', '40') 90).Out }
  catch { Write-Host "  (couldn't read the stage's screen this minute: $($_.Exception.Message))" -ForegroundColor DarkGray; return $null }
  $flat = ($screen -replace '\s+', ' ').Trim()
  $tail = if ($flat.Length -gt 700) { $flat.Substring($flat.Length - 700) } else { $flat }
  $state = ''
  try { $state = [string]((Invoke-Native $hcExe @('get', $terminal, '--json') 30).Out | ConvertFrom-Json).status.state } catch {}
  # Seen 2026-11-25: Antigravity "Individual quota reached ... Resets in 2h45m" and "Your AI credits balance is too low".
  $rx = '(?i)usage limit|limit reached|quota (reached|exceeded|exhausted)|out of (credits|usage|quota)|reached your .{0,30}limit|hit your .{0,30}limit|' +
        '(credits?|credit balance|balance) (is )?too low|not enough (credits|quota)|insufficient (credits|quota|balance)'
  $ids = @([regex]::Matches($tail, 'Error ID:\s*([0-9A-Za-z\-]+)') | ForEach-Object { $_.Groups[1].Value })
  $fresh = @($ids | Where-Object { -not $w.seen.ContainsKey($_) })
  foreach ($x in $ids) { $w.seen[$x] = $true }
  # OpenRouter's errors as OpenCode shows them. Herdr reports no state for OpenCode, so for it "stopped" means the
  # screen did not change since the last check a minute ago.
  if ($kind -eq 'opencode') {
    $rx += '|rate limit exceeded|free-models-per-day|requires more credits|insufficient credits|payment required|key limit exceeded'
    if ($flat -ne $w.qlast) { $state = 'working' }
  }
  $w.qlast = $flat
  $isLimit = ($tail -match $rx) -and $state -ne 'working'
  if ($isLimit -and $ids.Count -and -not $fresh.Count -and -not $w.limit) { $isLimit = $false }   # old, handled message
  if (-not $isLimit) {
    if ($w.limit) { $w.limit = $false; Write-Host '  plan limit over; the agent is working again.' -ForegroundColor Magenta }
    $w.limitSince = $null
    return $null
  }
  $capped = $false
  if ($w.limit) {
    # Already waiting it out. No wait lasts longer than maxWaitMinutes (D-029): then switch like a far-off reset.
    if (-not $here -and $script:fbOn -and $w.limitSince -and ((Get-Date) - $w.limitSince).TotalMinutes -ge $script:fbMaxWait) {
      Write-Host "  waited $($script:fbMaxWait) min for the quota: switching instead." -ForegroundColor Magenta
      $w.limit = $false; $capped = $true
    } else {
      # Nudge every 30 min (the limit may have reset without the agent noticing).
      if (((Get-Date) - $w.limitNudge).TotalMinutes -ge 30) {
        $w.limitNudge = Get-Date; $w.changed = Get-Date
        Send-Agent $terminal "Your usage limit should have reset by now. Please carry on with your $($st.Role) work, then finish the end-of-session steps and create .ai/relay/stage-$i.done."
      }
      return $null
    }
  }
  $mins = Reset-Minutes $kind $screen
  $until = if ($mins -ge 0) { (Get-Date).AddMinutes($mins) } else { (Get-Date).AddMinutes(60) }   # unknown: assume an hour
  $cur = ''
  if ($kind -eq 'antigravity') {
    $f = [regex]::Matches($screen, '(?m)(?:auto|accept-edits|plan|default)\s+\S{1,2}\s+([^\r\n]+?)\s*(?:\S{1,2}\s+(?:low|medium|high|xhigh|max))?\s*$') | Select-Object -Last 1
    $cur = if ($f) { Model-Short 'antigravity' $f.Groups[1].Value } else { '' }
    if (-not $cur) { $cur = Model-Short 'antigravity' $(if ($entry.model -ne 'default') { $entry.model } else { $script:agyDefaultRaw }) }
  }
  if ($kind -eq 'opencode') { $cur = [string]$entry.model }
  Set-Quota (Quota-Key $kind $cur) $until
  $resetText = if ($mins -ge 0) { "back at $($until.ToString('HH:mm'))" } else { 'reset time unknown' }
  Write-Host "  $kind ran out of plan quota$(if ($cur) { " on $cur" }) ($resetText)." -ForegroundColor Magenta
  $wait = (-not $script:fbOn) -or $here -or ($mins -ge 0 -and $mins -le $script:fbWait -and -not $capped)
  if (-not $wait -and $kind -eq 'antigravity') {
    $alt = Pick-AgyModel $st.Role
    if ($alt -and $alt -ne $cur) {
      if (Switch-AgyModel $terminal $alt) {
        $note = "$(Get-Date -Format HH:mm) Antigravity $(if ($cur) { $cur } else { 'model' }) out of quota ($resetText): switched this session to $alt"
        $entry.model = $script:modelNames['antigravity'][$alt]
        if ($alt -notin @('hydrogen', 'flash')) { $entry.effort = 'default' }
        $entry.switches += $note
        Notify-User "$(Split-Path $Folder -Leaf): Antigravity switched model" "Stage $i ($($st.Role)): $(if ($cur) { $cur } else { 'model' }) out of quota ($resetText), now on $alt." 'info' $terminal
        Write-Host "  switched this Antigravity session to $alt; telling it to carry on." -ForegroundColor Magenta
        Start-Sleep -Seconds 2
        Send-Agent $terminal ("Your previous model ran out of quota, so this session now runs on $alt. Carry on with your $($st.Role) work " +
          "exactly where you stopped, then finish every end-of-session step and, as your very last action, create .ai/relay/stage-$i.done whose first line is your signature.")
        $w.changed = Get-Date
        return $null
      }
      Write-Host "  couldn't switch the model inside the Antigravity session." -ForegroundColor DarkYellow
    }
  }
  $p = $null
  if (-not $wait -and $kind -eq 'opencode') {
    # Next OpenRouter model for this role (OpenCode can't switch inside a session from here): a fresh OpenCode tab.
    $alt = Pick-OpenCodeModel $st.Role @($cur)
    if ($alt) { $p = @{ agent = 'opencode'; model = $alt } }
  }
  if (-not $wait -and -not $p) { $p = Pick-Agent $st.Role $kind }
  if (-not $p) {
    $w.limit = $true; $w.limitNudge = Get-Date
    if (-not $w.limitSince) { $w.limitSince = Get-Date }   # the 30-minute cap counts from the first wait
    $why = if ($here) { 'your own session' } elseif (-not $script:fbOn) { 'fallback is off' } elseif ($mins -ge 0 -and $mins -le $script:fbWait) { "it resets within $($script:fbWait) min" } else { 'no other agent has quota left' }
    Write-Host "  waiting for the quota to come back ($why)." -ForegroundColor Magenta
    if ($why -eq 'no other agent has quota left') {
      Notify-User "$(Split-Path $Folder -Leaf): relay is waiting for quota" "Stage $i ($($st.Role)): $kind is out ($resetText) and no other agent or free model can take over." 'error' $terminal
    }
    return $null
  }
  # Hand the stage to another agent: same stage, same done file; the new agent continues from the repo's state.
  Stop-Agent $terminal
  $take = "The $kind agent stopped in the middle of this stage because its plan quota ran out ($resetText). You take over its stage. " +
          "First look at git status, git diff and the newest .ai/HANDOFF.md and task-file notes to see what it already did; keep its good work and finish the rest. "
  $lvl = if ($entry.effort -in @('low', 'medium', 'high', 'xhigh', 'max')) { $entry.effort } else { [string]$script:effortByRole[$st.Role] }
  $L = New-AgentLaunch $p.agent $st.Role $p.model $lvl ($take + $msg)
  $argvJson = ConvertTo-Json -InputObject ([object[]]$L.argv) -Compress
  $tab = New-RelayStageTab $script:spaceId "$i $($st.Role) - $($p.agent) (takeover)" (@('--folder', $Folder, '--argv', $argvJson) + $L.taskArgs)
  $note = "$(Get-Date -Format HH:mm) $kind out of quota ($resetText): $($p.agent) took over" +
          $(if ($p.lastResort) { " on the free model $($p.model) (every plan and the paid budget were out)" } else { '' })
  $entry.agent = $p.agent; $entry.model = $L.model; $entry.effort = $L.effort; $entry.session = $L.session
  $entry.terminal = [string]$tab.terminal; $entry.switches += $note
  Write-Host "  $($p.agent) takes over stage $i in terminal $($tab.terminal) (tab '$i $($st.Role) - $($p.agent) (takeover)')." -ForegroundColor Magenta
  Notify-User "$(Split-Path $Folder -Leaf): $($p.agent) took over stage $i" "$kind ran out of quota ($resetText) during the $($st.Role) stage." `
    $(if ($p.lastResort) { 'error' } else { 'warning' }) ([string]$tab.terminal)
  $w.limit = $false; $w.limitSince = $null; $w.changed = Get-Date
  return [string]$tab.terminal
}

function Run-Stage($st, [string]$label, [string]$next, [string]$context) {
  Check-Controls
  if ($script:pendingBranch) {
    # Switched to overnight during the run: the night's work starts on its own branch from this stage on.
    $script:pendingBranch = $false
    $gs = Invoke-Native (Get-Command git | Select-Object -First 1).Source @('-C', $Folder, 'switch', '-c', $script:nightBranch) 60
    if ($gs.Code -eq 0) { Write-Host "  overnight: now on branch $($script:nightBranch)." -ForegroundColor Yellow }
    else { Write-Host "  overnight: couldn't create $($script:nightBranch) ($($gs.Err.Trim())); staying on the current branch." -ForegroundColor Yellow; $script:nightBranch = '' }
  }
  $script:n++
  $i = $script:n
  $marker = Join-Path $relayDir ("stage-{0}.done" -f $i)
  $rules = if ($NoRulesCheck) { '' } else { 'Start your reply with one line naming the global rules you follow and your signature. ' }
  $verdictAsk = if ($st.Role -eq $script:judgeRole) { ' The second line of that file must be exactly APPROVED or CHANGES_REQUESTED.' } else { '' }
  $job = if ($script:jobOf[$st.Role]) { "Your job as the $($st.Role): $($script:jobOf[$st.Role].TrimEnd('.')). " } else { '' }
  $msg = "${rules}You are the $($st.Role) in an automatic agent relay ($label, team $Team). $job$context" +
         "Project goal: $goalText. Follow the Shared Project Protocol: read .ai/ first (bootstrap it if missing), " +
         "do only the $($st.Role) part, then finish every end-of-session step (stop every server, watcher and test run you started and free their ports, STATE, HANDOFF for the $next, one LOG line, commit). " +
         "As your very last action, after the commit, create the file .ai/relay/stage-$i.done whose first line is your signature.$verdictAsk Then stop."

  # Claude and Codex take Herdr's first message (--task). Antigravity CLI only accepts an
  # interactive first prompt through its -i / --prompt-interactive flag, so it goes in argv.
  $here = $st.Agent -eq 'here'
  $kind = if ($here) { $HereAgent } else { $st.Agent }   # claude | codex | antigravity
  $entry = [ordered]@{ n = $i; role = $st.Role; agent = $kind; here = $here; label = $label; round = $script:round; task = $script:currentTask
                       model = ''; effort = ''; state = 'running'; started = (Get-Date).ToString('o'); finished = ''
                       minutes = 0; terminal = ''; by = ''; verdict = ''; session = ''; usage = $null; cleaned = @(); switches = @()
                       planBefore = $null; planAfter = $null; logLines = 0; sigOk = $false; commits = 0; trial = $false }
  # Quality record (D-030): the commit before the stage, to count the agent's own commits after it.
  $headBefore = ''
  try { $hb = Invoke-Native (Get-Command git | Select-Object -First 1).Source @('-C', $Folder, 'rev-parse', 'HEAD') 30; if ($hb.Code -eq 0) { $headBefore = $hb.Out.Trim() } } catch {}
  [void]$script:history.Add($entry)
  if ($here) {
    # This stage runs in the agent session that started the relay: send it the task, no new tab.
    $hcExe = Find-Exe 'hc' @("$env:LOCALAPPDATA\Programs\herdr-core")
    Write-Host "`n[$i] $($st.Role) -> your $HereAgent session ($HereTerminal)   ($label)" -ForegroundColor Yellow
    # hc refuses to type while the session shows a dialog (a permission prompt, a notice): wait until it's answered.
    # Type only when Herdr sees the agent at its normal prompt (idle, done or working: a working agent queues it).
    # Any other screen (a trust dialog, Codex's task list, ...) would take the text as keystrokes, so wait.
    # (2026-11-22: Codex's trust screen showed no status; the typed task landed in its task list.)
    $askedAt = $null
    while ($true) {
      $g = Invoke-Native $hcExe @('get', $HereTerminal, '--json') 30
      if ($g.Code -ne 0) { throw "Your $HereAgent session $HereTerminal is gone ($($g.Out + $g.Err)). Start it again or stop the relay." }
      $stt = ''
      try { $stt = [string](($g.Out | ConvertFrom-Json).status.state) } catch {}
      if ($stt -in @('idle', 'done', 'working')) {
        $r = Invoke-Native $hcExe @('send', $HereTerminal, $msg) 600
        if ($r.Code -eq 0) { break }
        if (($r.Out + $r.Err) -notmatch '"kind"\s*:\s*"blocked"') {
          throw "Couldn't send the $($st.Role) task to $HereTerminal ($($r.Out + $r.Err)). Is that session still open?"
        }
      }
      if (-not $askedAt) {
        $askedAt = Get-Date
        Write-Host "  your $HereAgent session ($HereTerminal) has a question open; answer it there and the task follows." -ForegroundColor Magenta
      }
      Write-Status 'waiting' $st $label $HereTerminal "Your $HereAgent session ($HereTerminal) has a question open. Answer it there; then the relay hands it the $($st.Role) task."
      if (Test-Path $stopFile) { Check-Controls }
      Start-Sleep -Seconds 10
    }
    # Codex takes a fast paste's Enter as a newline, so the task sits in its input box unsent (seen 2026-11-22).
    # A separate Enter a moment later submits it; on an already-sent (empty) input it does nothing.
    Start-Sleep -Milliseconds 1500
    [void](Invoke-Native $hcExe @('keys', $HereTerminal, 'enter') 30)
    $tab = [pscustomobject]@{ terminal = $HereTerminal }
    $entry.terminal = $HereTerminal; $entry.model = 'its own'; $entry.effort = 'its own'
  } else {
  # Which agent, model and effort, given what is out of plan quota right now (D-027).
  $plan = Plan-Stage $st ([string]$script:modelByRole[$st.Role]) ([string]$script:effortByRole[$st.Role])
  $kind = $plan.agent
  $entry.agent = $plan.agent
  # 5-hour plan use before the stage (Claude/Codex): with the value after it, the prediction learns (D-029).
  $pb = if ($kind -in @('claude', 'codex')) { Plan-5h $kind } else { $null }
  $entry.planBefore = $(if ($pb) { $pb.used } else { $null })
  $L = New-AgentLaunch $plan.agent $st.Role $plan.model $plan.effort $msg
  $argv = $L.argv; $taskArgs = $L.taskArgs
  $entry.session = $L.session; $entry.model = $L.model; $entry.effort = $L.effort
  foreach ($nt in $plan.notes) { $entry.switches += "$(Get-Date -Format HH:mm) $nt" }
  $entry.trial = [bool]$plan.trial
  $argvJson = ConvertTo-Json -InputObject ([object[]]$argv) -Compress
  $tabName = "$i $($st.Role) - $($plan.agent)"
  $effortNote = $(if ($L.model -ne 'default') { ", model $($L.model)" } else { '' }) +
                $(if ($L.effort -ne 'default') { ", effort $($L.effort)" } else { '' })
  Write-Host "`n[$i] $($st.Role) -> $($plan.agent)$effortNote   ($label, tab '$tabName')" -ForegroundColor Yellow
  foreach ($nt in $plan.info) { Write-Host "  $nt." -ForegroundColor DarkCyan }
  foreach ($nt in $plan.notes) { Write-Host "  fallback: $nt." -ForegroundColor Magenta }
  if ($plan.notes.Count) {
    Notify-User "$name`: stage $i ($($st.Role)) uses $($plan.agent)" ($plan.notes -join '; ') $(if (($plan.notes -join ' ') -match 'last resort') { 'error' } else { 'info' })
  }
  $tabArgs = @('--folder', $Folder, '--argv', $argvJson) + $taskArgs
  try { $tab = New-RelayStageTab $script:spaceId $tabName $tabArgs }
  catch {
    # An unacknowledged command may have created a tab. Never repeat it in a different space.
    if ($_.Exception.Message -match '(?i)did not acknowledge') { throw }
    # Only if the space is really gone (closed while the relay ran): open a fresh one and retry once.
    # Any other error is real, so stop with it instead of piling up duplicate spaces.
    if (Space-Exists $script:spaceId) { throw }
    Write-Host "  Herdr space $($script:spaceId) is gone - opening a new space for '$name'." -ForegroundColor DarkGray
    $space = Herdr @('do', 'space.new', '--name', $name, '--folder', $Folder)
    $script:spaceId = [string]$space.space
    $tab = New-RelayStageTab $script:spaceId $tabName $tabArgs
  }
  # The full task goes to a file instead of the screen (D-030: a readable relay tab).
  $taskFile = Join-Path $relayDir "stage-$i.task.txt"
  try { [IO.File]::WriteAllText($taskFile, $msg, (New-Object System.Text.UTF8Encoding($false))) } catch {}
  Write-Host "  terminal $($tab.terminal) - task in .ai\relay\stage-$i.task.txt (paste it into the tab if a first-run question swallowed it)" -ForegroundColor DarkGray
  $entry.terminal = [string]$tab.terminal
  }

  $start = Get-Date; $stopNoted = $false
  $script:stageStart = $start
  Write-Status 'running' $st $label ([string]$tab.terminal)
  $logBefore = Count-Lines (Join-Path $Folder '.ai\LOG.md')
  Reset-Watch
  while (-not (Test-Path $marker)) {
    Start-Sleep -Seconds 10
    Write-Status 'running' $st $label ([string]$tab.terminal)   # heartbeat: 'updated' older than ~1 min = relay not running
    # Plan quota ran out? Wait, switch model, or hand the stage to another agent (every mode, not only overnight).
    $newTerm = $null
    try { $newTerm = Check-StageQuota ([string]$tab.terminal) $kind $entry $st $i $msg $here }
    catch { Write-Host "  quota check failed this minute ($($_.Exception.Message)); the stage goes on." -ForegroundColor DarkGray }
    if ($newTerm) { $tab = [pscustomobject]@{ terminal = $newTerm }; $kind = $entry.agent; Write-Status 'running' $st $label $newTerm }
    if ((Test-Path $stopFile) -and -not $stopNoted) { Write-Host '  STOP requested - will stop when this stage finishes.' -ForegroundColor Red; $stopNoted = $true }
    if (Test-Path $overnightFile) { $was = [bool]$Overnight; Convert-ToOvernight; if (-not $was) { Reset-Watch; $start = Get-Date } }
    if ($Overnight) {
      # Nobody to ask: the watchdog nudges a stuck agent, waits out plan limits, and gives up on a stage it can't save.
      if ((Watch-Stage ([string]$tab.terminal) $kind $i $st $label) -eq 'skip') { break }
      if (((Get-Date) - $start).TotalMinutes -ge $TimeoutMin -and -not $script:watch.limit) {
        Write-Host "  stage $i ran $TimeoutMin min: interrupting it and moving on (overnight)." -ForegroundColor DarkYellow
        Stop-Agent ([string]$tab.terminal); break
      }
      continue
    }
    if (((Get-Date) - $start).TotalMinutes -ge $TimeoutMin) {
      $qText = "Stage $i has run $TimeoutMin min without finishing. [w]ait more / [n]ext stage / [q]uit"
      Write-Status 'waiting' $st $label ([string]$tab.terminal) $qText   # the panel shows the question, not 'Not responding'
      $ans = Read-Choice "  $qText" 'w'   # switched to overnight while asking: keep waiting, the watchdog takes over
      if ($ans -eq 'q') { Write-Status 'stopped'; Write-Host 'Stopped. Agents keep running in their tabs.'; Show-Summary; exit 1 }
      if ($ans -eq 'n') { break }
      $start = Get-Date
    }
  }
  # @() outside the if: an if-expression unrolls a one-line file to a plain string, and [0] was then its first letter
  # ("done by c" instead of the signature).
  $lines = @(if (Test-Path $marker) { Get-Content $marker } else { '(skipped)' })
  $who = ([string]$lines[0]).Trim()
  $extra = ''
  if ($st.Role -eq $script:judgeRole) {
    $all = $lines -join ' '
    $script:verdict = if (($all -match 'APPROVED') -and ($all -notmatch 'CHANGES_REQUESTED')) { 'APPROVED' } else { 'CHANGES_REQUESTED' }
    $extra = "  |  verdict: $($script:verdict)"
  }
  $added = (Count-Lines (Join-Path $Folder '.ai\LOG.md')) - $logBefore
  # Did the agent follow the protocol? A LOG line, a signature like "codex-cli/gpt-6", its own commit(s).
  $entry.logLines = [int][math]::Max(0, $added)
  $entry.sigOk = ($who -match '^[a-z]+(-[a-z]+)?/[\w.:\-]+')
  if ($headBefore) {
    try {
      $rc = Invoke-Native (Get-Command git | Select-Object -First 1).Source @('-C', $Folder, 'rev-list', '--count', "$headBefore..HEAD") 30
      if ($rc.Code -eq 0) { $entry.commits = [int]$rc.Out.Trim() }
    } catch {}
  }
  $entry.state = $(if (Test-Path $marker) { 'done' } else { 'skipped' })
  # A finished stage without a LOG line (OpenCode models skip it most): the relay writes one for it and commits only
  # LOG.md, so the shared record stays complete. Stats keep logLines = 0 (logFilled marks it): compliance stays honest.
  if ($entry.state -eq 'done' -and $entry.logLines -le 0) {
    try {
      $logPath = Join-Path $Folder '.ai\LOG.md'
      $sig = $(if ($entry.sigOk) { ($who -split '\s')[0] } else { "$kind" })
      $tid = $(if ($script:currentTask) { $script:currentTask } else { '-' })
      $line = "{0} | {1} | {2} | {3} | stage {4} done; LOG line added by relay (agent skipped it)" -f (Get-Date).ToString('yyyy-MM-dd HH:mm'), $sig, $st.Role, $tid, $i
      $txt = ''; if (Test-Path $logPath) { $txt = [IO.File]::ReadAllText($logPath) }
      if ($txt -and -not $txt.EndsWith("`n")) { $line = "`n" + $line }
      [IO.File]::AppendAllText($logPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
      $entry.logFilled = $true
      $gitExe = (Get-Command git | Select-Object -First 1).Source
      $null = Invoke-Native $gitExe @('-C', $Folder, 'add', '--', '.ai/LOG.md') 30
      $null = Invoke-Native $gitExe @('-C', $Folder, 'commit', '--author=ai-relay <ai@localhost>', '-m', "[ai-relay] ${tid}: LOG line for stage $i ($sig)", '--', '.ai/LOG.md') 30
      Write-Host "  no LOG line from the agent: the relay added one." -ForegroundColor DarkYellow
    } catch { Write-Host "  could not add the missing LOG line ($($_.Exception.Message))." -ForegroundColor DarkGray }
  }
  # A finished stage must not leave servers or test runs behind for the next one (a skipped stage may still be working).
  # ForEach-Object unrolls the list the function returns (else 'cleaned' becomes [[...]] and looks non-empty).
  if ($entry.state -eq 'done') { $entry.cleaned = @(Stop-StageLeftovers ([string]$tab.terminal) $script:stageStart | ForEach-Object { $_ }) }
  $entry.finished = (Get-Date).ToString('o')
  $entry.minutes = [math]::Round(((Get-Date) - $script:stageStart).TotalMinutes, 1)
  $entry.by = $who
  if ($st.Role -eq $script:judgeRole) { $entry.verdict = $script:verdict }
  $entry.usage = Stage-Usage $entry
  if ($null -ne $entry.planBefore -and $entry.agent -in @('claude', 'codex')) {
    $script:usage = Get-PlanUsage; $script:usageAt = Get-Date
    $pa = Plan-5h $entry.agent
    # A window that reset during the stage gives a lower value: no usable measure then.
    $entry.planAfter = $(if ($pa -and $pa.used -ge $entry.planBefore) { $pa.used } else { $null })
  }
  Write-StageStats $entry   # the model report's raw data (D-028)
  $script:usageAt = [datetime]::MinValue   # refresh plan usage now
  Write-Status 'running' $st $label ([string]$tab.terminal)
  Write-Host ("  done by {0}  |  {1} new LOG line(s)  |  {2:N0} min{3}" -f $who, $added, ((Get-Date) - $start).TotalMinutes, $extra) -ForegroundColor Green
}

function Run-Pass($stages, [string]$label, [string]$context) {
  for ($k = 0; $k -lt $stages.Count; $k++) {
    $next = if ($k + 1 -lt $stages.Count) { $stages[$k + 1].Role } else { 'next agent or the user' }
    Run-Stage $stages[$k] $label $next $context
  }
}

# ---------- run ----------
# Any error that ends the relay is shown as "Stopped: <why>" in the panel, never left looking like a running relay
# that went quiet ("Not responding"). (A trap covers the whole script scope.)
trap {
  $script:fatal = $_.Exception.Message
  Write-Host "`nRelay stopped by an error: $($script:fatal)" -ForegroundColor Red
  if (Get-Command Write-Status -ErrorAction SilentlyContinue) { Write-Status 'stopped' }
  if (Get-Command Write-NightReport -ErrorAction SilentlyContinue) { Write-NightReport 'stopped by an error' }
  break
}
Write-Host "`nRelay for '$name'" -ForegroundColor Cyan
# The weekly model report's suggestions (tools/model-report.ps1, D-028): one line, so they don't go unseen.
try {
  $mr = Read-Json (Join-Path $script:usageDir 'model-report.json')
  $real = @($mr.suggestions | Where-Object { $_ -notlike 'No relay stages recorded*' })
  if ($real.Count) { Write-Host "  model report ($(([datetime]$mr.at).ToString('dd MMM'))): $($real.Count) suggestion(s) in $(Join-Path $script:usageDir 'model-report.html')" -ForegroundColor DarkCyan }
} catch {}
if ($first.Count -gt 0) { Write-Host ("  first pass : " + (($first | ForEach-Object { "$($_.Role)=$($_.Agent)" }) -join ' -> ')) }
Write-Host ("  fix loop   : " + (($loopStages | ForEach-Object { "$($_.Role)=$($_.Agent)" }) -join ' -> ') + "   (max $MaxRounds rounds)")
Write-Host "  stop  : create $stopFile" -ForegroundColor DarkGray
Write-Host "  pause : create $pauseFile (delete it to continue)" -ForegroundColor DarkGray
# The project's Herdr space: the one you started the relay from if it holds only this project, else another space
# of this project's, else a new one (D-025). Stage tabs open there, never in another project's space.
$hereSpace = Get-TerminalSpace $env:HC_TERMINAL_ID
$script:spaceId = Get-ProjectSpace $Folder $name $hereSpace
if ($hereSpace -and $hereSpace -ne $script:spaceId) {
  Write-Host "  note: this tab isn't in $name's space; the stage tabs open in $name's own space." -ForegroundColor DarkYellow
}
$script:n = 0
$script:relayStart = Get-Date
$script:verdict = $null
$script:round = 0
$script:stageStart = $null

# One job: a first pass, then fix rounds while the judge asks for changes. Rounds used -> $script:jobRounds.
function Run-Job($firstStages, $loop, [string]$prefix, [string]$context) {
  $script:jobRounds = 0
  $script:verdict = $null
  if (@($firstStages).Count -gt 0) { Run-Pass $firstStages "${prefix}first pass" $context }
  $round = 0; $script:round = 0
  while ($MaxRounds -gt 0 -and $script:verdict -ne 'APPROVED' -and $round -lt $MaxRounds) {
    $round++; $script:round = $round; $script:jobRounds = $round
    if ($AskEachRound) {
      Write-Status 'waiting' $null '' '' "${prefix}Start fix round $round of $($MaxRounds)? Answer y or n in the AI Relay tab."
      $ans = Read-Choice "`n${prefix}Start fix round $round of $($MaxRounds)? [y]es / [n]o" 'y'   # $($...): '$MaxRounds?' would read a variable named 'MaxRounds?'
      if ($ans -ne 'y') { break }
    }
    Write-Host "`n=== ${prefix}Fix round $round of $MaxRounds ===" -ForegroundColor Cyan
    Run-Pass $loop "${prefix}fix round $round of $MaxRounds" ($context + "Work from the latest HANDOFF and the $($script:judgeRole)'s findings (in the task file, if there is one). ")
  }
}

# ---------- queue mode: plan into tasks, then one mini-relay per task with its own agents ----------
$builtinStrengths = [ordered]@{
  claude      = 'planning, architecture, code review, tricky logic, writing'
  codex       = 'static assets (images, icons, illustrations via image generation), scripts, tests'
  antigravity = 'app code, UI and full features, refactors'
}
function Strengths-Text {
  $s = Default-Of 'strengths' $null
  $map = [ordered]@{}
  foreach ($k in $builtinStrengths.Keys) { $map[$k] = $builtinStrengths[$k] }
  if ($s) { foreach ($p in $s.PSObject.Properties) { $map[$p.Name.ToLower()] = [string]$p.Value } }
  return (($map.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join '; ')
}
# A task file's title and its "Relay: role=agent, ..." line (agents for this task; missing roles keep the team's).
function Read-QueueTask([string]$id) {
  $dir = Join-Path $Folder '.ai\tasks'
  $file = Get-ChildItem $dir -Filter "$id*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
  if (-not $file) { throw "Queue: no task file for '$id' in .ai/tasks." }
  $lines = @(Get-Content $file.FullName -Encoding UTF8)   # 5.1 would read BOM-less UTF-8 as ANSI (garbled dashes)
  $title = ($lines | Where-Object { $_ -match '^\s*#' } | Select-Object -First 1) -replace '^\s*#+\s*', ''
  # "T-010 Static assets - status: planned" -> "Static assets"
  $title = (($title -replace '\s*[^\w\s]+\s*status\s*:.*$', '') -replace "^$([regex]::Escape($id))\b\W*", '').Trim()
  $agents = [ordered]@{}
  $rl = $lines | Where-Object { $_ -match '^\W*Relay\W*:' } | Select-Object -First 1
  if ($rl) {
    foreach ($m in [regex]::Matches(($rl -replace '^\W*Relay\W*:', ''), '([A-Za-z][A-Za-z0-9-]*)\s*=\s*([A-Za-z]+)')) {
      $role = $m.Groups[1].Value.ToLower(); $ag = $m.Groups[2].Value.ToLower()
      if ($ag -eq 'agy') { $ag = 'antigravity' }
      if ($ag -eq 'here' -and -not $HereTerminal) { throw "Task $id gives $role to 'here', but no -HereTerminal was passed." }
      if ($ag -ne 'here' -and -not $script:agents.ContainsKey($ag)) { throw "Task ${id}: unknown agent '$ag' for $role (claude, codex, antigravity, opencode)." }
      $agents[$role] = $ag
    }
  }
  $stages = @($loopStages | ForEach-Object { [pscustomobject]@{ Role = $_.Role; Agent = $(if ($agents.Contains($_.Role)) { $agents[$_.Role] } else { $_.Agent }) } })
  foreach ($st in $stages) { if ($st.Agent -ne 'here') { [void](Model-Args $st.Agent $script:modelByRole[$st.Role]) } }
  return [ordered]@{ id = $id; title = $(if ($title) { $title } else { $id }); file = $file.Name
                     agents = (($stages | ForEach-Object { "$($_.Role)=$($_.Agent)" }) -join ', '); stages = $stages
                     state = 'pending'; verdict = ''; rounds = 0 }
}
function Load-Queue([string[]]$ids) {
  $script:queueList.Clear()
  foreach ($id in $ids) { $t = Read-QueueTask $id; [void]$script:queueList.Add($t) }
}
function Show-Queue {
  Write-Host "`nQueue ($($script:queueList.Count) tasks, one at a time):" -ForegroundColor Cyan
  $k = 0
  foreach ($t in $script:queueList) { $k++; Write-Host ("  {0}. {1}  {2}`n       {3}" -f $k, $t.id, $t.title, $t.agents) }
}
function Test-QueueApproval($task) {
  $taskPath = Join-Path (Join-Path $Folder '.ai\tasks') $task.file
  $record = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if ($record -notmatch '(?im)^#\s+[^\r\n]*\bstatus:\s*done\s*$') { return $false }
  $reviews = [regex]::Matches($record, '(?im)^#{3,6}\s+Review[^\r\n]*\|\s*(APPROVED|CHANGES_REQUESTED)\s*\r?$')
  return $reviews.Count -gt 0 -and $reviews[$reviews.Count - 1].Groups[1].Value -eq 'APPROVED'
}

function Wait-QueueApproval($task) {
  # Keep the heartbeat alive and leave later tasks pending until there is a recorded approval.
  $why = "$($task.id) needs reviewer approval. Record approval in its task file, then Resume. Stop ends this run."
  New-Item -ItemType File -Path $pauseFile -Force | Out-Null
  Write-Host "  PAUSED: $why" -ForegroundColor Magenta
  Write-Status 'paused' $null '' '' $why
  Write-NightReport "paused awaiting $($task.id) approval" -IncludeCurrentQueue
  while ($true) {
    if (Test-Path -LiteralPath $stopFile) { Check-Controls }
    if ($Overnight -and (Get-Date) -ge $script:untilAt) { return $false }
    if (-not (Test-Path -LiteralPath $pauseFile)) {
      if (Test-QueueApproval $task) {
        $script:verdict = 'APPROVED'
        $task.verdict = 'APPROVED'
        $task.state = 'done'
        return $true
      }
      Write-Host "  Still paused: $why" -ForegroundColor Yellow
      New-Item -ItemType File -Path $pauseFile -Force | Out-Null
    }
    Write-Status 'paused' $null '' '' $why
    Start-Sleep -Seconds 10
  }
}

function Run-Queue {
  $qFile = Join-Path $relayDir 'queue.txt'
  if ($Tasks.Trim()) {
    $ids = @($Tasks -split '[,\s]+' | Where-Object { $_ })
  } else {
    $planners = @($first | Where-Object { $_.Role -in @($script:teamRoles | Where-Object once | ForEach-Object { $_.role }) })
    if (-not $planners) { throw "Queue mode needs a planning role (a 'once' role) in team '$Team', or -Tasks T-xxx,T-yyy." }
    if (Test-Path $qFile) { Remove-Item $qFile -Force }
    $loopRoles = ($loopStages | ForEach-Object { $_.Role }) -join ', '
    $ctx = "QUEUE MODE: this goal is big, so split it into small tasks that one relay each can finish (one deliverable per task, " +
           "e.g. static assets in one task, app code in another). Write each as .ai/tasks/T-xxx.md per the protocol. In each task " +
           "file put one line that starts exactly with 'Relay: ' and names an agent (claude, codex or antigravity) for each of these " +
           "roles: $loopRoles. Example: 'Relay: executor=codex, tester=claude, reviewer=claude'. Choose by these strengths: " +
           "$(Strengths-Text). Then write the task ids in the order to run them, one per line, to .ai/relay/queue.txt " +
           "(that folder is not committed). "
    Run-Pass $planners 'planning the queue' $ctx
    if (-not (Test-Path $qFile)) { throw "The planner didn't write .ai/relay/queue.txt, so there is no queue to run." }
    $ids = @(Get-Content $qFile | ForEach-Object { ($_ -replace '^[\s\-\*\d\.\)]+', '').Trim() } | Where-Object { $_ -match '^[A-Za-z]+-\d+' } |
             ForEach-Object { ($_ -split '\s')[0] })
  }
  if (-not $ids) { throw 'The queue is empty.' }
  # You approve the queue (and may edit the Relay: lines in the task files) before any task starts.
  # Overnight: nobody is there; the queue starts as planned (you approved overnight mode itself).
  while ($true) {
    Load-Queue $ids
    Show-Queue
    if ($Overnight) { Write-Host '  overnight: starting the queue as planned.' -ForegroundColor DarkGray; break }
    Write-Status 'waiting' $null '' '' "Queue ready: $($script:queueList.Count) tasks. Check it in the AI Relay tab: y = start, r = re-read after editing the task files' Relay: lines, q = quit."
    $a = (Read-Choice "`nStart this queue? [y]es / [r]e-read task files / [q]uit" 'y').Trim().ToLower()
    if ($a -eq 'y') { break }
    if ($a -eq 'q') { Write-Status 'stopped'; Write-Host 'Queue not started.'; Show-Summary; exit 0 }
  }
  $k = 0
  foreach ($t in $script:queueList) {
    $k++
    if ($Overnight -and (Get-Date) -ge $script:untilAt) {
      Write-Host "  overnight: it's past $($script:untilAt.ToString('HH:mm')); not starting $($t.id) or later tasks." -ForegroundColor DarkYellow
      foreach ($r in $script:queueList) { if ($r.state -eq 'pending') { $r.state = 'not started (time)' } }; break
    }
    $script:currentTask = $t.id
    $t.state = 'running'
    Write-Host "`n##### Task $k of $($script:queueList.Count): $($t.id) $($t.title)   ($($t.agents))" -ForegroundColor Cyan
    $ctx = "This relay works through a queue of tasks. Your task now is $($t.id) (.ai/tasks/$($t.file)): work only on that task. "
    $null = Run-Job $t.stages $t.stages "$($t.id): " $ctx
    $t.rounds = $script:jobRounds
    $t.verdict = $(if ($script:verdict) { $script:verdict } else { '' })
    $t.state = $(if ($script:verdict -eq 'APPROVED') { 'done' } else { 'not approved' })
    if ($t.state -ne 'done' -and $PauseOnUnapproved) {
      if (-not (Wait-QueueApproval $t)) {
        $script:queueHeld = $true
        return
      }
    }
    elseif ($t.state -ne 'done' -and $k -lt $script:queueList.Count -and $Overnight) {
      Write-Host "  overnight: $($t.id) was not approved; going on with the next task (it's listed in the morning report)." -ForegroundColor DarkYellow
    }
    elseif ($t.state -ne 'done' -and $k -lt $script:queueList.Count) {
      Write-Status 'waiting' $null '' '' "$($t.id) was not approved after $($t.rounds) fix round(s). n = go on with the next task, q = stop the queue."
      $a = (Read-Choice "`n$($t.id) was not approved. [n]ext task anyway / [q]uit" 'n').Trim().ToLower()
      if ($a -ne 'n') { foreach ($r in $script:queueList) { if ($r.state -eq 'pending') { $r.state = 'skipped' } }; break }
    }
  }
  $script:currentTask = ''
}

# ---------- overnight: pre-flight (while you're still there), own branch, keep the PC awake ----------
function Codex-Trusts([string]$dir) {
  $cfg = Join-Path $HOME '.codex\config.toml'
  if (-not (Test-Path $cfg)) { return $false }
  $want = $dir.TrimEnd('\').ToLower()
  foreach ($m in [regex]::Matches((Get-Content $cfg -Raw), "(?m)^\[projects\.'([^']+)'\]\s*\r?\ntrust_level\s*=\s*`"trusted`"")) {
    if ($m.Groups[1].Value.TrimEnd('\').ToLower() -eq $want) { return $true }
  }
  return $false
}
# git's stdout (stderr ignored), run safely in the project folder.
function Git-Out([string[]]$gitArgs) {
  $gitExe = (Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if (-not $gitExe) { return '' }
  $r = Invoke-Native $gitExe (@('-C', $Folder) + $gitArgs) 60
  return [string]$r.Out
}
function Start-Overnight {
  Write-Host "`n== Overnight pre-flight ==" -ForegroundColor Cyan
  $script:nightStart = Get-Date
  $problems = @()
  $isGit = $false
  $isGit = ((Git-Out @('rev-parse', '--is-inside-work-tree')).Trim() -eq 'true')
  if (-not $isGit) { throw "Overnight needs a git repository (the night's work goes on its own branch). Run 'git init' in $Folder first." }
  $dirty = @((Git-Out @('status', '--porcelain')) -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '\.ai/relay/' })
  $script:nightBranch = 'relay/overnight-' + (Get-Date).ToString('yyyyMMdd-HHmm')
  $script:nightBase = (Git-Out @('rev-parse', '--short', 'HEAD')).Trim()
  Write-Host "  branch    : new branch $($script:nightBranch) from $($script:nightBase) (never pushed; review it in the morning)"
  if ($dirty) { Write-Host "  note      : $($dirty.Count) uncommitted change(s) come along onto that branch: $((($dirty | Select-Object -First 5) -join '; '))" -ForegroundColor Yellow }
  Write-Host "  runs      : $(Night-LimitText)"
  Write-Host "  stages    : interrupted after $TimeoutMin min; nudged after $($script:stallMin) min without progress, skipped if still stuck"
  Write-Host "  agents    : $(if ($script:skipPerms) { 'ALL PERMISSION CHECKS SKIPPED (claude, codex: no sandbox, antigravity)' } else { 'their normal permission modes' })"
  foreach ($k in @('claude', 'codex', 'agy')) { if (-not (Get-Command $k -ErrorAction SilentlyContinue)) { $problems += "$k is not installed or not on PATH" } }
  if (-not (Codex-Trusts $Folder)) {
    Write-Host "  codex     : this folder isn't trusted in Codex yet, so Codex would stop at 'Trust this folder?' tonight." -ForegroundColor Yellow
    if ((Read-Host '  Mark it trusted in ~/.codex/config.toml now? y/n [y]') -ne 'n') {
      Add-Content -Path (Join-Path $HOME '.codex\config.toml') -Value "`n[projects.'$($Folder.TrimEnd('\'))']`ntrust_level = `"trusted`"" -Encoding UTF8
      Write-Host '  codex     : trusted.' -ForegroundColor Green
    } else { $problems += "Codex isn't trusted here: a Codex stage would wait at its trust question" }
  } else { Write-Host '  codex     : folder trusted' }
  $u = Get-PlanUsage
  $fmt = { param($v) if (-not $v) { 'no data' } else { "5h $(if ($v.fiveHour) { [math]::Round($v.fiveHour.used) } else { '-' })%, week $(if ($v.week) { [math]::Round($v.week.used) } else { '-' })%" } }
  Write-Host "  usage now : Claude $(& $fmt $u.claude) | Codex $(& $fmt $u.codex) | Antigravity not reported. Limits hit at night are waited out."
  Write-Host '  windows   : the relay keeps the PC awake while it runs. Keep it on power; set Windows Update active hours to cover the night.' -ForegroundColor DarkGray
  Write-Host '  you       : watch or step in any time (type in any stage tab; Pause/Stop in the AI Project panel).' -ForegroundColor DarkGray
  foreach ($p in $problems) { Write-Host "  PROBLEM   : $p" -ForegroundColor Red }
  Write-Status 'waiting' $null '' '' 'Overnight pre-flight: check it in the AI Relay tab and answer y to start the night.'
  if ((Read-Host "`nStart the overnight run? y/n [y]") -eq 'n') { Write-Status 'stopped'; Write-Host 'Not started.'; exit 0 }
  # Invoke-Native, not '& git': git prints normal progress on stderr, which Windows PowerShell 5.1 with
  # ErrorActionPreference Stop turns into a fatal error ("Switched to a new branch ..." stopped the first test run).
  $gs = Invoke-Native (Get-Command git | Select-Object -First 1).Source @('-C', $Folder, 'switch', '-c', $script:nightBranch) 60
  if ($gs.Code -ne 0) { throw "Couldn't create branch $($script:nightBranch): $($gs.Err.Trim())" }
  Write-Host "  $($gs.Err.Trim())"
  # Keep Windows from sleeping while this process runs (ES_CONTINUOUS | ES_SYSTEM_REQUIRED); ends with the process.
  try {
    Add-Type -Namespace RelayNight -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction Stop
    [void][RelayNight.Power]::SetThreadExecutionState([uint32]2147483649)
  } catch { Write-Host "  couldn't keep the PC awake: $($_.Exception.Message)" -ForegroundColor Yellow }
  $script:nightStart = Get-Date
  Write-Host "  overnight run started on branch $($script:nightBranch)." -ForegroundColor Green
}
# The morning report: .ai/relay/overnight-report.md (not committed).
function Write-NightReport([string]$how, [switch]$IncludeCurrentQueue) {
  if (-not $Overnight -or -not $script:nightBranch) { return }
  try {
    $L = @("# Overnight relay report: $name", '',
      "- Branch: ``$($script:nightBranch)`` from ``$($script:nightBase)`` (not pushed). Review: ``git log $($script:nightBase)..$($script:nightBranch)``",
      "- Ran: $($script:nightStart.ToString('ddd dd MMM HH:mm')) to $((Get-Date).ToString('ddd dd MMM HH:mm')), cycles: $($script:cycle), ended: $how",
      "- Goal: $($script:firstGoal)", '')
    $reportTasks = @($script:allTasks)
    if ($IncludeCurrentQueue) { $reportTasks += @($script:queueList) }
    if ($reportTasks.Count) {
      $L += '## Tasks', '', '| Task | State | Verdict | Fix rounds | Agents |', '|---|---|---|---|---|'
      foreach ($t in $reportTasks) { $L += "| $($t.id) $($t.title) | $($t.state) | $($t.verdict) | $($t.rounds) | $($t.agents) |" }
      $L += ''
    }
    $L += '## Stages', '', '| # | Task | Role | Agent | State | Min | Cleaned up |', '|---|---|---|---|---|---|---|'
    foreach ($h in $script:history) { $L += "| $($h.n) | $($h.task) | $($h.role) | $($h.agent) | $($h.state) | $($h.minutes) | $((@($h.cleaned | ForEach-Object { $_ }) -join '; ')) |" }
    $L += '', '## Commits on the branch', ''
    $L += @((Git-Out @('log', '--oneline', "$($script:nightBase)..HEAD")) -split "`r?`n" | Where-Object { $_ } | ForEach-Object { "- $_" })
    if ($script:fatal) { $L += '', "## Stopped by an error", '', $script:fatal }
    $p = Join-Path $relayDir 'overnight-report.md'
    [IO.File]::WriteAllText($p, ($L -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  morning report: $p" -ForegroundColor Cyan
  } catch { Write-Host "  couldn't write the morning report: $($_.Exception.Message)" -ForegroundColor Yellow }
}
$script:queueHeld = $false
$script:allTasks = New-Object System.Collections.ArrayList
$script:cycle = 1
$script:firstGoal = $goalText
if ($Overnight) { Start-Overnight }

if ($Queue -or $Tasks.Trim()) {
  # Overnight: after a queue, plan the next one from STATE's Next list, until the time or cycle limit.
  $cycle = 0
  while ($true) {
    $cycle++; $script:cycle = $cycle
    if ($cycle -gt 1) {
      $Tasks = ''
      $goalText = "continue with the Next list in .ai/STATE.md (overnight cycle $cycle; the night started with: $($script:firstGoal)). " +
                  "Only plan work that is worth doing for the project's goal; never invent busywork. If nothing worthwhile is left " +
                  "(or the rest needs the user), write an empty .ai/relay/queue.txt and say why in HANDOFF.md"
      Write-Host "`n########## Overnight cycle $cycle ##########" -ForegroundColor Cyan
    }
    try { Run-Queue }
    catch {
      if ($Overnight -and $cycle -gt 1) { Write-Host "  no further tasks to run: $($_.Exception.Message)" -ForegroundColor DarkYellow; break }
      throw
    }
    foreach ($t in $script:queueList) { [void]$script:allTasks.Add($t) }
    if ($script:queueHeld) {
      $why = "Stopped at the overnight cutoff while $($script:currentTask) still awaited approval."
      Write-Status 'stopped' $null '' '' $why
      Write-NightReport $why
      Write-Host $why -ForegroundColor Yellow
      Show-Summary
      exit 0
    }
    if (-not $Overnight -or ($MaxCycles -gt 0 -and $cycle -ge $MaxCycles) -or (Get-Date) -ge $script:untilAt) { break }
    if (-not @($first | Where-Object { $_.Role -in @($script:teamRoles | Where-Object once | ForEach-Object { $_.role }) })) { break }   # no planner to plan more
  }
  Write-Host "`n== Queue finished ==" -ForegroundColor Cyan
  Write-Status 'finished'
  $doneN = @($script:allTasks | Where-Object { $_.state -eq 'done' }).Count
  Notify-User "$name`: queue finished" "$doneN of $(@($script:allTasks).Count) task(s) done." $(if ($doneN -eq @($script:allTasks).Count) { 'success' } else { 'warning' }) ([string]$env:HC_TERMINAL_ID)
  foreach ($t in $script:allTasks) { Write-Host ("  {0,-8} {1,-13} {2}" -f $t.id, $t.state, $t.title) -ForegroundColor $(if ($t.state -eq 'done') { 'Green' } else { 'Yellow' }) }
  Write-NightReport 'finished'
  Show-Summary
  exit 0
}

$null = Run-Job $first $loopStages '' ''
$round = $script:jobRounds
Write-NightReport 'finished'

Write-Host "`n== Relay finished ==" -ForegroundColor Cyan
Write-Status 'finished'
Notify-User "$name`: relay finished" $(if ($script:verdict -eq 'APPROVED') { "$($script:judgeRole) approved after $round fix round(s)." }
  elseif ($script:verdict) { "Still CHANGES_REQUESTED after $round fix round(s): see .ai/HANDOFF.md." } else { 'All stages done.' }) `
  $(if ($script:verdict -and $script:verdict -ne 'APPROVED') { 'warning' } else { 'success' }) ([string]$env:HC_TERMINAL_ID)
if ($script:verdict -eq 'APPROVED') { Write-Host "Verdict ($($script:judgeRole)): APPROVED" -ForegroundColor Green }
elseif ($script:verdict) { Write-Host "Verdict ($($script:judgeRole)): CHANGES_REQUESTED after $round fix round(s). See .ai/HANDOFF.md to decide what's next." -ForegroundColor Yellow }
Show-Summary
