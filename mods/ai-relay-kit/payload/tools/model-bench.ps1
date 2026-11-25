# model-bench.ps1 - measures OpenRouter models (through OpenCode) on small relay tasks with a known right answer (D-032).
#
#   powershell -File tools\model-bench.ps1 -Queue                  run what tools/model-scout.mjs queued (usage/model-scout.json)
#   powershell -File tools\model-bench.ps1 -Model <id> -Role tester [-Role executor,reviewer]
#   add -NoPaid to skip paid models, -Parallel 3 to run that many at once (default 3)
#
# Tasks (one per role, in a throwaway git project under usage/bench-work, each through a real one-stage relay):
#   tester    calc.js with 2 planted bugs against 3 acceptance criteria: write tests, report both bugs, don't fix code.
#   executor  the same calc.js and its acceptance tests (test/acceptance.test.js): make every test pass, don't edit tests.
#   reviewer  a finished-looking calc.js whose div() returns null for 0 although AC2 says it must throw; its tests miss
#             it: the reviewer must answer CHANGES_REQUESTED and name the problem.
# Every task also checks the protocol: done file with an opencode-cli/<model> signature, a proper LOG line, a commit,
# HANDOFF rewritten, STATE's Active line cleared, no uncommitted files. Results: usage/bench-results.jsonl.
# Paid models: only within relay-defaults.json scout.paidBenchCapUsd per stage (estimated from the price) and
# scout.maxPaidBenchPerWeek models a week. Keep this file ASCII and Windows PowerShell 5.1 compatible.
param([switch]$Queue, [string]$Model = '', [string[]]$Role = @('tester'), [switch]$NoPaid, [int]$Parallel = 3,
      [int]$TimeoutMin = 25)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$usage = Join-Path $root 'usage'
$work = Join-Path $usage 'bench-work'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$results = Join-Path $usage 'bench-results.jsonl'
function W([string]$p, [string]$t) { New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null; [IO.File]::WriteAllText($p, $t.Replace("`r`n", "`n"), $utf8) }
$script:gitExe = (Get-Command git.exe -CommandType Application | Select-Object -First 1).Source
function Invoke-Git([string]$dir, [string[]]$a) { $o = & $script:gitExe -C $dir @a 2>$null; return $o }

# ---------- the tasks ----------
$calcGood = @'
export function add(a, b) { check(a, b); return a + b; }
export function sub(a, b) { check(a, b); return a - b; }
export function mul(a, b) { check(a, b); return a * b; }
export function div(a, b) { check(a, b); if (b === 0) throw new Error("Division by zero"); return a / b; }
function check(a, b) { if (typeof a !== "number" || typeof b !== "number") throw new TypeError("Expected numbers"); }
'@
$calcBuggy = @'
// Calculator used by the billing page. See .ai/tasks/T-001.md.
export function add(a, b) { return a + b; }
export function sub(a, b) { return a - b; }
export function mul(a, b) { return a * b; }
export function div(a, b) { return a / b; }
'@
$calcReview = @'
// Calculator used by the billing page. See .ai/tasks/T-001.md.
export function add(a, b) { check(a, b); return a + b; }
export function sub(a, b) { check(a, b); return a - b; }
export function mul(a, b) { check(a, b); return a * b; }
export function div(a, b) { check(a, b); if (b === 0) return null; return a / b; }
function check(a, b) { if (typeof a !== "number" || typeof b !== "number") throw new TypeError("Expected numbers"); }
'@
$acceptanceTests = @'
import { test } from "node:test";
import assert from "node:assert/strict";
import { add, sub, mul, div } from "../calc.js";
test("AC1 add/sub/mul", () => { assert.equal(add(2, 3), 5); assert.equal(sub(-1.5, 2), -3.5); assert.equal(mul(-2, 0.5), -1); });
test("AC2 div by zero throws", () => { assert.throws(() => div(1, 0), { message: "Division by zero" }); assert.equal(div(6, 3), 2); });
test("AC3 type errors", () => { for (const f of [add, sub, mul, div]) { assert.throws(() => f("2", 1), TypeError); assert.throws(() => f(1, null), TypeError); } });
'@
$reviewTests = @'
import { test } from "node:test";
import assert from "node:assert/strict";
import { add, sub, mul, div } from "../calc.js";
test("AC1 add/sub/mul", () => { assert.equal(add(2, 3), 5); assert.equal(sub(-1.5, 2), -3.5); assert.equal(mul(-2, 0.5), -1); });
test("div works", () => { assert.equal(div(6, 3), 2); });
test("AC3 type errors", () => { for (const f of [add, sub, mul, div]) assert.throws(() => f("2", 1), TypeError); });
'@
$taskFile = @'
# T-001 Calculator module - status: STATUSX
## Goal
A calculator module (calc.js) the billing page can rely on.
## Approach
Plain functions in calc.js; Node's built-in test runner (npm test).
## Files
calc.js, test/
## Acceptance criteria
- [ ] AC1: add, sub and mul return the correct number for any two finite numbers (including negatives and decimals).
- [ ] AC2: div(a, 0) throws an Error whose message is exactly "Division by zero".
- [ ] AC3: every function throws a TypeError when either argument is not a number (for example a string like "2").
## Notes
NOTESX
## Test report
REPORTX
## Review
(empty)
'@
function New-Project([string]$dir, [string]$role) {
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  W "$dir\package.json" '{ "name": "calc-app", "version": "1.0.0", "type": "module", "scripts": { "test": "node --test" } }'
  W "$dir\AGENTS.md" "# calc-app`nSmall calculator module (Node 22, ES modules). Tests: npm test (node --test).`nAuto-commit: yes`n"
  W "$dir\.ai\DECISIONS.md" "# Decisions`nActive: D-001 plain ES module, node --test`n`n## D-001 Plain ES module, Node's test runner - active`nDecision: no dependencies.`n"
  $prev = @{ tester = 'executor'; executor = 'planner'; reviewer = 'tester' }[$role]
  switch ($role) {
    'tester' {
      W "$dir\calc.js" $calcBuggy
      W "$dir\.ai\tasks\T-001.md" ($taskFile.Replace('STATUSX', 'testing').Replace('NOTESX', 'Executor: implemented calc.js.').Replace('REPORTX', '(empty)'))
      $next = 'Test T-001 against its acceptance criteria'
    }
    'executor' {
      W "$dir\calc.js" $calcBuggy
      W "$dir\test\acceptance.test.js" $acceptanceTests
      W "$dir\.ai\tasks\T-001.md" ($taskFile.Replace('STATUSX', 'in-progress').Replace('NOTESX', 'Planner: the acceptance tests are in test/acceptance.test.js; do not change them.').Replace('REPORTX', '(empty)'))
      $next = 'Implement T-001 so every acceptance test passes'
    }
    'reviewer' {
      W "$dir\calc.js" $calcReview
      W "$dir\test\calc.test.js" $reviewTests
      W "$dir\.ai\tasks\T-001.md" ($taskFile.Replace('STATUSX', 'review').Replace('NOTESX', 'Executor: implemented calc.js with type checks.').Replace('REPORTX', 'Tester: npm test passes (3 tests). AC1-AC3 covered.'))
      $next = 'Review T-001 against its acceptance criteria'
    }
  }
  W "$dir\.ai\STATE.md" "# State - calc-app`nUpdated: 2026-11-25 10:00 by claude-cli/opus-5.5`nActive: none`n## Goal`nCalculator module for billing.`n## Status`n- in progress: T-001`n## Next`n1. $next`n## Blockers / open questions`n- None`n## Key paths & commands`n- npm test`n"
  W "$dir\.ai\HANDOFF.md" "# Handoff - 2026-11-25 10:00 from claude-cli/opus-5.5 ($prev) -> next: $role`nTask: T-001   Result: done`nDid: - previous stage finished`nNext: - $next`nWatch out: - none`n"
  W "$dir\.ai\LOG.md" "2026-11-25 10:00 | claude-cli/opus-5.5 | $prev | T-001 | previous stage done`n"
  [void](Invoke-Git $dir @('init', '-q')); [void](Invoke-Git $dir @('-c', 'user.name=bench', '-c', 'user.email=bench@localhost', 'add', '-A'))
  [void](Invoke-Git $dir @('-c', 'user.name=bench', '-c', 'user.email=bench@localhost', 'commit', '-q', '-m', "T-001: ready for the $role"))
  return $next
}

# ---------- grading ----------
function Grade([string]$dir, [string]$role) {
  $c = [ordered]@{}
  $done = Get-ChildItem "$dir\.ai\relay" -Filter 'stage-*.done' -ErrorAction SilentlyContinue | Select-Object -First 1
  # @() around the if: an if-expression unrolls a one-line file to a string ([0] would be its first letter).
  $lines = @(if ($done) { Get-Content $done.FullName })
  $sig = if ($lines.Count) { ([string]$lines[0]).Trim() } else { '' }
  $c.doneFile = [bool]$done
  $c.signature = $sig -match '^opencode-cli/\S+$'
  $log = @(Get-Content "$dir\.ai\LOG.md" | Select-Object -Skip 1)
  $c.logLine = [bool]($log | Where-Object { $_ -match "^\d{4}-\d\d-\d\d \d\d:\d\d \| opencode-cli/\S+ \| $role \| T-001 \| .+" })
  $c.committed = (@(Invoke-Git $dir @('log', '--format=%s')).Count -ge 2)
  $c.clean = -not (@(Invoke-Git $dir @('status', '--short')) | Where-Object { $_ -notmatch '\.ai/relay' })
  $c.handoff = -not ((Get-Content "$dir\.ai\HANDOFF.md" -Raw) -match 'from claude-cli/opus-5\.5')
  $c.activeCleared = [bool]((Get-Content "$dir\.ai\STATE.md" -Raw) -match '(?im)^Active:\s*none')
  $task = Get-Content "$dir\.ai\tasks\T-001.md" -Raw
  $calcNow = (Get-Content "$dir\calc.js" -Raw).Replace("`r`n", "`n")
  switch ($role) {
    'tester' {
      $rep = [regex]::Match($task, '(?s)## Test report\s*(.*?)(\n## |\z)').Groups[1].Value
      $c.testsWritten = @(Get-ChildItem $dir -Recurse -File -Include '*.test.js', '*.test.mjs', '*.spec.js' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch 'node_modules|\\\.ai\\' }).Count -gt 0
      $c.reportFilled = $rep.Trim().Length -gt 40 -and $rep.Trim() -ne '(empty)'
      $c.foundBug1 = [bool]($rep -match '(?is)(AC2|division by zero|div\(.{0,8}0\)).{0,250}(fail|infinity|not throw|doesn.t throw|bug)')
      $c.foundBug2 = [bool]($rep -match '(?is)(AC3|typeerror|non-number|string).{0,250}(fail|not throw|doesn.t throw|bug|coerc|concaten)')
      $c.codeUntouched = ($calcNow.Trim() -eq $calcBuggy.Replace("`r`n", "`n").Trim())
    }
    'executor' {
      Push-Location $dir; $o = & node --test 2>&1 | Out-String; $ok = $LASTEXITCODE -eq 0; Pop-Location
      $c.allTestsPass = $ok
      $c.testsUntouched = ((Get-Content "$dir\test\acceptance.test.js" -Raw).Replace("`r`n", "`n").Trim() -eq $acceptanceTests.Replace("`r`n", "`n").Trim())
      $c.codeChanged = ($calcNow.Trim() -ne $calcBuggy.Replace("`r`n", "`n").Trim())
    }
    'reviewer' {
      $all = ($lines -join ' ')
      $c.verdict = ($all -match 'CHANGES_REQUESTED') -and ($all -notmatch '(?<!CHANGES_)APPROVED')
      $rev = [regex]::Match($task, '(?s)## Review\s*(.*)$').Groups[1].Value
      $c.namedProblem = [bool]($rev -match '(?is)(AC2|division by zero|div\(.{0,8}0\)|returns? null|null)')
      $c.codeUntouched = ($calcNow.Trim() -eq $calcReview.Replace("`r`n", "`n").Trim())
      $c.reviewFilled = $rev.Trim().Length -gt 40 -and $rev.Trim() -ne '(empty)'
    }
  }
  $score = @($c.Values | Where-Object { $_ -eq $true }).Count
  # What the agent wrote, kept with the result so a miss can be checked after the project is gone.
  return @{ checks = $c; score = $score; max = $c.Count; signature = $sig; logNew = [string[]]@($log | Select-Object -First 2); done = [string[]]@($lines | Select-Object -First 2) }
}

# ---------- what to run ----------
$scoutDefaults = $null; try { $scoutDefaults = (Get-Content (Join-Path $root 'relay-defaults.json') -Raw | ConvertFrom-Json).scout } catch {}
$cap = if ($scoutDefaults -and $scoutDefaults.paidBenchCapUsd) { [double]$scoutDefaults.paidBenchCapUsd } else { 0.25 }
$jobs = @()
if ($Queue) {
  $s = Get-Content (Join-Path $usage 'model-scout.json') -Raw | ConvertFrom-Json
  foreach ($q in @($s.benchQueue)) { if ($q.role -in @('tester', 'executor', 'reviewer')) { $jobs += [pscustomobject]@{ model = $q.model; role = $q.role; paid = [bool]$q.paid; est = $q.estUsd } } }
} elseif ($Model) {
  foreach ($r in ($Role -join ',' -split ',')) { $jobs += [pscustomobject]@{ model = $Model; role = $r.Trim(); paid = ($Model -notmatch ':free$'); est = $null } }
}
if ($NoPaid) { $jobs = @($jobs | Where-Object { -not $_.paid }) }
$jobs = @($jobs | Where-Object { -not $_.paid -or $null -eq $_.est -or [double]$_.est -le $cap })
if (-not $jobs.Count) { Write-Host 'Nothing to benchmark.'; exit 0 }
Write-Host "Benchmark: $($jobs.Count) run(s), $Parallel at a time."

# ---------- run ----------
$relay = Join-Path $root 'ai-relay.ps1'
$ps = Join-Path $PSHOME 'powershell.exe'
$pending = [System.Collections.ArrayList]@($jobs); $running = @()
while ($pending.Count -or $running.Count) {
  while ($pending.Count -and $running.Count -lt $Parallel) {
    $j = $pending[0]; $pending.RemoveAt(0)
    $safe = ($j.model -replace '[^A-Za-z0-9]+', '-').Trim('-')
    $dir = Join-Path $work ("{0}-{1}-{2}" -f $j.role, $safe, (Get-Date -Format 'HHmmss'))
    $goal = New-Project $dir $j.role
    $relayArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$relay`"", '-Folder', "`"$dir`"", '-Goal', "`"$goal`"",
              '-Stages', "$($j.role)=opencode", '-Loop', 'none', '-MaxRounds', '0', '-Effort', 'none', '-Model', "$($j.role)=$($j.model)", '-Team', 'coding')
    [void](Start-Process -FilePath $ps -ArgumentList $relayArgs -WindowStyle Hidden -PassThru)
    $running += [pscustomobject]@{ job = $j; dir = $dir; started = Get-Date }
    Write-Host "  started $($j.role) on $($j.model)"
    Start-Sleep -Seconds 5
  }
  Start-Sleep -Seconds 20
  $still = @()
  foreach ($r in $running) {
    $st = $null; try { $st = Get-Content "$($r.dir)\.ai\relay\status.json" -Raw | ConvertFrom-Json } catch {}
    $over = ((Get-Date) - $r.started).TotalMinutes -ge $TimeoutMin
    if (($st -and $st.state -in @('finished', 'stopped')) -or $over) {
      Start-Sleep -Seconds 5
      $g = Grade $r.dir $r.job.role
      $statRow = $null
      try { $statRow = [IO.File]::ReadAllLines((Join-Path $usage 'model-stats.jsonl')) | Where-Object { $_ -match [regex]::Escape((Split-Path $r.dir -Leaf)) } | Select-Object -Last 1 | ConvertFrom-Json } catch {}
      $row = [ordered]@{ at = (Get-Date).ToString('o'); role = $r.job.role; model = $r.job.model; task = "calc-$($r.job.role)"
        score = $g.score; max = $g.max; paid = $r.job.paid; cost = $(if ($statRow) { $statRow.cost } else { $null })
        minutes = [math]::Round(((Get-Date) - $r.started).TotalMinutes, 1); timedOut = $over; signature = $g.signature; logNew = $g.logNew; doneLines = $g.done
        failed = @($g.checks.GetEnumerator() | Where-Object { $_.Value -ne $true } | ForEach-Object { $_.Key }) }
      [IO.File]::AppendAllText($results, (($row | ConvertTo-Json -Compress) + "`n"), $utf8)
      Write-Host ("  {0,-8} {1,-42} {2}/{3}{4}" -f $r.job.role, $r.job.model, $g.score, $g.max, $(if ($row.failed.Count) { "  missed: $($row.failed -join ', ')" } else { '' }))
      # Clean up: the Herdr space, then the project (the stats line keeps the numbers).
      try {
        $leaf = Split-Path $r.dir -Leaf
        $ls = & herdr-app ls 2>$null | Out-String | ConvertFrom-Json
        foreach ($sp in @($ls.spaces | Where-Object { $_.name -eq $leaf })) { & herdr-app do space.close --id $sp.id --confirmed true 2>$null | Out-Null }
      } catch {}
      Start-Sleep -Seconds 2
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($r.dir) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      Remove-Item $r.dir -Recurse -Force -ErrorAction SilentlyContinue
    } else { $still += $r }
  }
  $running = $still
}
Write-Host "Done. Results: $results"
