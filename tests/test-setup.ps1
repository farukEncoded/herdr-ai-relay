# test-setup.ps1 - runs every setup.ps1 action against a throwaway home folder and lists what it wrote.
# Never touches the real home, PATH or Herdr folder: USERPROFILE, HERDR_APP_HOME and the PATH stand-in
# (AI_RELAY_KIT_FAKE_PATH) all point into a temp folder. Usage: powershell -File tests\test-setup.ps1
$ErrorActionPreference = 'Stop'
$kitMods = Join-Path $PSScriptRoot '..\mods' | Resolve-Path
$fake = Join-Path ([IO.Path]::GetTempPath()) ("airk-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fake | Out-Null
$herdr = Join-Path $fake '.config\herdr-app'
New-Item -ItemType Directory -Path $herdr -Force | Out-Null
# Pre-existing user files, to check backups and restore.
New-Item -ItemType Directory -Path (Join-Path $fake '.codex') | Out-Null
Set-Content -Path (Join-Path $fake '.codex\AGENTS.md') -Value "# my codex rules`r`nkeep me" -Encoding ASCII
Set-Content -Path (Join-Path $herdr 'programs.json') -Value '{ "programs": { "mytool": { "name": "My Tool" } } }' -Encoding ASCII
Set-Content -Path (Join-Path $fake 'fake-path.txt') -Value 'C:\Windows' -Encoding ASCII

$saved = @{ USERPROFILE = $env:USERPROFILE; HERDR_APP_HOME = $env:HERDR_APP_HOME; AI_RELAY_KIT_FAKE_PATH = $env:AI_RELAY_KIT_FAKE_PATH
            CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR; CODEX_HOME = $env:CODEX_HOME }
$fail = 0
function Check([string]$what, [bool]$ok) { if ($ok) { Write-Host "  PASS $what" -ForegroundColor Green } else { Write-Host "  FAIL $what" -ForegroundColor Red; $script:fail++ } }
function Run([string[]]$a) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup @a -HerdrHome $herdr
  $last = @($out)[-1]
  Write-Host ("> setup.ps1 " + ($a -join ' ')) -ForegroundColor Cyan
  Write-Host "  $last"
  return ($last | ConvertFrom-Json)
}
function Tree { Get-ChildItem -LiteralPath $fake -Recurse -File -Force | Where-Object { $_.FullName -notlike '*\mods\*' } | ForEach-Object { '  ' + $_.FullName.Substring($fake.Length + 1) + "  ($($_.Length) b)" } }

try {
  $env:USERPROFILE = $fake; $env:HERDR_APP_HOME = $herdr; $env:AI_RELAY_KIT_FAKE_PATH = Join-Path $fake 'fake-path.txt'
  $env:CLAUDE_CONFIG_DIR = ''; $env:CODEX_HOME = ''
  Write-Host "Fake home: $fake`n"

  # Adding the kit = copying every folder in mods/ into the Herdr home (what the agent does per Herdr's AGENTS.md).
  # Setup then runs from there, exactly as the panel runs it.
  New-Item -ItemType Directory -Path (Join-Path $herdr 'mods') -Force | Out-Null
  Copy-Item -Path (Join-Path $kitMods '*') -Destination (Join-Path $herdr 'mods') -Recurse -Force
  $want = @('ai-relay-kit', 'ai-relay-kit-launcher', 'ai-relay-kit-commands', 'ai-relay-kit-handoff', 'ai-relay-kit-drawer', 'ai-relay-kit-overnight')
  foreach ($m in $want) { Check "mod added: $m (main.js, mod.json, lib.js)" ((Test-Path (Join-Path $herdr "mods\$m\main.js")) -and (Test-Path (Join-Path $herdr "mods\$m\mod.json")) -and (Test-Path (Join-Path $herdr "mods\$m\lib.js"))) }
  Check 'no extra mod folders' (@(Get-ChildItem (Join-Path $herdr 'mods') -Directory).Count -eq $want.Count)
  Check 'relay icon for programs.json is there' (Test-Path (Join-Path $herdr 'mods\ai-relay-kit\icons\relay.svg'))
  $setup = Join-Path $herdr 'mods\ai-relay-kit\payload\setup.ps1'

  $d = Run @('-Action', 'detect')
  Check 'detect: not installed' (-not $d.installed)
  Check 'detect: home is the fake one' ($d.home -eq $fake)
  Write-Host ("  tools: " + (($d.tools | ForEach-Object { "$($_.key)=$(if ($_.found) {'found'} else {'missing'})" }) -join ', '))

  $r = Run @('-Action', 'protocol', '-Agent', 'claude')
  Check 'protocol before install is refused' (-not $r.ok)

  $r = Run @('-Action', 'install'); Check 'install ok' $r.ok
  $ra = Get-Content (Join-Path $fake '.agents\protocol\RELAY-AGENT.md') -Raw
  Check 'RELAY-AGENT.md has the real path' (($ra -notmatch 'PROTOCOL_DIR') -and $ra.Contains("$fake\.agents\protocol\ai-relay.ps1"))
  foreach ($a in @('claude', 'codex', 'antigravity')) { $r = Run @('-Action', 'protocol', '-Agent', $a); Check "protocol $a ok" $r.ok }
  $cx = Get-Content (Join-Path $fake '.codex\AGENTS.md') -Raw
  Check 'codex file keeps old text + block' (($cx -match 'keep me') -and ($cx -match 'AI-PROTOCOL:END'))
  Check 'codex backup made' (Test-Path (Join-Path $fake '.codex\AGENTS.md.bak-ai-relay-kit'))
  Check 'claude file imports the protocol' ((Get-Content (Join-Path $fake '.claude\CLAUDE.md') -Raw) -match '@~/.agents/protocol/AI-PROTOCOL.md')
  $r = Run @('-Action', 'protocol', '-Agent', 'codex'); Check 'protocol twice: still one block' (([regex]::Matches((Get-Content (Join-Path $fake '.codex\AGENTS.md') -Raw), 'AI-PROTOCOL:BEGIN')).Count -eq 1)
  $r = Run @('-Action', 'path'); Check 'path added' $r.added
  Check 'fake PATH has bin' ((Get-Content $env:AI_RELAY_KIT_FAKE_PATH -Raw) -match [regex]::Escape("$fake\.agents\protocol\bin"))
  $r = Run @('-Action', 'programs'); Check 'programs ok' $r.ok
  $pj = Get-Content (Join-Path $herdr 'programs.json') -Raw | ConvertFrom-Json
  Check 'programs.json keeps mytool' ([bool]$pj.programs.mytool)
  Check 'programs.json has relay' ([bool]$pj.programs.relay)
  $d = Run @('-Action', 'detect'); Check 'detect: installed' $d.installed
  Write-Host "`nFiles in the fake home after setup:"; Tree
  Write-Host "`nprograms.json:"; Get-Content (Join-Path $herdr 'programs.json')

  # The user edits a file after setup: remove must keep their edit and only take our block out.
  Add-Content -Path (Join-Path $fake '.gemini\GEMINI.md') -Value "my own line" -Encoding ASCII
  $r = Run @('-Action', 'remove'); Check 'remove ok' $r.ok
  $r.notes | ForEach-Object { Write-Host "    $_" }
  Check 'codex file restored exactly' ((Get-Content (Join-Path $fake '.codex\AGENTS.md') -Raw).Trim() -eq "# my codex rules`r`nkeep me")
  Check 'claude file (created by setup) deleted' (-not (Test-Path (Join-Path $fake '.claude\CLAUDE.md')))
  $gm = Get-Content (Join-Path $fake '.gemini\GEMINI.md') -Raw
  Check 'gemini edit kept, block gone' (($gm -match 'my own line') -and ($gm -notmatch 'AI-PROTOCOL'))
  Check 'programs.json restored' ((Get-Content (Join-Path $herdr 'programs.json') -Raw).Trim() -eq '{ "programs": { "mytool": { "name": "My Tool" } } }')
  Check 'PATH restored' ((Get-Content $env:AI_RELAY_KIT_FAKE_PATH -Raw).Trim() -eq 'C:\Windows')
  Check 'protocol folder gone' (-not (Test-Path (Join-Path $fake '.agents\protocol')))
  Write-Host "`nFiles in the fake home after remove:"; Tree

  # An earlier hand install in ~/.agents/protocol: install backs it up and keeps relay-defaults.json; remove restores.
  Write-Host "`nEarlier install already there:" -ForegroundColor Cyan
  $pd = Join-Path $fake '.agents\protocol'
  New-Item -ItemType Directory -Path $pd -Force | Out-Null
  Set-Content -Path (Join-Path $pd 'ai-relay.ps1') -Value '# my older relay' -Encoding ASCII
  Set-Content -Path (Join-Path $pd 'relay-defaults.json') -Value '{ "maxRounds": 1 }' -Encoding ASCII
  $d = Run @('-Action', 'detect'); Check 'detect: foreign install seen' $d.foreign
  $r = Run @('-Action', 'install'); Check 'install notes backup + kept defaults' ((($r.notes -join ',') -match 'backed up ai-relay.ps1') -and (($r.notes -join ',') -match 'kept your relay-defaults.json'))
  Check 'user defaults untouched' ((Get-Content (Join-Path $pd 'relay-defaults.json') -Raw).Trim() -eq '{ "maxRounds": 1 }')
  $r = Run @('-Action', 'remove'); Check 'remove ok' $r.ok
  Check 'older relay restored' ((Get-Content (Join-Path $pd 'ai-relay.ps1') -Raw).Trim() -eq '# my older relay')
  Check 'user defaults still there' (Test-Path (Join-Path $pd 'relay-defaults.json'))
  Write-Host "`nFiles in the fake home at the end:"; Tree
} finally {
  foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $(if ($saved[$k]) { $saved[$k] } else { '' }) }
  Remove-Item -LiteralPath $fake -Recurse -Force
}
Write-Host ""
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'All checks passed' -ForegroundColor Green }
