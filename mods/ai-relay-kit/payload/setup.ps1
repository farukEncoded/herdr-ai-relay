# setup.ps1 - set up (and remove) the AI Relay Kit on this Windows machine.
# The Herdr panel "Set up AI relay" runs one action at a time, each only after the user clicks it.
# It prints one JSON object (the result) as its last line. Nothing is downloaded and no remote installer runs.
#
#   detect              what is installed: agents found/missing, protocol blocks, PATH, programs.json
#   install             copy the engine (this folder) to ~/.agents/protocol
#   protocol -Agent X   add the protocol block to X's global rules file (claude | codex | antigravity), with a backup
#   path                add ~/.agents/protocol/bin (the 'relay' command) to the user PATH
#   programs            add Herdr programs.json entries (+ menu) for the agents found, plus 'AI Relay'
#   remove              undo everything this kit did (restores backups where the file is unchanged since)
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 -Action detect [-HerdrHome <dir>]
# Test hooks: USERPROFILE decides the home folder; AI_RELAY_KIT_FAKE_PATH (a file) stands in for the user PATH.
# Keep this file ASCII and Windows PowerShell 5.1 compatible.

param(
  [ValidateSet('detect', 'install', 'protocol', 'path', 'programs', 'remove')]
  [string]$Action = 'detect',
  [string]$Agent = '',
  [string]$HerdrHome = ''
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$KitVersion = '0.1.1'
$Source = $PSScriptRoot

$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$ProtocolDir = Join-Path $UserHome '.agents\protocol'
if (-not $HerdrHome) { $HerdrHome = if ($env:HERDR_APP_HOME) { $env:HERDR_APP_HOME } else { Join-Path $UserHome '.config\herdr-app' } }
$ManifestPath = Join-Path $ProtocolDir '.ai-relay-kit.json'
$BinDir = Join-Path $ProtocolDir 'bin'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# The engine files copied to ~/.agents/protocol (relative paths).
$PayloadFiles = @('ai-relay.ps1', 'setup.ps1', 'AI-PROTOCOL.md', 'RELAY-AGENT.md', 'relay-defaults.json',
                  'bin\relay.cmd', 'bin\claude-statusline.ps1')
# Files the user is expected to edit: never overwritten once they exist.
$UserFiles = @('relay-defaults.json')

$claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $UserHome '.claude' }
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $UserHome '.codex' }
$RuleFiles = [ordered]@{
  claude      = Join-Path $claudeHome 'CLAUDE.md'
  codex       = Join-Path $codexHome 'AGENTS.md'
  antigravity = Join-Path $UserHome '.gemini\GEMINI.md'
}
$BEGIN = '<!-- AI-PROTOCOL:BEGIN (managed by AI Relay Kit - edit ~/.agents/protocol/AI-PROTOCOL.md, then run Set up again) -->'
$END = '<!-- AI-PROTOCOL:END -->'
$BlockPattern = '(?s)(\r?\n)*<!-- AI-PROTOCOL:BEGIN.*?<!-- AI-PROTOCOL:END -->(\r?\n)?'

# ---------- helpers ----------
function Out-Result($obj) { Write-Output ($obj | ConvertTo-Json -Depth 8 -Compress) }
function Read-Text([string]$p) { if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } return $null }
function Write-Text([string]$p, [string]$text) {
  $d = Split-Path -Parent $p
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  [IO.File]::WriteAllText($p, $text, $utf8)
}
function Hash-Of([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return '' }
  return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
}
function Read-Manifest {
  $t = Read-Text $ManifestPath
  if ($t) { try { return $t | ConvertFrom-Json } catch {} }
  return [pscustomobject]@{ version = ''; files = @(); protocol = [pscustomobject]@{}; path = $null; programs = $null }
}
function Save-Manifest($m) { Write-Text $ManifestPath ($m | ConvertTo-Json -Depth 8) }
function Set-Prop($obj, [string]$name, $value) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }

# The user PATH (registry), or a stand-in file during tests.
function Get-UserPath {
  if ($env:AI_RELAY_KIT_FAKE_PATH) { $t = Read-Text $env:AI_RELAY_KIT_FAKE_PATH; if ($t) { return $t.Trim() } return '' }
  $u = [Environment]::GetEnvironmentVariable('Path', 'User'); if ($u) { return $u } return ''
}
function Set-UserPath([string]$value) {
  if ($env:AI_RELAY_KIT_FAKE_PATH) { Write-Text $env:AI_RELAY_KIT_FAKE_PATH $value; return }
  [Environment]::SetEnvironmentVariable('Path', $value, 'User')
}
function Same-Dir([string]$a, [string]$b) { return ($a.TrimEnd('\', '/').ToLower() -eq $b.TrimEnd('\', '/').ToLower()) }

function Find-Tool([string]$cmd, [string[]]$dirs) {
  $c = Get-Command $cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  foreach ($d in $dirs) {
    if ($d -and (Test-Path -LiteralPath $d)) {
      foreach ($ext in @('.exe', '.cmd', '.bat')) { $f = Join-Path $d "$cmd$ext"; if (Test-Path -LiteralPath $f) { return $f } }
    }
  }
  return $null
}
function Detect-Tools {
  $L = $env:LOCALAPPDATA; $A = $env:APPDATA
  $list = @(
    @{ key = 'claude'; name = 'Claude Code'; cmd = 'claude'; url = 'https://code.claude.com/docs/en/setup'
       dirs = @("$UserHome\.local\bin", "$A\npm", "$L\Programs\claude") },
    @{ key = 'codex'; name = 'Codex CLI'; cmd = 'codex'; url = 'https://github.com/openai/codex'
       dirs = @("$A\npm", "$UserHome\.local\bin", "$codexHome\bin", "$L\Programs\OpenAI\Codex\bin") },
    @{ key = 'antigravity'; name = 'Antigravity CLI (agy)'; cmd = 'agy'; url = 'https://antigravity.google/download'
       dirs = @("$UserHome\.gemini\bin", "$L\agy\bin", "$L\Programs\Antigravity\bin") },
    @{ key = 'hc'; name = 'herdr-core (hc)'; cmd = 'hc'; url = 'https://herdr.dev/download/'
       dirs = @("$L\Programs\herdr-core", "$L\Programs\herdr-core\bin") },
    @{ key = 'herdr-app'; name = 'Herdr app CLI'; cmd = 'herdr-app'; url = 'https://herdr.dev/download/'
       dirs = @("$L\Programs\herdr-app") },
    @{ key = 'git'; name = 'Git'; cmd = 'git'; url = 'https://git-scm.com/install/'
       dirs = @("$env:ProgramFiles\Git\cmd", "$L\Programs\Git\cmd") }
  )
  $out = @()
  foreach ($t in $list) {
    $p = Find-Tool $t.cmd $t.dirs
    $out += [pscustomobject]@{ key = $t.key; name = $t.name; found = [bool]$p; path = $(if ($p) { $p } else { '' }); url = $t.url }
  }
  return ,$out
}

# ---------- actions ----------
function Do-Detect {
  $m = Read-Manifest
  $protocol = [ordered]@{}
  foreach ($k in $RuleFiles.Keys) {
    $f = $RuleFiles[$k]; $t = Read-Text $f
    $protocol[$k] = [pscustomobject]@{ file = $f; exists = ($null -ne $t); hasBlock = [bool]($t -and $t -match 'AI-PROTOCOL:BEGIN')
                                       managed = [bool]($m.protocol -and $m.protocol.PSObject.Properties[$k]) }
  }
  $onPath = [bool]((Get-UserPath) -split ';' | Where-Object { $_ -and (Same-Dir $_ $BinDir) })
  $progFile = Join-Path $HerdrHome 'programs.json'
  $prog = $null; try { $t = Read-Text $progFile; if ($t) { $prog = $t | ConvertFrom-Json } } catch {}
  $entries = [ordered]@{}
  foreach ($k in @('claude', 'codex', 'antigravity', 'relay')) { $entries[$k] = [bool]($prog -and $prog.programs -and $prog.programs.PSObject.Properties[$k] -and $prog.programs.$k.run) }
  $installed = Test-Path -LiteralPath $ManifestPath
  Out-Result ([ordered]@{
    ok = $true; action = 'detect'; kitVersion = $KitVersion; installedVersion = [string]$m.version
    home = $UserHome; protocolDir = $ProtocolDir; herdrHome = $HerdrHome
    installed = $installed
    # Engine files there but not from this kit (e.g. an earlier hand install): install backs them up first.
    foreign = (-not $installed) -and (Test-Path -LiteralPath (Join-Path $ProtocolDir 'ai-relay.ps1'))
    tools = (Detect-Tools); protocol = $protocol
    path = [ordered]@{ dir = $BinDir; onPath = $onPath; managed = [bool]($m.path -and $m.path.added) }
    programs = [ordered]@{ file = $progFile; herdrFound = (Test-Path -LiteralPath $HerdrHome); entries = $entries; managed = [bool]$m.programs }
  })
}

function Do-Install {
  $m = Read-Manifest
  $known = @{}; foreach ($f in @($m.files)) { if ($f) { $known[$f.rel] = $f } }
  $backupDir = Join-Path $ProtocolDir "backup-ai-relay-kit-$Stamp"
  $files = @(); $notes = @()
  foreach ($rel in $PayloadFiles) {
    $src = Join-Path $Source $rel; $dst = Join-Path $ProtocolDir $rel
    if (-not (Test-Path -LiteralPath $src)) { throw "Payload file missing: $src" }
    $text = Read-Text $src
    if ($rel -eq 'RELAY-AGENT.md') { $text = $text.Replace('{{PROTOCOL_DIR}}', $ProtocolDir) }
    $prev = $known[$rel]
    $entry = [ordered]@{ rel = $rel; sha = ''; backup = $(if ($prev) { $prev.backup } else { '' }); created = $(if ($prev) { [bool]$prev.created } else { $true }) }
    if (Test-Path -LiteralPath $dst) {
      $cur = Read-Text $dst
      if ($cur -eq $text) { $entry.sha = Hash-Of $dst; $files += [pscustomobject]$entry; continue }
      $ours = $prev -and ((Hash-Of $dst) -eq $prev.sha)
      if (-not $ours -and ($UserFiles -contains $rel)) {
        $notes += "kept your $rel"; $entry.sha = 'user'; $files += [pscustomobject]$entry; continue
      }
      if (-not $ours) {
        # Someone else's file (or edited since): keep a copy before replacing it.
        $b = Join-Path $backupDir $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $b) -Force | Out-Null
        Copy-Item -LiteralPath $dst -Destination $b -Force
        if (-not $prev) { $entry.backup = $b; $entry.created = $false }
        $notes += "backed up $rel"
      }
    }
    Write-Text $dst $text
    $entry.sha = Hash-Of $dst
    $files += [pscustomobject]$entry
  }
  Set-Prop $m 'version' $KitVersion
  Set-Prop $m 'files' $files
  Set-Prop $m 'installedAt' (Get-Date -Format 's')
  Save-Manifest $m
  Out-Result ([ordered]@{ ok = $true; action = 'install'; protocolDir = $ProtocolDir; files = @($files | ForEach-Object { $_.rel }); notes = $notes })
}

function Require-Installed {
  if (-not (Test-Path -LiteralPath $ManifestPath)) { throw 'Copy the relay files first (install).' }
}

function Do-Protocol {
  Require-Installed
  $key = $Agent.ToLower(); if ($key -eq 'agy' -or $key -eq 'gemini') { $key = 'antigravity' }
  if (-not $RuleFiles.Contains($key)) { throw "Unknown agent '$Agent' (claude | codex | antigravity)." }
  $file = $RuleFiles[$key]
  $m = Read-Manifest
  if (-not $m.protocol) { Set-Prop $m 'protocol' ([pscustomobject]@{}) }
  $prev = if ($m.protocol.PSObject.Properties[$key]) { $m.protocol.$key } else { $null }
  # Claude Code imports the installed file, so later protocol edits apply at once; the others get a copy.
  $body = if ($key -eq 'claude') { '@~/.agents/protocol/AI-PROTOCOL.md' } else { (Read-Text (Join-Path $ProtocolDir 'AI-PROTOCOL.md')).Trim() }
  $block = "$BEGIN`r`n$body`r`n$END"
  $old = Read-Text $file
  $created = if ($prev) { [bool]$prev.created } else { $null -eq $old }
  $backup = if ($prev) { [string]$prev.backup } else { '' }
  if ($null -ne $old -and -not $prev) {
    $backup = "$file.bak-ai-relay-kit"
    if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::WriteAllText($backup, $old, $utf8) }
  }
  if ($null -eq $old) { $old = '' }
  if ($old -match 'AI-PROTOCOL:BEGIN') {
    $new = [regex]::Replace($old, '(?s)<!-- AI-PROTOCOL:BEGIN.*?<!-- AI-PROTOCOL:END -->', [Text.RegularExpressions.MatchEvaluator] { param($x) $block })
  } elseif ($old.Trim().Length -gt 0) { $new = $old.TrimEnd() + "`r`n`r`n" + $block + "`r`n" }
  else { $new = $block + "`r`n" }
  Write-Text $file $new
  Set-Prop $m.protocol $key ([pscustomobject]@{ file = $file; backup = $backup; created = $created; sha = (Hash-Of $file) })
  Save-Manifest $m
  Out-Result ([ordered]@{ ok = $true; action = 'protocol'; agent = $key; file = $file; backup = $backup })
}

function Do-Path {
  Require-Installed
  $m = Read-Manifest
  $cur = Get-UserPath
  $has = [bool]($cur -split ';' | Where-Object { $_ -and (Same-Dir $_ $BinDir) })
  if (-not $has) {
    Set-UserPath (($cur.TrimEnd(';') + ';' + $BinDir).TrimStart(';'))
    Set-Prop $m 'path' ([pscustomobject]@{ dir = $BinDir; added = $true })
    Save-Manifest $m
  }
  Out-Result ([ordered]@{ ok = $true; action = 'path'; dir = $BinDir; added = (-not $has); note = 'Open a new terminal to use the relay command.' })
}

function Do-Programs {
  Require-Installed
  if (-not (Test-Path -LiteralPath $HerdrHome)) { throw "Herdr app folder not found: $HerdrHome" }
  $m = Read-Manifest
  $file = Join-Path $HerdrHome 'programs.json'
  $text = Read-Text $file
  $json = if ($text) { $text | ConvertFrom-Json } else { New-Object psobject }
  if (-not $json.PSObject.Properties['programs'] -or -not $json.programs) { Set-Prop $json 'programs' (New-Object psobject) }
  $prev = $m.programs
  $added = @(); if ($prev) { $added = @($prev.keys) }
  $tools = Detect-Tools
  $want = [ordered]@{}
  foreach ($t in $tools) {
    if (-not $t.found) { continue }
    if ($t.key -eq 'claude') { $want['claude'] = [pscustomobject]@{ run = [object[]]@($t.path) } }
    if ($t.key -eq 'antigravity') { $want['antigravity'] = [pscustomobject]@{ run = [object[]]@($t.path) } }
    if ($t.key -eq 'codex') { $want['codex'] = [pscustomobject]@{ run = [object[]]@('codex', '--no-daemon') } }
  }
  $want['relay'] = [pscustomobject]@{ name = 'AI Relay'; icon = 'mods/ai-relay-kit/icons/relay.svg'; tint = $false
                                      tile = '#1c1d21'; color = '#ffffff'; run = [object[]]@((Join-Path $BinDir 'relay.cmd')) }
  $skipped = @(); $changed = $false
  foreach ($k in $want.Keys) {
    $cur = $json.programs.PSObject.Properties[$k]
    # Never replace an entry the user made: only add missing ones (or refresh our own).
    if ($cur -and $cur.Value.run -and ($added -notcontains $k)) { $skipped += $k; continue }
    Set-Prop $json.programs $k $want[$k]
    if ($added -notcontains $k) { $added += $k }
    $changed = $true
  }
  $backup = if ($prev) { [string]$prev.backup } else { '' }
  $created = if ($prev) { [bool]$prev.created } else { $null -eq $text }
  if ($changed) {
    if ($text -and -not $prev) { $backup = "$file.bak-ai-relay-kit"; if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::WriteAllText($backup, $text, $utf8) } }
    Write-Text $file ($json | ConvertTo-Json -Depth 10)
  }
  Set-Prop $m 'programs' ([pscustomobject]@{ file = $file; backup = $backup; created = $created; keys = $added; sha = (Hash-Of $file) })
  Save-Manifest $m
  Out-Result ([ordered]@{ ok = $true; action = 'programs'; file = $file; added = $added; keptYours = $skipped })
}

# Undo one edited file: unchanged since we wrote it -> restore the backup (or delete what we created);
# changed since -> only take our part out ($strip) and leave the backup next to it.
function Undo-File([string]$file, [string]$backup, [bool]$created, [string]$sha, [scriptblock]$strip) {
  if (-not (Test-Path -LiteralPath $file)) { return "gone: $file" }
  if ((Hash-Of $file) -eq $sha) {
    if ($created) { Remove-Item -LiteralPath $file -Force; return "deleted $file" }
    if ($backup -and (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $backup -Destination $file -Force; Remove-Item -LiteralPath $backup -Force; return "restored $file" }
  }
  & $strip $file
  return "removed our part from $file$(if ($backup -and (Test-Path -LiteralPath $backup)) { " (backup kept: $backup)" })"
}

function Do-Remove {
  if (-not (Test-Path -LiteralPath $ManifestPath)) { Out-Result ([ordered]@{ ok = $true; action = 'remove'; notes = @('nothing to remove') }); return }
  $m = Read-Manifest
  $notes = @()
  if ($m.programs) {
    $p = $m.programs; $keys = @($p.keys)
    $notes += Undo-File $p.file $p.backup ([bool]$p.created) $p.sha {
      param($f)
      $j = (Read-Text $f) | ConvertFrom-Json
      foreach ($k in $keys) { if ($j.programs -and $j.programs.PSObject.Properties[$k]) { $j.programs.PSObject.Properties.Remove($k) } }
      Write-Text $f ($j | ConvertTo-Json -Depth 10)
    }
  }
  if ($m.path -and $m.path.added) {
    $cur = Get-UserPath
    Set-UserPath ((($cur -split ';') | Where-Object { $_ -and -not (Same-Dir $_ $m.path.dir) }) -join ';')
    $notes += "removed $($m.path.dir) from PATH"
  }
  if ($m.protocol) {
    foreach ($pr in $m.protocol.PSObject.Properties) {
      $v = $pr.Value
      $notes += Undo-File $v.file $v.backup ([bool]$v.created) $v.sha {
        param($f)
        $t = [regex]::Replace((Read-Text $f), $BlockPattern, "`r`n").TrimEnd()
        Write-Text $f $(if ($t) { $t + "`r`n" } else { '' })
      }
    }
  }
  foreach ($f in @($m.files)) {
    if (-not $f) { continue }
    $dst = Join-Path $ProtocolDir $f.rel
    if (-not (Test-Path -LiteralPath $dst)) { continue }
    if ($f.sha -eq 'user' -or (Hash-Of $dst) -ne $f.sha) { $notes += "kept $($f.rel) (yours or changed)"; continue }
    if ($f.backup -and (Test-Path -LiteralPath $f.backup)) { Copy-Item -LiteralPath $f.backup -Destination $dst -Force; $notes += "restored $($f.rel)" }
    elseif ($f.created) { Remove-Item -LiteralPath $dst -Force }
  }
  Remove-Item -LiteralPath $ManifestPath -Force
  # The relay's own cache (only if this kit brought the relay), then folders left empty.
  $engine = @($m.files) | Where-Object { $_ -and $_.rel -eq 'ai-relay.ps1' } | Select-Object -First 1
  $usage = Join-Path $ProtocolDir 'usage'
  if ($engine -and $engine.created -and (Test-Path -LiteralPath $usage)) { Remove-Item -LiteralPath $usage -Recurse -Force }
  Get-ChildItem -LiteralPath $ProtocolDir -Directory -Filter 'backup-ai-relay-kit-*' -ErrorAction SilentlyContinue |
    ForEach-Object { $notes += "kept backups: $($_.FullName)" }
  foreach ($d in @($BinDir, $ProtocolDir, (Split-Path -Parent $ProtocolDir))) {
    if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force }
  }
  Out-Result ([ordered]@{ ok = $true; action = 'remove'; notes = $notes })
}

try {
  switch ($Action) {
    'detect'   { Do-Detect }
    'install'  { Do-Install }
    'protocol' { Do-Protocol }
    'path'     { Do-Path }
    'programs' { Do-Programs }
    'remove'   { Do-Remove }
  }
} catch {
  Out-Result ([ordered]@{ ok = $false; action = $Action; error = $_.Exception.Message })
  exit 1
}
