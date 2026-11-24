# check-setup-render.ps1 - `herdr-app check` only renders a mod's first state, which is the project view.
# This copies the panel to a temp folder, makes init() open the setup screen with a canned detect result
# (not installed / installed + outdated / failed / Windows-only notice), plus the project view with awkward
# relay data (incl. a fatal error), and the launcher with Overnight ticked; runs `herdr-app check` on each copy.
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\mods\ai-relay-kit' | Resolve-Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("airk-render-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$tools = '[{"key":"claude","name":"Claude Code","found":true,"path":"C:/x/claude.exe","url":"https://example.invalid"},' +
         '{"key":"codex","name":"Codex CLI","found":false,"path":"","url":"https://example.invalid"},' +
         '{"key":"antigravity","name":"Antigravity CLI (agy)","found":true,"path":"C:/x/agy.exe","url":"https://example.invalid"},' +
         '{"key":"hc","name":"herdr-core (hc)","found":true,"path":"C:/x/hc.exe","url":"https://example.invalid"},' +
         '{"key":"git","name":"Git","found":false,"path":"","url":"https://example.invalid"}]'
$prot = '{"claude":{"file":"C:/h/.claude/CLAUDE.md","exists":true,"hasBlock":true,"managed":true},' +
        '"codex":{"file":"C:/h/.codex/AGENTS.md","exists":false,"hasBlock":false,"managed":false},' +
        '"antigravity":{"file":"C:/h/.gemini/GEMINI.md","exists":true,"hasBlock":false,"managed":false}}'
$cases = [ordered]@{
  fresh     = "{ok:true,installed:false,foreign:true,kitVersion:'0.1.0',installedVersion:'',protocolDir:'C:/h/.agents/protocol',tools:$tools,protocol:$prot,path:{dir:'C:/h/.agents/protocol/bin',onPath:false},programs:{entries:{},managed:false}}"
  installed = "{ok:true,installed:true,foreign:false,kitVersion:'0.2.0',installedVersion:'0.1.0',protocolDir:'C:/h/.agents/protocol',tools:$tools,protocol:$prot,path:{dir:'C:/h/.agents/protocol/bin',onPath:true},programs:{entries:{relay:true},managed:true}}"
  failed    = "{ok:false,error:'powershell not found'}"
  other     = "{ok:false,unsupported:true}"
}
# The project view with awkward relay data: a missing usage window, an unknown agent, a stage without a role,
# a stage that cleaned up after itself, a queue task without an id. Nothing in it may reach .child() as null.
$project = "this.key = 'undefined|null'; this.setup.info = {ok:true,installed:true,kitVersion:'0.1.0',installedVersion:'0.1.0'}; " +
  "this.data = {root:'C:/p/demo',setup:true,updated:'',active:'',next:['one','two'],status:['s1','s2','s3'],blockers:['none'],log:[]," +
  "usage:{claude:{plan:'max',week:{used:42}},codex:null}," +
  "relay:{state:'running',live:true,error:'Herdr did not answer for 20 minutes',overnight:true,until:'2026-11-25T07:00:00',queueMode:true,maxCycles:3,cycle:2,nightBranch:'relay/overnight-test',stage:3,role:'tester',agent:'foo',round:1,maxRounds:3,label:'',started:new Date().toISOString()," +
  "relayStarted:new Date().toISOString(),updated:new Date().toISOString(),plannedMax:7,verdict:'CHANGES_REQUESTED',currentTask:'T-002'," +
  "queue:[{id:'T-001',title:'T-001 first',state:'done',agents:'executor=codex'},{title:'no id',state:'pending',agents:'executor=bar'}]," +
  "stages:[{n:1,role:'planner',agent:'claude',state:'done',minutes:3,model:'default',effort:'high',task:'T-002',cleaned:['node (pid 1)']}," +
  "{n:2,agent:'foo',state:'done',minutes:1,model:'x',effort:'default',task:'T-002'},{n:3,role:'tester',agent:'codex',state:'running',task:'T-002'}]," +
  "config:{team:'coding',judge:'reviewer',stages:'a',loop:'b',effort:'recommended',model:'default'}}};"
$fail = 0
try {
  foreach ($name in @($cases.Keys) + 'project') {
    $dir = Join-Path $tmp "$name\ai-relay-kit"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -Path "$src\*" -Destination $dir -Recurse -Force
    $main = Join-Path $dir 'main.js'
    $js = [IO.File]::ReadAllText($main)
    $hook = '    this.view = "project";  // or "setup"'
    if (-not $js.Contains($hook)) { throw 'hook line not found in main.js' }
    $inject = if ($name -eq 'project') { $hook + "`n    $project" }
      else { $hook + "`n    this.view = 'setup'; this.setup.info = $($cases[$name]); this.setup.msg = { 'setup-install': { ok: true, text: 'Copied.' }, 'setup-path': { ok: false, text: 'Access denied' } };" }
    [IO.File]::WriteAllText($main, $js.Replace($hook, $inject))
    $out = cmd /c "herdr-app check `"$dir`" 2>&1"
    if ($LASTEXITCODE -eq 0) { Write-Host "PASS renders: $name" -ForegroundColor Green }
    else { Write-Host "FAIL $name`n$out" -ForegroundColor Red; $fail++ }
  }
  # The Start AI relay dialog with the Overnight box ticked (its warning line shows).
  $ldir = Join-Path $tmp 'launcher\ai-relay-kit-launcher'
  New-Item -ItemType Directory -Path $ldir -Force | Out-Null
  Copy-Item -Path (Join-Path $src '..\ai-relay-kit-launcher\*') -Destination $ldir -Recurse -Force
  $lmain = Join-Path $ldir 'main.js'
  $ljs = [IO.File]::ReadAllText($lmain)
  $lhook = '    this.overnight = false;'
  if (-not $ljs.Contains($lhook)) { throw 'overnight hook not found in the launcher' }
  [IO.File]::WriteAllText($lmain, $ljs.Replace($lhook, '    this.overnight = true;'))
  $out = cmd /c "herdr-app check `"$ldir`" 2>&1"
  if ($LASTEXITCODE -eq 0) { Write-Host "PASS renders: launcher-overnight" -ForegroundColor Green }
  else { Write-Host "FAIL launcher-overnight`n$out" -ForegroundColor Red; $fail++ }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
if ($fail) { exit 1 }
